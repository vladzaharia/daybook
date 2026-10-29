import AVFoundation
import Combine
import DaybookCaptions
import DaybookCore
import DaybookDevices
import Foundation

/// The Mac's live captions while it records, on the shared DaybookCaptions engine the iPhone uses:
/// one captioner for You (the microphone) and one for Call (the call or system track), fed by the
/// recorder's caption tap (docs/capture.md, "Live captions").
///
/// They're tentative feedback that the audio is being heard, and something to read until the
/// transcript exists. They're never the transcript: saved on this Mac only (`LiveCaptionStore`),
/// never synced, fused, summarized, or used as evidence, and gone once the transcript lands.
///
/// The recording never depends on them. Each captioner runs on its own tasks, keeps a bounded
/// backlog and drops audio when it falls behind, and a captioner that can't start or fails changes
/// only its own state; the other source keeps captioning.
@MainActor
final class LiveCaptionsController: ObservableObject {
    /// What's on screen: You and Call interleaved by time and tagged with their source, without
    /// microphone lines that only echo the call through the speakers (`CaptionEcho`).
    @Published private(set) var segments: [LiveCaptionSegment] = []
    /// Each source's captioner, as it stands.
    @Published private(set) var states: [LiveCaptionSource: LiveCaptionState] = [:]
    /// The conversation being captioned, from `prepare` until the captions are saved.
    @Published private(set) var meetingID: UUID?
    /// When captions were last written to the store, so pages showing saved captions read them again.
    @Published private(set) var lastSave: Date?
    /// The conversation whose recording surfaces show captions now (`isShowing(for:)`), so a surface
    /// can follow it without observing every word.
    @Published private(set) var showing: UUID?

    let store: LiveCaptionStore
    /// Makes the captioner for one source; nil when captions are off or can't run on this system.
    var makeCaptioner: (LiveCaptionSource) -> (any LiveCaptioning)?

    private var captioners: [LiveCaptionSource: any LiveCaptioning] = [:]
    private var heard: [LiveCaptionSource: [LiveCaptionSegment]] = [:]
    private var listeners: [Task<Void, Never>] = []
    private var generation = UUID()
    private var routes: [(time: TimeInterval, echoes: Bool)] = []
    private var routeSubscription: AnyCancellable?
    /// You lines already judged, so an hour of captions isn't compared again on every word.
    private var verdicts: [UUID: (text: String, isEcho: Bool)] = [:]
    private var saving: Task<Void, Never>?
    private var dirty = false
    private var createdAt = Date()
    private var localeIdentifier = Locale.current.identifier

    /// While listening, what's heard is written this often, so a crash keeps most of it.
    static let saveInterval: Duration = .seconds(10)
    /// You lines older than this (behind the newest caption) keep the echo verdict they were given.
    static let settledAfter: TimeInterval = 30

    init(store: LiveCaptionStore, makeCaptioner: @escaping (LiveCaptionSource) -> (any LiveCaptioning)?) {
        self.store = store
        self.makeCaptioner = makeCaptioner
    }

    /// Captioning this Mac's recording now.
    var isActive: Bool { !captioners.isEmpty }
    /// The language captions listen in, for the surfaces' status lines.
    var locale: Locale { Locale(identifier: localeIdentifier) }

    /// Where captions stand overall: listening while either source is; otherwise the most telling state.
    var state: LiveCaptionState {
        let values = Array(states.values)
        if values.contains(.listening) { return .listening }
        if let downloading = values.first(where: { if case .downloading = $0 { return true } else { return false } }) { return downloading }
        if values.contains(.preparing) { return .preparing }
        if let failed = values.first(where: { if case .failed = $0 { return true } else { return false } }) { return failed }
        if let unavailable = values.first(where: { if case .unavailable = $0 { return true } else { return false } }) { return unavailable }
        return values.contains(.finished) ? .finished : .off
    }

    /// Whether a recording surface shows captions for this conversation. When they can't run (no
    /// language, no Speech support) the surfaces stay quiet and Settings says why.
    func isShowing(for meetingID: UUID) -> Bool { showing == meetingID }

    private func updateShowing() {
        let shows: Bool
        switch state {
        case .preparing, .downloading, .listening, .failed: shows = isActive
        case .off, .unavailable, .finished: shows = false
        }
        let value = shows ? meetingID : nil
        if showing != value { showing = value }
    }

    /// The newest lines, oldest first.
    func recent(_ count: Int) -> [LiveCaptionSegment] { Array(segments.suffix(count)) }

    // MARK: A recording

    /// Before the recorder starts: a captioner for each source (none when captions are off or the
    /// system can't make them) and the tap that hands them the recorder's audio. Nil means no captions.
    func prepare(meetingID: UUID, includesCall: Bool) -> CaptureCaptionTap? {
        reset()
        var tap = CaptureCaptionTap()
        for source in includesCall ? [LiveCaptionSource.microphone, .call] : [.microphone] {
            guard let captioner = makeCaptioner(source) else { continue }
            captioners[source] = captioner
            states[source] = .preparing
            listen(to: captioner, as: source)
            // Seconds since the recording started become the buffer's place on that timeline.
            let handler: CaptureBufferHandler = { buffer, seconds in
                let rate = buffer.format.sampleRate
                guard rate > 0 else { return }
                captioner.append(buffer, at: AVAudioTime(sampleTime: AVAudioFramePosition((max(0, seconds) * rate).rounded()), atRate: rate))
            }
            if source == .microphone { tap.microphone = handler } else { tap.call = handler }
        }
        guard !captioners.isEmpty else { return nil }
        self.meetingID = meetingID
        createdAt = Date()
        updateShowing()
        return tap
    }

    /// The recorder is running: listen in `locale`. The microphone's captioner starts first, so a
    /// language that needs a download is fetched once. Returns once both run or have said why not.
    func start(locale: Locale) async {
        localeIdentifier = locale.identifier
        for source in [LiveCaptionSource.microphone, .call] {
            guard let captioner = captioners[source] else { continue }
            await captioner.start(locale: locale, sourceFormat: nil)
        }
    }

    /// Follows the recorder's output route: on speakers (or anything that might be), microphone lines
    /// that only echo the call are left out; with headphones both sources show in full.
    func follow(_ recorder: RecordingController) {
        routeSubscription = recorder.$outputRoute.sink { [weak self, weak recorder] route in
            guard let self, let route, self.isActive else { return }
            self.routeChanged(route.kind, at: recorder?.elapsedTime ?? 0)
        }
    }

    /// The output route at `time` seconds into the recording.
    func routeChanged(_ kind: AudioOutputRoute.Kind, at time: TimeInterval) {
        let canEcho = kind != .headphones
        guard routes.last?.echoes != canEcho else { return }
        routes.append((time, canEcho))
        verdicts = [:]
        rebuild()
    }

    /// The recording stopped (or never started): finish both captioners, keep what stands as heard,
    /// and save. Nothing about the recording waits for this.
    func finish() async {
        guard isActive else { return }
        let current = generation
        let finishing = captioners
        captioners = [:]
        updateShowing()
        for source in [LiveCaptionSource.microphone, .call] {
            await finishing[source]?.finish()
        }
        for listener in listeners { await listener.value }
        guard generation == current else { return }
        listeners = []
        saving?.cancel()
        saving = nil
        heard = heard.mapValues { $0.map { segment in var segment = segment; segment.isTentative = false; return segment } }
        rebuild()
        save()
        states = [:]
        segments = []
        heard = [:]
        meetingID = nil
    }

    // MARK: Listening

    private func listen(to captioner: any LiveCaptioning, as source: LiveCaptionSource) {
        let current = generation
        listeners += [
            Task { [weak self] in
                for await snapshot in captioner.updates {
                    guard let self, self.generation == current else { return }
                    self.heard[source] = snapshot
                    self.dirty = true
                    self.rebuild()
                }
            },
            Task { [weak self] in
                for await state in captioner.states {
                    guard let self, self.generation == current else { return }
                    self.states[source] = state
                    self.updateShowing()
                    if state == .listening { self.startSaving() }
                }
            }
        ]
    }

    private func rebuild() {
        let you = heard[.microphone] ?? [], call = heard[.call] ?? []
        let newest = max(you.last?.end ?? 0, call.last?.end ?? 0)
        let merged = CaptionEcho.merge(you: you, call: call, echoes: canEcho(at:)) { line in
            if let known = verdicts[line.id], known.text == line.text, !line.isTentative, line.end < newest - Self.settledAfter {
                return known.isEcho
            }
            let verdict = CaptionEcho.isEcho(line, of: call)
            verdicts[line.id] = (line.text, verdict)
            return verdict
        }
        if merged != segments { segments = merged }
    }

    /// Whether the output could echo into the microphone at `time`. Until a route is known, assume it can.
    private func canEcho(at time: TimeInterval) -> Bool {
        (routes.last { $0.time <= time } ?? routes.first)?.echoes ?? true
    }

    private func reset() {
        generation = UUID()
        listeners.forEach { $0.cancel() }
        listeners = []
        saving?.cancel()
        saving = nil
        captioners = [:]
        heard = [:]
        states = [:]
        segments = []
        routes = []
        verdicts = [:]
        meetingID = nil
        dirty = false
        updateShowing()
    }

    private func startSaving() {
        guard saving == nil else { return }
        let current = generation
        saving = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.saveInterval)
                guard !Task.isCancelled, let self, self.generation == current else { return }
                if self.dirty { self.save() }
            }
        }
    }

    private func save() {
        guard let meetingID, !segments.isEmpty else { return }
        let captions = LiveCaptions(meetingID: meetingID, localeIdentifier: localeIdentifier, segments: segments,
                                    createdAt: createdAt, updatedAt: Date())
        do {
            try store.save(captions)
            dirty = false
            lastSave = captions.updatedAt
        } catch {
            // Captions are a convenience: a failed write never reaches the recording.
        }
    }
}

// MARK: - Storage

/// Mac-local storage at `<library>/LiveCaptions/<meeting id>.json`, laid out as on the iPhone:
/// outside `Meetings/`, so sync never sees it, and removed once the transcript replaces it or the
/// conversation goes to the Trash.
@MainActor
final class LiveCaptionStore {
    let directory: URL

    init(libraryRoot: URL) {
        directory = libraryRoot.appendingPathComponent("LiveCaptions", isDirectory: true)
    }

    func url(for meetingID: UUID) -> URL { directory.appendingPathComponent("\(meetingID.uuidString).json") }

    func captions(for meetingID: UUID) -> LiveCaptions? {
        guard let data = try? Data(contentsOf: url(for: meetingID)) else { return nil }
        return try? JSONDecoder().decode(LiveCaptions.self, from: data)
    }

    func save(_ captions: LiveCaptions) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = url(for: captions.meetingID)
        try JSONEncoder().encode(captions).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func remove(_ meetingID: UUID) {
        try? FileManager.default.removeItem(at: url(for: meetingID))
    }

    /// The captions to show for a conversation, or nil once its transcript has replaced them (a
    /// transcript made after the captions began) or when there's nothing to read.
    static func shown(_ captions: LiveCaptions?, for meeting: Meeting) -> LiveCaptions? {
        guard let captions, captions.meetingID == meeting.id, !isReplaced(captions, in: meeting),
              captions.segments.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }
        return captions
    }

    /// The official transcript replaces live captions: any transcript made since they began.
    static func isReplaced(_ captions: LiveCaptions, in meeting: Meeting) -> Bool {
        meeting.transcripts.contains { $0.createdAt >= captions.createdAt }
    }

    /// Removes captions the transcript has replaced, and those of conversations no longer in the
    /// library (moved to the Trash). `keeping` is the conversation being recorded.
    func prune(meetings: [Meeting], keeping: UUID?) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        guard !files.isEmpty else { return }
        let byID = Dictionary(meetings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for file in files where file.pathExtension == "json" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), id != keeping else { continue }
            guard let meeting = byID[id] else { remove(id); continue }
            if let captions = captions(for: id), Self.isReplaced(captions, in: meeting) { remove(id) }
        }
    }
}

// MARK: - Settings and captioners

/// Live captions' preferences on this Mac (never synced): on or off, and the language.
@MainActor
final class LiveCaptionSettings: ObservableObject {
    @Published var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Keys.enabled) } }
    /// Nil follows the Mac's language.
    @Published var localeIdentifier: String? { didSet { defaults.set(localeIdentifier, forKey: Keys.locale) } }
    /// A downloaded live transcription model captions in this language (`MacLiveModels`), so captions
    /// run even where the Speech framework can't (macOS 15). Not stored: read from what's installed.
    @Published var hasLiveModels = false
    var locale: Locale { localeIdentifier.map(Locale.init(identifier:)) ?? .current }

    private let defaults: UserDefaults
    enum Keys {
        static let enabled = "liveCaptions"
        static let locale = "captionLocale"
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        localeIdentifier = defaults.string(forKey: Keys.locale)
    }
}

/// Which captioner a source gets on this Mac.
@MainActor
enum MacCaptioners {
    /// Captions need macOS 26's `SpeechAnalyzer`. On macOS 15 there are none, and nothing says otherwise.
    nonisolated static var systemSupportsCaptions: Bool {
        if #available(macOS 26, *) { return true } else { return false }
    }

    /// About ten seconds of each source's audio may wait while the recognizer starts or catches up:
    /// the microphone arrives in buffers of about 85 ms, the call in IO cycles of about 10 ms.
    nonisolated static func backlog(for source: LiveCaptionSource) -> Int { source == .call ? 1_024 : 128 }

    /// The Speech framework's captioner for one of a recording's sources, counting from the
    /// recording's start, or nil when the system can't make one. A real recording may download
    /// the language and, if the analyzer needs it, ask once for speech-recognition permission.
    static func speechCaptioner(for source: LiveCaptionSource, allowsDownload: Bool,
                                supported: Bool = systemSupportsCaptions) -> (any LiveCaptioning)? {
        guard supported, #available(macOS 26, *) else { return nil }
        return SpeechCaptioner(allowsDownload: allowsDownload, asksForAuthorization: allowsDownload,
                               backlog: backlog(for: source), timelineOrigin: 0)
    }

    /// Recordings' captioners: none when captions are off or in tests (they inject their own); a
    /// script for `--demo-captions`; the live models when they're downloaded (`MacLiveModels`, any
    /// macOS), else the Speech framework (macOS 26).
    static func recordingFactory(settings: LiveCaptionSettings, live: MacLiveModels? = nil) -> (LiveCaptionSource) -> (any LiveCaptioning)? {
        { [weak settings, weak live] source in
            guard let settings, settings.isEnabled else { return nil }
            #if DEBUG
            if DemoCaptions.isRequested { return DemoCaptions.captioner(for: source) }
            #endif
            guard !isRunningTests else { return nil }
            let speech = { speechCaptioner(for: source, allowsDownload: !isDemo) }
            // Demos and the device simulator never load models.
            guard let live, !isDemo else { return speech() }
            return live.captioner(locale: settings.locale, backlog: backlog(for: source), timelineOrigin: 0, fallback: speech)
        }
    }

    /// Listen Live's captioner for a recorder: the same setting, language, and live models as recordings.
    static func recorderFactory(settings: LiveCaptionSettings, live: MacLiveModels? = nil) -> () -> (any LiveCaptioning)? {
        { [weak settings, weak live] in
            guard let settings, settings.isEnabled else { return nil }
            #if DEBUG
            if DemoCaptions.isRequested { return DemoCaptions.captioner(for: nil) }
            #endif
            guard !isRunningTests else { return nil }
            let speech = { LiveCaptionHooks.speechCaptioner(allowsDownload: !isDemo, asksForAuthorization: !isDemo) }
            guard let live, !isDemo else { return speech() }
            return live.captioner(locale: settings.locale, backlog: LiveCaptionHooks.backlog, timelineOrigin: 0, fallback: speech)
        }
    }

    static let isRunningTests = NSClassFromString("XCTestCase") != nil

    /// Device demos and the simulator never download a language or ask for permission.
    private static var isDemo: Bool {
        #if DEBUG
        return DeviceDemo.isRequested || DeviceDemo.usesSimulator
        #else
        return false
        #endif
    }
}

#if DEBUG
/// `--demo-captions`: scripted captions for screenshots and the device simulator, without speech
/// recognition. With `--simulate-recording`, You and Call talk over one another on speakers, and
/// the microphone's echo of the call is left out.
enum DemoCaptions {
    static let isRequested = CommandLine.arguments.contains("--demo-captions")

    static func captioner(for source: LiveCaptionSource?) -> ScriptedCaptioner {
        if source == .microphone {
            return ScriptedCaptioner(lines: [
                .init(at: 0.2, text: "Can we lock the launch date before the end of the call?"),
                // The speakers' echo of the call's next line: the You captioner hears it too.
                .init(at: 2.5, text: "so the launch moves to the fourteenth"),
                .init(at: 4.6, text: "Great, I'll draft the checklist and send it around tonight."),
            ], wordInterval: 0.12)
        }
        if source == .call {
            // As live speakers label them: a voice recognized from its profile, then one that wasn't.
            return ScriptedCaptioner(lines: [
                .init(at: 1.6, text: "Yes. So the launch moves to the fourteenth, and Priya owns the checklist.",
                      speaker: LiveCaptionSpeaker(slot: "S1", name: "Sam")),
                .init(at: 3.8, text: "We still need legal to sign off on the pricing page before Friday.",
                      speaker: LiveCaptionSpeaker(slot: "S2")),
            ], wordInterval: 0.12, leavesLastTentative: false)
        }
        return ScriptedCaptioner(lines: [
            .init(at: 0.3, text: "So the launch moves to the fourteenth, and Priya owns the checklist."),
            .init(at: 2.4, text: "We still need legal to sign off on the pricing page before Friday."),
            .init(at: 4.4, text: "I'll send the deck around after lunch."),
        ], wordInterval: 0.12)
    }
}
#endif
