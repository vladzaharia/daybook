import Foundation
import Observation

/// One recording's live captions on the device recording it, the part the Mac and the iPhone share:
/// a captioner per source (the Mac's You and Call, the iPhone's microphone), other devices' lines
/// recording the same conversation (`received`), all put together off the main actor (`LiveCaptionMixer`),
/// the captions saved every `saveInterval` while they listen and once more at the end, and what stands kept
/// as heard when the recording stops. Each app adds only its own: when its microphone can hear its call
/// (`echoes`, the Mac's), its sources' levels and other devices' recordings (`levels`, `track`), when its
/// surfaces show the captions; the iPhone's filing and speakers afterwards.
///
/// The recording never depends on them. Each captioner runs on its own tasks, keeps a bounded backlog
/// and drops audio when it falls behind; one that can't start or fails changes only its own state.
/// The main actor holds only the newest lines; saves go to `LiveCaptionStore` off it.
@MainActor
@Observable
public final class LiveCaptionSession {
    /// What's on screen: the newest lines of every source put together (`LiveCaptionMixer`), in time order.
    public private(set) var segments: [LiveCaptionSegment] = []
    /// Grows with every change to the lines.
    public private(set) var version = 0
    /// Other devices' names by source (raw value), for their lines' labels.
    public private(set) var sourceNames: [String: String] = [:]
    /// Each source's captioner, as it stands.
    public private(set) var states: [LiveCaptionSource: LiveCaptionState] = [:]
    /// The conversation being captioned, from `begin` until the captions are saved.
    public private(set) var meetingID: UUID?
    /// This recording, among the conversation's (`LiveCaptions.captureID`), and when it began, by this
    /// device's clock (`start`).
    public private(set) var captureID: UUID?
    public private(set) var startedAt: Date?
    /// The language captions listen in.
    public private(set) var localeIdentifier = Locale.current.identifier
    /// When captions were last written, and the conversation they're of, so pages showing saved captions
    /// read them again.
    public private(set) var lastSave: Date?
    public private(set) var lastSaved: UUID?

    public let store: LiveCaptionStore
    /// While listening, what's heard is written this often, so a crash keeps most of it.
    public let saveInterval: Duration
    /// The sources' levels now (0…1, for a meter), read as their lines arrive, so an utterance several
    /// sources heard reads from the one that heard it loudest.
    @ObservationIgnored public var levels: (@MainActor () -> [LiveCaptionSource: Double])?
    /// Another device's recording, for a source `received` didn't say it of, when it's known: asked as
    /// captions are saved (a recorder reports its recording's ID a moment after it starts).
    @ObservationIgnored public var track: (@MainActor (LiveCaptionSource) -> LiveCaptionTrack?)?
    /// Told when a captioner starts, changes state, or the recording's captioners end.
    @ObservationIgnored public var statesChanged: (@MainActor () -> Void)?

    @ObservationIgnored private var captioners: [LiveCaptionSource: any LiveCaptioning] = [:]
    /// The sources, in the order their captioners start and finish.
    @ObservationIgnored private var order: [LiveCaptionSource] = []
    @ObservationIgnored private var mixer = LiveCaptionMixer()
    @ObservationIgnored private var pipe: AsyncStream<Operation>.Continuation?
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var tracks: [String: LiveCaptionTrack] = [:]
    @ObservationIgnored private var listeners: [Task<Void, Never>] = []
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var saving: Task<Void, Never>?
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var createdAt = Date()

    /// One change for the mixer, in the order changes were made.
    private typealias Operation = @Sendable (LiveCaptionMixer) async -> LiveCaptionMixer.Tail

    public init(store: LiveCaptionStore, saveInterval: Duration = .seconds(10)) {
        self.store = store
        self.saveInterval = saveInterval
    }

    /// Captioning a recording now: its captioners haven't been finished.
    public var isActive: Bool { !captioners.isEmpty }

    /// The newest lines, oldest first.
    public func recent(_ count: Int) -> [LiveCaptionSegment] { Array(segments.suffix(count)) }

    /// Every line, put together, in time order, as the changes made so far left them (built off the main actor).
    public func lines() async -> [LiveCaptionSegment] { await mixer.lines() }

    /// Every line this device's sources and the recorders it manages heard, as heard: what goes to another
    /// device recording the same conversation (`LinkCaptions`), which puts them together with its own.
    public func forwardable() async -> [LiveCaptionSegment] { await mixer.forwardable() }

    // MARK: A recording

    /// Begins `meetingID`'s captions with a captioner for each source, in the order they're to start.
    /// Whatever was being captioned before is dropped unsaved. Returns false when there's no captioner.
    @discardableResult
    public func begin(meetingID: UUID, captioners list: [(source: LiveCaptionSource, captioner: any LiveCaptioning)]) -> Bool {
        reset()
        for (source, captioner) in list where captioners[source] == nil {
            captioners[source] = captioner
            order.append(source)
            states[source] = .preparing
        }
        guard !captioners.isEmpty else {
            statesChanged?()
            return false
        }
        self.meetingID = meetingID
        captureID = UUID()
        createdAt = Date()
        openPipe()
        let sources = order
        send { await $0.ownSources(sources); return await $0.tail() }
        for source in order { if let captioner = captioners[source] { listen(to: captioner, as: source) } }
        statesChanged?()
        return true
    }

    /// The recording is running (since `startedAt`, by this device's clock): each source's captioner starts in
    /// `locale`, in turn, so a language that needs a download is fetched once. Returns once each runs or has
    /// said why not; a recording that stops meanwhile starts no more of them.
    public func start(locale: Locale, startedAt: Date = Date()) async {
        localeIdentifier = locale.identifier
        if self.startedAt == nil, isActive { self.startedAt = startedAt }
        for source in order {
            guard let captioner = captioners[source] else { continue }
            await captioner.start(locale: locale, sourceFormat: nil)
        }
    }

    /// Another device's captions of this recording: `segments` are all it has heard (a recorder's
    /// captioner), or, with `changesOnly`, the lines that changed and those it took back (`removed`: a phone's
    /// link). `offset` moves its times onto this recording's. `forwards`: its lines go on to other devices with
    /// this one's (a recorder this device manages); another device's own stay here. `track`: its recording,
    /// when known. Ignored unless a recording is being captioned.
    public func received(_ segments: [LiveCaptionSegment], removed: [UUID] = [], from source: LiveCaptionSource, name: String,
                         offset: TimeInterval, changesOnly: Bool = false, forwards: Bool = true, track: LiveCaptionTrack? = nil) {
        guard isActive, meetingID != nil else { return }
        if sourceNames[source.rawValue] != name { sourceNames[source.rawValue] = name }
        if let track { tracks[source.rawValue] = track }
        dirty = true
        let levels = self.levels?() ?? [:]
        send { await $0.received(segments, removed: removed, from: source, offset: offset, changesOnly: changesOnly,
                                 forwards: forwards, levels: levels) }
    }

    /// From `time` on (seconds into the recording), whether this device's microphone can hear its call through
    /// the output (not headphones): only then is a microphone line that repeats the call its echo.
    public func echoes(_ canEcho: Bool, from time: TimeInterval) {
        guard isActive else { return }
        send { await $0.echoes(canEcho, from: time) }
    }

    /// The recording stopped (or never started): every captioner finishes, what stands is kept as heard,
    /// and the captions are saved. Returns once they're on disk. Nothing about the recording waits for this.
    public func finish() async {
        guard isActive else { return }
        let current = generation
        let finishing = captioners
        captioners = [:]
        statesChanged?()
        for source in order { await finishing[source]?.finish() }
        for listener in listeners { await listener.value }
        guard generation == current else { return }
        listeners = []
        saving?.cancel()
        saving = nil
        // Every change made reaches the mixer before what stands is kept.
        pipe?.finish()
        await pump?.value
        guard generation == current else { return }
        publish(await mixer.heardAsSaid())
        await save()
        // A recording that began while this one saved keeps its own.
        guard generation == current else { return }
        states = [:]
        segments = []
        sourceNames = [:]
        meetingID = nil
        captureID = nil
        statesChanged?()
    }

    /// Writes what's heard now. A failed write is kept by the store, which tries it again on its own (the last save
    /// has no next one), and the next save tries again too.
    public func save() async {
        guard let meetingID else { return }
        let current = generation
        let lines = await mixer.lines()
        guard generation == current, !lines.isEmpty else { return }
        for source in sourceNames.keys where tracks[source] == nil {
            if let found = track?(LiveCaptionSource(rawValue: source)) { tracks[source] = found }
        }
        let captions = LiveCaptions(meetingID: meetingID, captureID: captureID, localeIdentifier: localeIdentifier, segments: lines,
                                    createdAt: createdAt, updatedAt: Date(), startedAt: startedAt ?? createdAt,
                                    sourceNames: sourceNames.isEmpty ? nil : sourceNames, tracks: tracks.isEmpty ? nil : tracks)
        // Lines that arrive while it's written mark it again.
        dirty = false
        do {
            try await store.save(captions)
            lastSaved = meetingID
            lastSave = captions.updatedAt
        } catch {
            dirty = true
        }
    }

    /// Saved captions of `meetingID` changed outside a recording (filed, speakers labelled afterwards): pages
    /// showing them read them again.
    public func savedElsewhere(at date: Date, meetingID: UUID) {
        lastSaved = meetingID
        lastSave = date
    }

    // MARK: Listening

    private func listen(to captioner: any LiveCaptioning, as source: LiveCaptionSource) {
        let current = generation
        listeners += [
            Task { [weak self] in
                for await snapshot in captioner.updates {
                    guard let self, self.generation == current else { return }
                    self.dirty = true
                    let levels = self.levels?() ?? [:]
                    self.send { await $0.heard(snapshot, from: source, levels: levels) }
                }
            },
            Task { [weak self] in
                for await state in captioner.states {
                    guard let self, self.generation == current else { return }
                    self.states[source] = state
                    self.statesChanged?()
                    if state == .listening { self.startSaving() }
                }
            },
        ]
    }

    /// Changes go to the mixer one after another, in the order they were made; what it shows comes back here.
    private func openPipe() {
        let (stream, continuation) = AsyncStream<Operation>.makeStream()
        pipe = continuation
        let mixer = self.mixer, current = generation
        pump = Task { [weak self] in
            for await operation in stream {
                let tail = await operation(mixer)
                guard let self, self.generation == current else { return }
                self.publish(tail)
            }
        }
    }

    private func send(_ operation: @escaping Operation) {
        pipe?.yield(operation)
    }

    private func publish(_ tail: LiveCaptionMixer.Tail) {
        guard tail.version != version else { return }
        version = tail.version
        if tail.lines != segments { segments = tail.lines }
    }

    private func startSaving() {
        guard saving == nil else { return }
        let current = generation, interval = saveInterval
        saving = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self, self.generation == current else { return }
                if self.dirty { await self.save() }
            }
        }
    }

    private func reset() {
        generation = UUID()
        listeners.forEach { $0.cancel() }
        listeners = []
        saving?.cancel()
        saving = nil
        pipe?.finish()
        pipe = nil
        pump?.cancel()
        pump = nil
        mixer = LiveCaptionMixer()
        captioners = [:]
        order = []
        tracks = [:]
        sourceNames = [:]
        states = [:]
        segments = []
        version = 0
        meetingID = nil
        captureID = nil
        startedAt = nil
        dirty = false
    }
}
