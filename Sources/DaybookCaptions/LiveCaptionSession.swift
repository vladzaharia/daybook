import Foundation
import Observation

/// One recording's live captions on the device recording it, the part the Mac and the iPhone share:
/// a captioner per source (the Mac's You and Call, the iPhone's microphone), what each has heard,
/// other devices' lines recording the same conversation (`received`), the captions saved every
/// `saveInterval` while they listen and once more at the end, and what stands kept as heard when the
/// recording stops. Each app adds only its own: how its sources go together (`merge`: the Mac's echo
/// rule) and when its surfaces show them; the iPhone's filing and speakers afterwards.
///
/// The recording never depends on them. Each captioner runs on its own tasks, keeps a bounded backlog
/// and drops audio when it falls behind; one that can't start or fails changes only its own state.
/// Saves go to `LiveCaptionStore` off the main actor.
@MainActor
@Observable
public final class LiveCaptionSession {
    /// What's on screen: this device's sources put together (`merge`), in time order, with other
    /// devices' lines that add something (`LiveCaptionMix`).
    public private(set) var segments: [LiveCaptionSegment] = []
    /// Other devices' names by source (raw value), for their lines' labels.
    public private(set) var sourceNames: [String: String] = [:]
    /// Each source's captioner, as it stands.
    public private(set) var states: [LiveCaptionSource: LiveCaptionState] = [:]
    /// The conversation being captioned, from `begin` until the captions are saved.
    public private(set) var meetingID: UUID?
    /// The language captions listen in.
    public private(set) var localeIdentifier = Locale.current.identifier
    /// When captions were last written, so pages showing saved captions read them again.
    public private(set) var lastSave: Date?

    public let store: LiveCaptionStore
    /// While listening, what's heard is written this often, so a crash keeps most of it.
    public let saveInterval: Duration
    /// This device's sources as one list, from what each has heard (each in time order). One source's
    /// lines as they are; several interleaved by time, unless the app puts them together itself.
    @ObservationIgnored public var merge: @MainActor ([LiveCaptionSource: [LiveCaptionSegment]]) -> [LiveCaptionSegment] = LiveCaptionSession.interleaved
    /// Told when a captioner starts, changes state, or the recording's captioners end.
    @ObservationIgnored public var statesChanged: (@MainActor () -> Void)?

    @ObservationIgnored private var captioners: [LiveCaptionSource: any LiveCaptioning] = [:]
    /// The sources, in the order their captioners start and finish.
    @ObservationIgnored private var order: [LiveCaptionSource] = []
    @ObservationIgnored private var heard: [LiveCaptionSource: [LiveCaptionSegment]] = [:]
    @ObservationIgnored private var feeds: [LiveCaptionSource: DeviceCaptionFeed] = [:]
    @ObservationIgnored private var listeners: [Task<Void, Never>] = []
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var saving: Task<Void, Never>?
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var createdAt = Date()

    public init(store: LiveCaptionStore, saveInterval: Duration = .seconds(10)) {
        self.store = store
        self.saveInterval = saveInterval
    }

    /// Captioning a recording now: its captioners haven't been finished.
    public var isActive: Bool { !captioners.isEmpty }

    /// What one source has heard, as its captioner last said.
    public func heard(from source: LiveCaptionSource) -> [LiveCaptionSegment] { heard[source] ?? [] }

    /// The newest lines, oldest first.
    public func recent(_ count: Int) -> [LiveCaptionSegment] { Array(segments.suffix(count)) }

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
            listen(to: captioner, as: source)
        }
        guard !captioners.isEmpty else {
            statesChanged?()
            return false
        }
        self.meetingID = meetingID
        createdAt = Date()
        statesChanged?()
        return true
    }

    /// The recording is running: each source's captioner starts in `locale`, in turn, so a language that
    /// needs a download is fetched once. Returns once each runs or has said why not; a recording that
    /// stops meanwhile starts no more of them.
    public func start(locale: Locale) async {
        localeIdentifier = locale.identifier
        for source in order {
            guard let captioner = captioners[source] else { continue }
            await captioner.start(locale: locale, sourceFormat: nil)
        }
    }

    /// Another device's captions of this recording: `segments` are all it has heard (a recorder's
    /// captioner), or, with `changesOnly`, the lines that changed (a phone's link). `offset` moves its
    /// times onto this recording's. Ignored unless a recording is being captioned.
    public func received(_ segments: [LiveCaptionSegment], from source: LiveCaptionSource, name: String, offset: TimeInterval,
                         changesOnly: Bool = false) {
        guard isActive, meetingID != nil else { return }
        var feed = feeds[source] ?? DeviceCaptionFeed(source: source, name: name, offset: offset)
        feed.name = name
        feed.offset = offset
        if changesOnly { feed.update(segments) } else { feed.segments = segments }
        feeds[source] = feed
        if sourceNames[source.rawValue] != name { sourceNames[source.rawValue] = name }
        dirty = true
        rebuild()
    }

    /// Puts the lines together again, after something `merge` reads changed (the Mac's output route).
    public func rebuild() {
        let all = LiveCaptionMix.adding(Array(feeds.values), to: merge(heard))
        if all != segments { segments = all }
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
        heard = heard.mapValues(Self.heardAsSaid)
        feeds = feeds.mapValues { feed in
            var feed = feed
            feed.segments = Self.heardAsSaid(feed.segments)
            return feed
        }
        rebuild()
        await save()
        // A recording that began while this one saved keeps its own.
        guard generation == current else { return }
        states = [:]
        segments = []
        heard = [:]
        feeds = [:]
        sourceNames = [:]
        meetingID = nil
        statesChanged?()
    }

    /// Writes what's heard now. A failed write is kept by the store, which tries it again on its own (the last save
    /// has no next one), and the next save tries again too.
    public func save() async {
        guard let meetingID, !segments.isEmpty else { return }
        let captions = LiveCaptions(meetingID: meetingID, localeIdentifier: localeIdentifier, segments: segments,
                                    createdAt: createdAt, updatedAt: Date(), sourceNames: sourceNames.isEmpty ? nil : sourceNames)
        // Lines that arrive while it's written mark it again.
        dirty = false
        do {
            try await store.save(captions)
            lastSave = captions.updatedAt
        } catch {
            dirty = true
        }
    }

    /// Saved captions changed outside a recording (filed, speakers labelled afterwards): pages showing
    /// them read them again.
    public func savedElsewhere(at date: Date) { lastSave = date }

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
                    self.statesChanged?()
                    if state == .listening { self.startSaving() }
                }
            },
        ]
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
        captioners = [:]
        order = []
        heard = [:]
        feeds = [:]
        sourceNames = [:]
        states = [:]
        segments = []
        meetingID = nil
        dirty = false
    }

    /// Lines as heard once the audio has ended: none still being revised.
    private static func heardAsSaid(_ segments: [LiveCaptionSegment]) -> [LiveCaptionSegment] {
        segments.map { segment in
            var segment = segment
            segment.isTentative = false
            return segment
        }
    }

    /// Several sources' lines interleaved by time, each tagged with its source; one source's as they are.
    public static func interleaved(_ heard: [LiveCaptionSource: [LiveCaptionSegment]]) -> [LiveCaptionSegment] {
        guard heard.count > 1 else { return heard.values.first ?? [] }
        return heard.sorted { $0.key.rawValue < $1.key.rawValue }
            .flatMap { source, lines in lines.map { line in var line = line; line.source = source; return line } }
            .sorted { $0.start < $1.start }
    }
}
