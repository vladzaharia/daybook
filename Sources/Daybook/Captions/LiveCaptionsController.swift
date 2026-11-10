import AVFoundation
import DaybookCaptions
import DaybookCore
import DaybookDevices
import DaybookLink
import DaybookUI
import Foundation
import Observation

/// Where this Mac keeps the live captions it made: DaybookCaptions' store, the iPhone's too.
typealias LiveCaptionStore = DaybookCaptions.LiveCaptionStore

/// The Mac's live captions while it records, on the shared DaybookCaptions engine the iPhone uses:
/// one captioner for You (the microphone) and one for Call (the call or system track), fed by the
/// recorder's caption tap (docs/capture.md, "Live captions").
///
/// They're tentative feedback that the audio is being heard, and something to read until the
/// transcript exists. They're never the transcript: saved on this Mac only (`LiveCaptionStore`),
/// never synced, fused, summarized, or used as evidence, and gone once the transcript lands.
///
/// What the iPhone does too (the captioners, saving, other devices' lines put together, finishing) is the
/// shared `LiveCaptionSession`; this adds the Mac's own: when the microphone can hear the call through the
/// speakers (`CaptionEcho`), when the recording surfaces show captions, and the call's lines for an iPhone
/// recording the conversation too (`shareCall`).
///
/// Other devices recording the same conversation add their captions (`received`): a recorder
/// recording along (its live audio, captioned on this Mac) and a paired iPhone (its captions, over
/// the local link). An utterance several sources heard reads once, from the source that heard it best,
/// labelled with it (`LiveCaptionMixer`).
@MainActor
@Observable
final class LiveCaptionsController {
    /// The recording's captioners, what they've heard, and their saving.
    let session: LiveCaptionSession
    /// The conversation whose recording surfaces show captions now (`isShowing(for:)`), so a surface
    /// can follow it without observing every word.
    private(set) var showing: UUID?

    /// Makes the captioner for one source; nil when captions are off or can't run on this system.
    @ObservationIgnored var makeCaptioner: (LiveCaptionSource) -> (any LiveCaptioning)?
    /// The captions of recorders recording along, as they're made (`AppState.wireCaptions`).
    let recorders = LiveCaptureCaptions()

    @ObservationIgnored private var canEcho: Bool?
    @ObservationIgnored private var routeWatch: ObservationWatch?
    /// The call's lines going to each iPhone recording this conversation that shows other devices' captions.
    @ObservationIgnored private var callShares: [UUID: CaptionShare] = [:]
    @ObservationIgnored private var callSharing: Task<Void, Never>?

    /// Saved captions by conversation, each recording's, as `readSaved` last read them off the main actor:
    /// what the transcript's page, the view switch, and search show (`AppState.savedCaptions(for:)`).
    private(set) var saved: [UUID: [LiveCaptions]] = [:]
    /// Reads of every conversation's started, and of each one's, so one that finishes after a later one leaves
    /// what that read.
    @ObservationIgnored private var savedReads = 0
    @ObservationIgnored private var conversationReads: [UUID: Int] = [:]

    init(store: LiveCaptionStore, makeCaptioner: @escaping (LiveCaptionSource) -> (any LiveCaptioning)?) {
        session = LiveCaptionSession(store: store)
        self.makeCaptioner = makeCaptioner
        session.statesChanged = { [weak self] in self?.updateShowing() }
    }

    /// What's on screen: the newest of You and Call, tagged with their source, and other devices' lines,
    /// each utterance once (`LiveCaptionMixer`).
    var segments: [LiveCaptionSegment] { session.segments }
    /// Other devices' names by source (raw value), for their lines' labels.
    var sourceNames: [String: String] { session.sourceNames }
    /// Each source's captioner, as it stands.
    var states: [LiveCaptionSource: LiveCaptionState] { session.states }
    /// The conversation being captioned, from `prepare` until the captions are saved.
    var meetingID: UUID? { session.meetingID }
    /// When captions were last written to the store.
    var lastSave: Date? { session.lastSave }
    var store: LiveCaptionStore { session.store }
    /// Captioning this Mac's recording now.
    var isActive: Bool { session.isActive }
    /// The language captions listen in, for the surfaces' status lines.
    var locale: Locale { Locale(identifier: session.localeIdentifier) }

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
    func recent(_ count: Int) -> [LiveCaptionSegment] { session.recent(count) }

    /// What a line from `source` is labelled with: "You", "Call", or the device that heard it.
    func label(for source: LiveCaptionSource?) -> String { LiveCaptionLabels.label(for: source, names: sourceNames) }

    /// Reads every conversation's saved captions again (`saved`), off the main actor: at launch and after
    /// pruning.
    func readSaved() async {
        savedReads += 1
        let read = savedReads, store = self.store
        let found = await Task.detached(priority: .userInitiated) { store.allCaptures() }.value
        guard read == savedReads, found != saved else { return }
        saved = found
    }

    /// Reads one conversation's saved captions again, off the main actor: after they're saved.
    func readSaved(_ meetingID: UUID) async {
        let all = savedReads, read = (conversationReads[meetingID] ?? 0) + 1
        conversationReads[meetingID] = read
        let store = self.store
        let found = await Task.detached(priority: .userInitiated) { store.captures(of: meetingID) }.value
        guard all == savedReads, conversationReads[meetingID] == read else { return }
        let value = found.isEmpty ? nil : found
        if saved[meetingID] != value { saved[meetingID] = value }
    }

    // MARK: Other devices

    /// Another device's captions of this recording (`LiveCaptionSession.received`).
    func received(_ segments: [LiveCaptionSegment], removed: [UUID] = [], from source: LiveCaptionSource, name: String,
                  offset: TimeInterval, changesOnly: Bool = false, forwards: Bool = true, track: LiveCaptionTrack? = nil) {
        session.received(segments, removed: removed, from: source, name: name, offset: offset, changesOnly: changesOnly,
                         forwards: forwards, track: track)
    }

    /// While this Mac records, its call's lines go to the iPhones recording the conversation too that show
    /// other devices' captions (`recipients`), a second at a time and only what changed, with those taken
    /// back: with headphones on here, a phone in the room can't hear the call.
    func shareCall(conversation: UUID, startedAt: Date, recipients: @escaping @MainActor () -> [UUID],
                   send: @escaping @MainActor (LinkCaptions, UUID) async -> Void) {
        callShares = [:]
        callSharing?.cancel()
        callSharing = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.callShareInterval)
                guard !Task.isCancelled, let self, self.session.meetingID == conversation else { return }
                let phones = recipients()
                guard !phones.isEmpty else { continue }
                let lines = await self.session.forwardable().filter { $0.source == .call }
                for phone in phones {
                    var share = self.callShares[phone] ?? CaptionShare()
                    let changes = share.changes(lines, names: [:])
                    self.callShares[phone] = share
                    guard !changes.lines.isEmpty || !changes.removed.isEmpty else { continue }
                    await send(LinkCaptions(conversationID: conversation, startedAt: startedAt, lines: changes.lines,
                                            removed: changes.removed.isEmpty ? nil : changes.removed), phone)
                }
            }
        }
    }

    /// The call's lines go to an iPhone this often.
    static let callShareInterval: Duration = .seconds(1)

    // MARK: A recording

    /// Before the recorder starts: a captioner for each source (none when captions are off or the
    /// system can't make them) and the tap that hands them the recorder's audio. Nil means no captions.
    func prepare(meetingID: UUID, includesCall: Bool) -> CaptureCaptionTap? {
        canEcho = nil
        callSharing?.cancel()
        callSharing = nil
        var tap = CaptureCaptionTap()
        var captioners: [(source: LiveCaptionSource, captioner: any LiveCaptioning)] = []
        for source in includesCall ? [LiveCaptionSource.microphone, .call] : [.microphone] {
            guard let captioner = makeCaptioner(source) else { continue }
            captioners.append((source, captioner))
            // Seconds since the recording started become the buffer's place on that timeline.
            let handler: CaptureBufferHandler = { buffer, seconds in
                let rate = buffer.format.sampleRate
                guard rate > 0 else { return }
                captioner.append(buffer, at: AVAudioTime(sampleTime: AVAudioFramePosition((max(0, seconds) * rate).rounded()), atRate: rate))
            }
            if source == .microphone { tap.microphone = handler } else { tap.call = handler }
        }
        return session.begin(meetingID: meetingID, captioners: captioners) ? tap : nil
    }

    /// The recorder is running (since `startedAt`, by this Mac's clock): listen in `locale`. The microphone's
    /// captioner starts first, so a language that needs a download is fetched once. Returns once both run or
    /// have said why not.
    func start(locale: Locale, startedAt: Date = Date()) async {
        await session.start(locale: locale, startedAt: startedAt)
    }

    /// Follows the recorder's output route: on speakers (or anything that might be), a microphone line
    /// that only echoes the call reads as the call's; with headphones both sources show in full.
    func follow(_ recorder: RecordingController) {
        routeWatch = ObservationWatch.values(of: { [weak recorder] in recorder?.outputRoute }) { [weak self, weak recorder] route in
            guard let self, let route, self.isActive else { return }
            self.routeChanged(route.kind, at: recorder?.elapsedTime ?? 0)
        }
    }

    /// The output route at `time` seconds into the recording: it applies from then on.
    func routeChanged(_ kind: AudioOutputRoute.Kind, at time: TimeInterval) {
        let echoes = CaptionEcho.canEcho(kind)
        guard canEcho != echoes else { return }
        canEcho = echoes
        session.echoes(echoes, from: time)
    }

    /// The recording stopped (or never started): finish both captioners, keep what stands as heard,
    /// and save. Nothing about the recording waits for this.
    func finish() async {
        callSharing?.cancel()
        callSharing = nil
        await session.finish()
    }
}

// MARK: - Settings and captioners

/// Live captions' preferences on this Mac (never synced): on or off, and the language.
@MainActor
@Observable
final class LiveCaptionSettings {
    var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Keys.enabled) } }
    /// Nil follows the Mac's language.
    var localeIdentifier: String? { didSet { defaults.set(localeIdentifier, forKey: Keys.locale) } }
    /// A downloaded live transcription model captions in this language (`MacLiveModels`), so captions
    /// run even where the Speech framework can't (macOS 15). Not stored: read from what's installed.
    var hasLiveModels = false
    /// The languages the downloaded live recognizers cover ("en", "ja"): what the language choice
    /// offers where the Speech framework can't. Not stored.
    var liveLanguages: [String] = []
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

extension LiveCaptionSettings: LiveCaptionPreferences {
    var captionsEnabled: Bool {
        get { isEnabled }
        set { isEnabled = newValue }
    }

    var captionLanguage: String? {
        get { localeIdentifier }
        set { localeIdentifier = newValue }
    }
}

/// Which captioner a source gets on this Mac.
@MainActor
enum MacCaptioners {
    /// The Speech framework's captions need macOS 26's `SpeechAnalyzer`; on macOS 15 only downloaded
    /// live models caption. `--captions-as-macos-15` (debug) acts as macOS 15 for screenshots.
    nonisolated static var systemSupportsCaptions: Bool {
        #if DEBUG
        if CommandLine.arguments.contains("--captions-as-macos-15") { return false }
        #endif
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
