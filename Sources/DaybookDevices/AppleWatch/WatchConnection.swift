import DaybookCore
import Foundation
import Observation

/// Apple Watch's direct method on the iPhone (docs/devices.md, "Apple Watch"): record control over WatchConnectivity,
/// the watch's state, and its recordings, whose segments arrive on their own and are joined here once every one has.
///
/// - **Connected** while WatchConnectivity is activated and the paired watch has Daybook. Reachability isn't the
///   connection: segments and queued messages arrive while Daybook on the watch is in the background. A Start needs
///   it, though: a watch a Start can't reach that isn't recording is left out of a shared recording quietly
///   (`canRecordAlong`).
/// - **A Stop it can't hear now** is queued (`transferUserInfo`), only ever for the recording it names, and counted as
///   done: the watch also follows the iPhone's published context, which no longer names the shared recording, and a
///   watch app that was ended while recording recovers the recording as finished when it next runs. However it ends,
///   the recording is finished, and what's owed is only its audio.
/// - **Its recordings** are the ledger's (`WatchSegmentLedger`, kept with the device): the one in progress, and every
///   one not yet imported. One finished on the watch that's still missing segments is listed as in progress, so
///   nothing imports early. Each segment staged is acknowledged (`.received`, every index held), the only proof of
///   delivery the watch takes; a finished one still missing segments asks again for them (`requestsMissing`), at most
///   once a minute, and not until WatchConnectivity has had a moment after activation to hand over what waited. A
///   complete one is joined (the app's `AppleWatchHooks.join`) and handed over whole, into the conversation it was
///   recorded for, if any (`TransferredAudio.conversationID`), whatever the transport's state, unless the app holds
///   that conversation's imports (`AppleWatchHooks.holdsImport`); its segments are deleted, and the watch told it may
///   delete its copies, only once it's in the library.
/// - **Its button**: a state the watch pushes saying it started or stopped on the wrist, while no Start or Stop of this
///   iPhone's waits for an answer. A join (Daybook opening on it while the iPhone records) is the button only for the
///   recording the iPhone records now; one that joined another (a context that waited) is stopped, only that recording.
@MainActor
@Observable
public final class WatchConnection: RecordingStateConnection, DetailedConnection {
    public let method = ConnectionMethodKind.direct
    public let capabilities: DeviceCapabilities = [.battery, .storage, .recordControl, .details]
    public private(set) var state: ConnectionState = .connecting
    public private(set) var recordings: [DeviceRecording] = []
    public private(set) var inventoryUpdatedAt: Date?
    public private(set) var isRefreshing = false
    public private(set) var problem: DeviceProblem?
    public private(set) var lastConnectedAt: Date?
    public private(set) var recordCommandPending = false
    public private(set) var lastTechnicalProblem: String?
    /// Daybook on the watch can answer now.
    public private(set) var isReachable = false
    public var isSetUp: Bool { true }
    /// WatchConnectivity holds the link itself: nothing to hold.
    public var staysConnected = false
    @ObservationIgnored public var onChange: (() -> Void)?
    @ObservationIgnored public var onButton: ((Bool) -> Void)?
    @ObservationIgnored public var expectsRecording: ((String) -> Bool)?

    /// The watch's state as last heard, and when (this iPhone's clock).
    private var watch: WatchState?
    private var heardAt: Date?
    private var clock = WatchClock()
    private var ledger = WatchSegmentLedger()
    /// A Stop queued while the watch couldn't hear it, until the watch says that recording ended.
    private var owedStop: WatchStop?
    /// The recording this iPhone's Start began.
    private var startedHereID: String?
    /// The watch's words for the last Start it refused.
    private var issue: String?
    private var importsAutomatically: Bool
    /// Starts given up on (no answer in time), by conversation (nil for one of the watch's own): one the watch confirms
    /// late is stopped again.
    @ObservationIgnored private var abandonedStarts: Set<UUID?> = []
    /// The button already told, by recording: started (true) or stopped (false).
    @ObservationIgnored private var buttonTold: [String: Bool] = [:]
    /// Receipts sent again this run for recordings the watch still lists after their import.
    @ObservationIgnored private var resentReceipts: Set<String> = []
    /// The watch that made each recording (`WatchState.watchID`, its tracks' serial), kept with the ledger.
    @ObservationIgnored private var recordedBy: [String: String] = [:]
    /// Recordings with segments staged since their last receipt, sent together on the next turn.
    @ObservationIgnored private var receiptsDue: Set<String> = []
    /// When each finished recording still missing segments last asked for them.
    @ObservationIgnored private var askedAgain: [String: Date] = [:]
    /// How often a finished recording still missing segments asks for them again.
    static let askAgainEvery: TimeInterval = 60
    @ObservationIgnored private var activated = false
    /// `AppleWatchHooks.asksForMissingAfter` has passed since activation: missing segments may be asked for.
    @ObservationIgnored private var mayAskForMissing = false

    private let transport: any WatchTransport
    private let hooks: AppleWatchHooks
    private let storage: DeviceStorage
    /// `<staging>/Watch`.
    private let staging: URL

    /// What's kept across launches, besides the ledger.
    private struct Remembered: Codable, Equatable {
        var watch: WatchState?
        var heardAt: Date?
        var clock = WatchClock()
        var owedStop: WatchStop?
        var startedHereID: String?
        var lastConnectedAt: Date?
        var recordedBy: [String: String]?
    }

    private static let rememberedKey = "watch"
    private static let ledgerKey = "ledger"
    /// What the watch said it's recording counts this long without word from it (a recording runs on with the watch
    /// out of reach, wrist down); after that it's unknown.
    static let lastKnownLifetime: TimeInterval = 12 * 3_600
    /// A pushed state older than this (queued, or delivered late) is news, not the button.
    static let buttonFreshness: TimeInterval = 120
    /// How fast the watch fills its storage: AAC near 64 kbps.
    static let bytesPerHour = Double(WatchAudioFormat.speech.bitRate) / 8 * 3_600

    /// Starts of the watch's recordings on this iPhone's clock, as listed: their IDs don't carry them
    /// (`DeviceRecordingStart.date(of:)`).
    public static var recordingStarts: [String: Date] = [:]

    public init(device: ConfiguredDevice, transport: any WatchTransport, hooks: AppleWatchHooks, storage: DeviceStorage, staging: URL) {
        self.transport = transport
        self.hooks = hooks
        self.storage = storage
        self.staging = staging
        importsAutomatically = device.importsAutomatically
        if let remembered = storage.decode(Remembered.self, Self.rememberedKey) {
            watch = remembered.watch
            heardAt = remembered.heardAt
            clock = remembered.clock
            owedStop = remembered.owedStop
            startedHereID = remembered.startedHereID
            lastConnectedAt = remembered.lastConnectedAt
            recordedBy = remembered.recordedBy ?? [:]
        }
        ledger = storage.decode(WatchSegmentLedger.self, Self.ledgerKey) ?? WatchSegmentLedger()
        // Messages and segments can come before the hub starts (iOS launched Daybook in the background for them).
        transport.onMessage = { [weak self] message, reply in self?.received(message, reply: reply) }
        transport.onSegment = { [weak self] staged in self?.received(staged) }
        transport.onWatchContext = { [weak self] state in self?.heard(state, from: .context) }
        transport.onChange = { [weak self] in self?.transportChanged() }
        hooks.onImportHoldChanged = { [weak self] in self?.publish() }
        relist()
        updateState()
    }

    // MARK: State

    public var summary: String {
        switch state {
        case .connected: return isReachable ? "Connected" : "Daybook isn’t open on the watch"
        case .connecting: return "Connecting…"
        case .unavailable: return problem?.title ?? "Unavailable"
        default: return "Not connected"
        }
    }

    public var status: DeviceStatus? {
        guard let watch else { return nil }
        let recording = currentRecording
        let storage = watch.freeBytes.flatMap { free in
            watch.totalBytes.map { DeviceStatus.Storage(freeBytes: free, totalBytes: $0, bytesPerHour: Self.bytesPerHour) }
        }
        return DeviceStatus(battery: watch.battery.map { DeviceStatus.Battery(level: $0, charging: watch.charging) }, storage: storage,
                            isRecording: knowsRecording ? recording != nil : nil,
                            recordingStartedAt: recording.map { clock.phoneTime($0.startedAt) }, firmware: watch.appVersion,
                            serial: watch.watchID, updatedAt: heardAt ?? watch.asOf)
    }

    /// The watch's words for the last Start it refused ("Apple Watch storage is full.").
    public var recordCommandIssue: String? { issue }

    /// A Start can reach it now (Daybook is open there), or it's recording already: otherwise it sits a shared recording
    /// out quietly, as it does while unavailable.
    public var canRecordAlong: Bool { state.isConnected && (isReachable || status?.isRecording == true) }

    /// Its recordings arrive on their own and are staged here: complete ones import whether or not the watch is paired
    /// or has Daybook now.
    public var importsWithoutConnection: Bool { true }

    /// The recording the watch is making, as last heard: none once a Stop is owed for it.
    private var currentRecording: WatchRecordingInfo? {
        guard let recording = watch?.recording else { return nil }
        if let owed = owedStop, owed.recordingID == nil || owed.recordingID == recording.id { return nil }
        return recording
    }

    /// What the watch is recording is known: it can answer now, or it said recently enough.
    private var knowsRecording: Bool {
        isReachable || heardAt.map { Date().timeIntervalSince($0) < Self.lastKnownLifetime } ?? false
    }

    public func recordingState(at now: Date) -> RecorderRecordingState? {
        guard let recording = currentRecording, let heardAt else { return nil }
        guard isReachable || now.timeIntervalSince(heardAt) < Self.lastKnownLifetime else { return nil }
        return RecorderRecordingState(isRecording: true, recordingID: recording.id, startedAt: clock.phoneTime(recording.startedAt),
                                      asOf: isReachable ? now : heardAt, isLive: isReachable, startedHere: recording.id == startedHereID)
    }

    private func updateState() {
        let next: ConnectionState
        let issue: DeviceProblem?
        if let error = transport.activationError {
            next = .unavailable
            issue = DeviceProblem(id: "watchUnavailable", title: "Apple Watch isn’t available",
                                  message: "This iPhone can’t reach Apple Watch right now.", actions: [])
            lastTechnicalProblem = error
        } else if !transport.isActivated {
            next = .connecting
            issue = nil
        } else if !transport.isPaired {
            next = .unavailable
            issue = DeviceProblem(id: "watchNotPaired", title: "No Apple Watch", message: "Pair an Apple Watch with this iPhone to record on it.",
                                  actions: [])
        } else if !transport.isWatchAppInstalled {
            next = .unavailable
            issue = DeviceProblem(id: "watchAppMissing", title: "Daybook isn’t on Apple Watch",
                                  message: "Install Daybook on your Apple Watch to record there.", actions: [])
        } else {
            next = .connected
            issue = nil
        }
        if next != state { state = next }
        if issue != problem { problem = issue }
    }

    private func transportChanged() {
        let reachable = transport.isActivated && transport.isReachable
        let cameIntoReach = reachable && !isReachable
        if reachable != isReachable { isReachable = reachable }
        updateState()
        if reachable {
            lastConnectedAt = Date()
            persist()
        }
        // Back in reach: its state, a clock sample, and what's missing, while it can answer.
        if cameIntoReach, activated { refresh() } else { publish() }
    }

    private func publish() { onChange?() }

    // MARK: Lifecycle

    public func activate() {
        guard !activated else { return refresh() }
        activated = true
        // What WatchConnectivity has pending arrives first: the ask waits for it.
        let grace = hooks.asksForMissingAfter
        if grace > 0 {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(grace))
                self?.mayAskForMissing = true
                self?.askForMissing()
            }
        } else {
            mayAskForMissing = true
        }
        ledger.prune()
        recordedBy = recordedBy.filter { ledger[$0.key] != nil }
        clearLeftovers()
        adoptStaged()
        if let context = transport.watchContext { heard(context, from: .context) }
        transport.activate()
        transportChanged()
        refresh()
    }

    /// WatchConnectivity is the system's: there's nothing to connect, only the watch to ask again.
    public func connect() { refresh() }
    public func disconnect() {}

    public func dismissProblem() { lastTechnicalProblem = nil }

    public func preferencesChanged(_ device: ConfiguredDevice) {
        guard device.importsAutomatically != importsAutomatically else { return }
        importsAutomatically = device.importsAutomatically
        publish()
    }

    /// Forgets what this iPhone kept of the watch, but not its recordings: the ledger, which watch made each, and the
    /// staged segments stay, so the watch, added again under the same ID (it comes back by itself), imports every one
    /// not in the library yet, and a late segment of one that is never imports twice.
    public func forget() {
        storage.removeAll()
        watch = nil
        heardAt = nil
        clock = WatchClock()
        owedStop = nil
        startedHereID = nil
        lastConnectedAt = nil
        clearLeftovers()
        persist()
        relist()
        publish()
    }

    public func shutDown() {
        transport.onMessage = nil
        transport.onSegment = nil
        transport.onWatchContext = nil
        transport.onChange = nil
    }

    /// Asks the watch what it's recording and samples its clock while it can answer; otherwise lists again from the
    /// ledger and the watch's last published state. Either way the list is fresh afterwards.
    public func refresh() {
        guard !isRefreshing else { return }
        guard transport.isActivated, transport.isReachable else {
            if let context = transport.watchContext { heard(context, from: .context) }
            listed()
            return
        }
        isRefreshing = true
        publish()
        Task {
            await sampleClock()
            do {
                if case .state(let state) = try await transport.send(.status, timeout: hooks.requestTimeout) { heard(state, from: .reply) }
            } catch {
                lastTechnicalProblem = error.localizedDescription
                if let context = transport.watchContext { heard(context, from: .context) }
            }
            isRefreshing = false
            listed()
        }
    }

    private func listed() {
        inventoryUpdatedAt = Date()
        askForMissing()
        relist()
        publish()
    }

    /// Two quick samples while the watch can answer: the less delayed one counts (`WatchClock`).
    private func sampleClock() async {
        for _ in 0..<2 where transport.isReachable {
            let sent = Date()
            guard case .clock(var sample)? = try? await transport.send(.clock(phoneTime: sent), timeout: .seconds(5)) else { return }
            sample.phoneSent = sent
            sample.phoneReceived = Date()
            clock.add(sample)
        }
        persist()
    }

    // MARK: Record control

    public func startRecording() { Task { _ = await recordCommand(.start, deadline: nil) } }
    public func pauseRecording() { Task { _ = await recordCommand(.pause, deadline: nil) } }

    public func recordCommand(_ command: RecordCommand, deadline: Duration?) async -> RecordCommandOutcome {
        guard state.isConnected, !recordCommandPending else { return .unavailable }
        recordCommandPending = true
        publish()
        defer {
            recordCommandPending = false
            publish()
        }
        return command == .start ? await start(within: deadline) : await stop(within: deadline)
    }

    /// Asks the watch to record along with the shared recording, or on its own when there's none (the device page's
    /// Record). It needs Daybook open on the watch.
    private func start(within deadline: Duration?) async -> RecordCommandOutcome {
        issue = nil
        guard transport.isReachable else { return .unavailable }
        let shared = hooks.sharedRecording()
        let start = WatchStart(conversationID: shared?.conversationID, title: shared?.title, startedAt: shared?.startedAt)
        // Asked again: what it confirms now is this Start's, not a late answer to one given up on.
        abandonedStarts.remove(start.conversationID)
        do {
            switch try await transport.send(.start(start), timeout: deadline ?? hooks.requestTimeout) {
            case .state(let state):
                heard(state, from: .reply)
                guard let recording = state.recording else { return .notConfirmed }
                startedHereID = recording.id
                buttonTold[recording.id] = true
                persist()
                return .confirmed
            case .refused(let words):
                issue = words
                return .unavailable
            default:
                return .notConfirmed
            }
        } catch {
            lastTechnicalProblem = error.localizedDescription
            // It may have started without its answer arriving in time: one it confirms later is stopped again.
            if case WatchTransportError.timedOut = error { abandonedStarts.insert(start.conversationID) }
            return .notConfirmed
        }
    }

    /// Stops the recording the watch is making (only that one). Without an answer now, it's owed: queued for when Daybook
    /// next runs there, and certain (see the type's notes), so it's confirmed. Only a known recording is ever owed: a
    /// queued stop of whatever the watch records could end a later recording.
    private func stop(within deadline: Duration?) async -> RecordCommandOutcome {
        let recording = watch?.recording
        let stop = WatchStop(recordingID: recording?.id, conversationID: recording?.conversationID)
        guard recording != nil || transport.isReachable else { return .unavailable }
        // Its stop is this iPhone's, not the watch's button.
        if let id = stop.recordingID { buttonTold[id] = false }
        if transport.isReachable {
            do {
                switch try await transport.send(.stop(stop), timeout: deadline ?? hooks.requestTimeout) {
                case .state(let state):
                    heard(state, from: .reply)
                    if state.recording == nil || (stop.recordingID != nil && state.recording?.id != stop.recordingID) { return .confirmed }
                case .refused(let words):
                    lastTechnicalProblem = words
                default:
                    break
                }
            } catch {
                lastTechnicalProblem = error.localizedDescription
            }
        }
        guard let recording else { return .notConfirmed }
        owe(WatchStop(recordingID: recording.id, conversationID: recording.conversationID))
        return .confirmed
    }

    /// Stops one recording this iPhone doesn't record along with (a join from a context that waited, a Start confirmed
    /// too late): asked now when the watch can hear it, owed otherwise.
    private func stopOnly(_ recording: WatchRecordingInfo) {
        let stop = WatchStop(recordingID: recording.id)
        buttonTold[recording.id] = false
        guard transport.isReachable else { return owe(stop) }
        Task {
            if case .state(let state)? = try? await transport.send(.stop(stop), timeout: hooks.requestTimeout) {
                heard(state, from: .reply)
                if state.recording?.id != recording.id { return }
            }
            owe(stop)
        }
    }

    /// Never a stop that names no recording.
    private func owe(_ stop: WatchStop) {
        guard stop.recordingID != nil else { return }
        transport.queue(.stop(stop))
        owedStop = stop
        if let id = stop.recordingID { buttonTold[id] = false }
        persist()
        relist()
    }

    // MARK: What the watch says

    private enum Source { case pushed, reply, context }

    private func received(_ message: WatchMessage, reply: ((WatchReply) -> Void)?) {
        switch message {
        case .state(let state):
            heard(state, from: .pushed)
            // Nothing is owed for a state; one the watch waits on is answered with what the iPhone records.
            reply?(.context(hooks.phoneContext()))
        case .context:
            reply?(.context(hooks.phoneContext()))
        default:
            reply?(.refused("Daybook on this iPhone doesn’t take that message."))
        }
    }

    private func heard(_ state: WatchState, from source: Source) {
        // The watch's published state can be older than a message already heard.
        if source == .context, let current = watch, state.asOf < current.asOf { return }
        let previous = watch
        watch = state
        // A published state is as old as the watch says (one from before a relaunch, say); anything else is news now.
        heardAt = source == .context ? min(Date(), clock.phoneTime(state.asOf)) : Date()
        if source != .context { lastConnectedAt = heardAt }
        for recording in [state.recording].compactMap({ $0 }) + state.finished {
            if recordedBy[recording.id] == nil { recordedBy[recording.id] = state.watchID }
            if ledger[recording.id]?.imported == true {
                // Imported here, yet the watch still has it: its receipt didn't arrive. Once a run.
                if resentReceipts.insert(recording.id).inserted { sendReceipt(recording.id, segments: recording.segmentIndices) }
                continue
            }
            ledger.update(recording)
            if recording.isFinished, recording.segmentIndices.isEmpty {
                // Nothing was recorded: nothing to import, and the watch may forget it.
                ledger.markImported(recording.id)
                sendReceipt(recording.id, segments: [])
            }
        }
        if let owed = owedStop, state.recording == nil || (owed.recordingID != nil && state.recording?.id != owed.recordingID) {
            owedStop = nil
        }
        if source != .reply, let recording = state.recording, state.change == .startedByPhone,
           abandonedStarts.remove(recording.conversationID) != nil {
            // A Start given up on that the watch confirmed late: what the cascade said ("didn't start") stays true. What
            // it recorded meanwhile imports into that conversation (`transfer`), never one of its own.
            stopOnly(recording)
        }
        persist()
        relist()
        if source == .pushed { button(state, previous: previous) }
        publish()
    }

    /// The watch's own Record or Stop (or Daybook opening on it and joining), pushed as it happened.
    private func button(_ state: WatchState, previous: WatchState?) {
        guard !recordCommandPending, let change = state.change else { return }
        if change == .joined, let recording = state.recording, buttonTold[recording.id] == nil, recording.id != startedHereID,
           recording.conversationID == nil || recording.conversationID != hooks.sharedRecording()?.conversationID {
            // It joined a recording this iPhone doesn't record now (from a context that waited): nothing starts here,
            // and only that recording stops, however late this is heard.
            return stopOnly(recording)
        }
        guard abs(Date().timeIntervalSince(clock.phoneTime(state.asOf))) < Self.buttonFreshness else { return }
        switch change {
        case .startedOnWatch, .joined:
            guard let id = state.recording?.id, buttonTold[id] != true, id != startedHereID, expectsRecording?(id) != true else { return }
            buttonTold[id] = true
            onButton?(true)
        case .stoppedOnWatch:
            guard let id = previous?.recording?.id ?? state.finished.last?.id, buttonTold[id] != false else { return }
            buttonTold[id] = false
            onButton?(false)
        default:
            break
        }
    }

    // MARK: Segments

    private func received(_ staged: WatchStagedSegment) {
        let segment = staged.segment
        if ledger[segment.recordingID]?.imported == true {
            // Late, for a recording already in the library.
            try? FileManager.default.removeItem(at: staged.url)
            try? FileManager.default.removeItem(at: WatchStaging.sidecar(of: staged.url))
            return
        }
        ledger.received(segment)
        // The watch that sends it is the one paired now; a state about its recording may not have come first.
        if recordedBy[segment.recordingID] == nil, let watchID = watch?.watchID { recordedBy[segment.recordingID] = watchID }
        persist()
        acknowledge(segment.recordingID)
        relist()
        publish()
    }

    /// Segments staged before a relaunch that the ledger doesn't have yet (the app ended between the two), and ones it
    /// has whose files are gone, forgotten so the watch is asked for them again (`askForMissing`).
    private func adoptStaged() {
        let manager = FileManager.default
        var changed = false
        for staged in WatchStaging.staged(in: staging) {
            let id = staged.segment.recordingID
            if ledger[id]?.imported == true {
                try? manager.removeItem(at: staged.url)
                try? manager.removeItem(at: WatchStaging.sidecar(of: staged.url))
            } else if ledger[id]?.segments[staged.segment.index] == nil {
                ledger.received(staged.segment)
                acknowledge(id)
                changed = true
            }
        }
        for entry in ledger.pending where !entry.segments.isEmpty {
            guard let folder = WatchStaging.recordingFolder(entry.recording.id, in: staging) else { continue }
            let kept = entry.segments.values.filter { manager.fileExists(atPath: folder.appendingPathComponent($0.fileName).path) }
            guard kept.count != entry.segments.count else { continue }
            ledger.remove(entry.recording.id)
            ledger.update(entry.recording, at: entry.firstSeen)
            for segment in kept { ledger.received(segment, at: entry.firstSeen) }
            changed = true
        }
        if changed { persist() }
    }

    /// What a join or an import left in `<staging>/Watch` when the app was ended under it: the joined file, the hard
    /// links it joined (`.join-…`), the assembler's own (`.joining-…`, `.silence-…`). Recordings' folders stay.
    private func clearLeftovers() {
        let manager = FileManager.default
        for item in (try? manager.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
            let isFolder = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if item.lastPathComponent.hasPrefix(".") || !isFolder { try? manager.removeItem(at: item) }
        }
    }

    // MARK: Receipts

    /// A segment of the recording was staged: the watch hears which it holds once what arrives together has.
    private func acknowledge(_ id: String) {
        guard receiptsDue.insert(id).inserted, receiptsDue.count == 1 else { return }
        Task { [weak self] in
            await Task.yield()
            self?.sendReceiptsDue()
        }
    }

    private func sendReceiptsDue() {
        let due = receiptsDue
        receiptsDue = []
        for id in due.sorted() { tellHeld(id) }
    }

    /// Every segment of the recording this iPhone holds: what the watch counts as delivered. Only with `asking` (a
    /// finished recording still missing segments) does the watch send again what it leaves out: one after a segment is
    /// staged never asks, since later ones may simply not have arrived yet.
    private func tellHeld(_ id: String, asking: Bool = false) {
        guard let entry = ledger[id], !entry.imported else { return }
        transport.tell(.received(WatchReceipt(recordingID: id, segments: entry.segments.keys.sorted(), imported: false,
                                              requestsMissing: asking)))
    }

    /// Finished recordings still missing segments (lost on the way, or never kept here) ask for them again: at
    /// activation, on a refresh, and when the watch comes within reach, at most once a minute each. Not until
    /// `AppleWatchHooks.asksForMissingAfter` has passed since activation (a task asks then), so what WatchConnectivity
    /// delivers as Daybook launches arrives first.
    private func askForMissing(now: Date = Date()) {
        guard mayAskForMissing else { return }
        for entry in ledger.pending where entry.recording.isFinished && !entry.missing.isEmpty {
            let id = entry.recording.id
            if let asked = askedAgain[id], now.timeIntervalSince(asked) < Self.askAgainEvery { continue }
            askedAgain[id] = now
            tellHeld(id, asking: true)
        }
    }

    // MARK: Recordings

    private func relist() {
        var list: [DeviceRecording] = []
        for entry in ledger.pending {
            let recording = entry.recording
            let start = clock.phoneTime(recording.startedAt)
            Self.recordingStarts[recording.id] = start
            let length: RecordingLength? = recording.duration > 0
                ? (recording.isFinished ? .exact(recording.duration) : .estimated(recording.duration)) : nil
            list.append(DeviceRecording(id: recording.id, startedAt: start, length: length,
                                        byteCount: recording.byteCount > 0 ? recording.byteCount : nil, isInProgress: !entry.isComplete))
        }
        list.sort { ($0.startedAt ?? .distantPast, $0.id) > ($1.startedAt ?? .distantPast, $1.id) }
        if list != recordings { recordings = list }
    }

    public func transfer(_ recording: DeviceRecording,
                         progress: @escaping @MainActor (TransferPhase, UInt64) -> Void) async throws -> TransferredAudio {
        guard let entry = ledger[recording.id], !entry.imported else {
            throw DeviceTransferError.rejected("This recording is no longer on Apple Watch.")
        }
        guard entry.isComplete else { throw DeviceTransferError.integrity("Not every part of this recording has arrived yet.") }
        guard let folder = WatchStaging.recordingFolder(recording.id, in: staging) else {
            throw DeviceTransferError.rejected("This recording can’t be read.")
        }
        let segments = entry.recording.segmentIndices.compactMap { entry.segments[$0] }
            .map { WatchStagedSegment(url: folder.appendingPathComponent($0.fileName), segment: $0) }
        guard !segments.isEmpty, segments.allSatisfy({ FileManager.default.fileExists(atPath: $0.url.path) }) else {
            throw DeviceTransferError.unreadable("Part of this recording is missing on this iPhone.")
        }
        progress(.preparing, 0)
        let output = staging.appendingPathComponent("\(recording.id).m4a")
        try? FileManager.default.removeItem(at: output)
        do {
            if segments.count == 1, let only = segments.first, abs(only.segment.startOffset) < 0.001, only.segment.cleanlyClosed {
                // One whole segment is the recording, as it is. A copy: the segment stays until the import is done.
                try FileManager.default.copyItem(at: only.url, to: output)
            } else {
                guard let join = hooks.join else { throw DeviceTransferError.rejected("This iPhone can’t join the recording’s parts.") }
                try await join(segments, output)
            }
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: output)
            if error is CancellationError || error is DeviceTransferError { throw error }
            lastTechnicalProblem = error.localizedDescription
            throw DeviceTransferError.integrity(error.localizedDescription)
        }
        let bytes = UInt64((try? output.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        progress(.receiving(fraction: 1), bytes)
        // Into the conversation it was recorded for, whether or not this iPhone's shared recording remembers it (a
        // relaunch, a join known only from the context); by the watch that made it, which may not be the one paired now.
        return TransferredAudio(url: output, isStaged: true, serial: recordedBy[recording.id] ?? watch?.watchID,
                                conversationID: entry.recording.conversationID)
    }

    /// Complete recordings not in the library: every recording the watch makes lands in Daybook, the ones it made on
    /// its own too, each in the conversation it was made for when it has one (`transfer`), however the watch is now.
    public func automaticImports(links: DeviceLibraryLinks, since: Date, excluding: Set<String>) -> [DeviceRecording] {
        // Imported, but the app ended before it heard (`didImport`): finished now.
        for entry in ledger.complete where links.imported[entry.recording.id] != nil { finishImport(entry.recording.id) }
        guard isInventoryCurrent, importsAutomatically else { return [] }
        // One made for a conversation the app holds (its own recording of it may not be filed yet) waits.
        let complete = Set(ledger.complete.filter { $0.recording.conversationID.map(hooks.holdsImport) != true }.map(\.recording.id))
        return recordings.filter { complete.contains($0.id) && links.imported[$0.id] == nil && !excluding.contains($0.id) }
    }

    public func didImport(_ recording: DeviceRecording) {
        finishImport(recording.id)
    }

    /// It's in the library: its segments go, and the watch may delete its copies.
    private func finishImport(_ id: String) {
        guard let entry = ledger[id], !entry.imported else { return }
        ledger.markImported(id)
        persist()
        if let folder = WatchStaging.recordingFolder(id, in: staging) { try? FileManager.default.removeItem(at: folder) }
        sendReceipt(id, segments: entry.recording.segmentIndices)
        relist()
        publish()
    }

    private func sendReceipt(_ id: String, segments: [Int]) {
        transport.queue(.received(WatchReceipt(recordingID: id, segments: segments, imported: true)))
    }

    private func persist() {
        storage.encode(Remembered(watch: watch, heardAt: heardAt, clock: clock, owedStop: owedStop, startedHereID: startedHereID,
                                  lastConnectedAt: lastConnectedAt, recordedBy: recordedBy), Self.rememberedKey)
        storage.encode(ledger, Self.ledgerKey)
    }

    // MARK: Details

    public var details: [DeviceDetail] {
        let status = status
        let asOf = isReachable ? "" : status.map { ", as of " + $0.updatedAt.formatted(date: .omitted, time: .shortened) } ?? ""
        return [
            DeviceDetail(label: "Battery", value: BatteryFormat.label(status?.battery) + (status?.battery?.level == nil ? "" : asOf)),
            DeviceDetail(label: "Storage", value: status?.storage.map(StorageFormat.detail) ?? "Unknown"),
            DeviceDetail(label: "Recording", value: status?.isRecording.map { ($0 ? "Recording" : "Not recording") + asOf } ?? "Unknown"),
            DeviceDetail(label: "Model", value: watch?.model ?? "Unknown"),
            DeviceDetail(label: "Daybook on the watch", value: watch?.appVersion ?? "Unknown")
        ]
    }

    public var technicalDetails: [DeviceDetail] {
        var rows = [
            DeviceDetail(label: "Connection", value: "WatchConnectivity, protocol \(WatchLink.version)"),
            DeviceDetail(label: "Daybook on the watch", value: !transport.isWatchAppInstalled ? "Not installed"
                         : isReachable ? "Open" : "Installed, not open")
        ]
        if let offset = clock.offset {
            rows.append(DeviceDetail(label: "Watch clock", value: String(format: "%+.3f s from this iPhone’s", offset)))
        }
        let waiting = ledger.pending.filter { $0.recording.isFinished && !$0.isComplete }
        if !waiting.isEmpty {
            let parts = waiting.reduce(0) { $0 + $1.missing.count }
            rows.append(DeviceDetail(label: "Waiting for audio", value: "\(parts) part\(parts == 1 ? "" : "s") of \(waiting.count) recording\(waiting.count == 1 ? "" : "s")"))
        }
        if owedStop != nil { rows.append(DeviceDetail(label: "Stop", value: "Queued until Daybook runs on the watch")) }
        if let watchID = watch?.watchID { rows.append(DeviceDetail(label: "Installation", value: String(watchID.prefix(8)), copyValue: watchID)) }
        return rows
    }
}
