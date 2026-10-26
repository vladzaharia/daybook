import AVFoundation
import Combine
import DaybookCaptions
import DaybookCore
import Foundation

/// Soundcore Work's direct method: a connection state machine over a `SoundcoreTransport`.
///
/// - It never scans, connects, or asks for Bluetooth permission on its own until the person sets up
///   a recorder. After that it remembers the recorder and reconnects through the system's record of
///   it (`retrievePeripherals`), falling back to a scan.
/// - An unexpected disconnect retries on a backoff schedule. A connection made for automatic import
///   is let go soon after its imports finish, and one the person made is let go after a few idle
///   minutes, so the phone app can reach the recorder.
/// - It only reads from the recorder. It never deletes, resets, rebinds, or updates it, and starts or
///   pauses a recording only when the person asks.
@MainActor
public final class SoundcoreConnection: ObservableObject, DiscoveringConnection, RecordControlConnection,
                                 LiveListeningConnection, DetailedConnection, ManagedConnection {
    /// Where the connection is. Each phase owns at most one timer.
    public enum Phase: Equatable {
        case idle
        case waitingForRadio(Intent)
        /// Looking for recorders (setup) or for the remembered one (`target`).
        case searching(target: UUID?)
        case connecting(UUID)
        /// The link is up; Daybook is confirming the recorder speaks the expected protocol.
        case opening(UUID)
        case connected(UUID)
        /// A connection for automatic import with no deadline: it completes when the recorder is in range.
        case waitingInRange(UUID)
        case backingOff(attempt: Int)
        case unavailable(RadioState)
    }

    public enum Intent: Equatable { case discover, reconnect, automatic }
    /// Who asked for the connection, which sets how soon it's let go.
    public enum Origin { case person, automatic }

    public let method = ConnectionMethodKind.direct
    public let capabilities: DeviceCapabilities = [.battery, .caseBattery, .storage, .liveListening, .recordControl, .details, .wirelessTransfer]

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var remembered: SoundcoreSnapshot?
    /// The recorder's status while connected.
    @Published public private(set) var info: SoundcoreDeviceInfo?
    @Published public private(set) var statusUpdatedAt: Date?
    @Published public private(set) var recordings: [DeviceRecording] = []
    @Published public private(set) var inventoryUpdatedAt: Date?
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var problem: DeviceProblem?
    @Published public private(set) var discovered: [DiscoveredRecorder] = []
    @Published public private(set) var searchFoundNothing = false
    @Published public private(set) var connectingTo: String?
    @Published public private(set) var recordCommandPending = false
    @Published public private(set) var lastTechnicalProblem: String?
    @Published public private(set) var keyExchangeComplete = false
    @Published public private(set) var reconnectAttempt = 0
    public let live = LiveCapture()

    public var onChange: (() -> Void)?
    /// A Listen Live portion to save: the file, the recording's ID, and its length.
    public var onLiveSaved: ((URL, String, TimeInterval) -> Void)?
    /// Set from the device's preference. Turning it on arms a quiet connection to the remembered recorder.
    public var importsAutomatically: Bool {
        didSet {
            guard importsAutomatically != oldValue else { return }
            if importsAutomatically {
                if case .idle = phase { armAutomatic(after: nil) }
            } else {
                switch phase {
                case .idle, .waitingInRange, .waitingForRadio(.automatic): stopAutomatic()
                default: break
                }
            }
        }
    }
    /// Another device manages this recorder (a synced `RecorderOwnership` whose owner isn't this
    /// device). While set, this device never connects on its own (automatic import, reconnecting,
    /// multipoint) and `connect()` does nothing; a link that's up is let go once it's idle, never in
    /// the middle of a transfer. Clearing it re-arms automatic import as usual.
    @Published public var managedElsewhere: RecorderOwnership? {
        didSet {
            guard managedElsewhere != oldValue else { return }
            if managedElsewhere != nil, oldValue == nil {
                switch phase {
                case .connected, .opening:
                    // Let go once nothing is running; a transfer in progress finishes first.
                    scheduleIdleRelease()
                case .unavailable:
                    deferredIntent = nil
                case .idle:
                    cancelTimer()
                default:
                    disconnect(rearm: false)
                }
            } else if managedElsewhere == nil, case .idle = phase {
                armAutomatic(after: nil)
            }
            publish()
        }
    }

    /// The recorder's serial number, from its status or the remembered recorder.
    public var recorderSerial: String? {
        let serial = info?.serial.isEmpty == false ? info?.serial : remembered?.serial
        return serial?.isEmpty == false ? serial : nil
    }

    /// Settings › Devices › Connect over Bluetooth.
    public var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled { if importsAutomatically { armAutomatic(after: nil) } } else { disconnect(rearm: false) }
        }
    }

    private let storage: DeviceStorage
    private let timing: SoundcoreTiming
    private let stagingDirectory: URL
    private let makeTransport: () -> any SoundcoreTransport
    private let captionHooks: LiveCaptionHooks
    private var transport: (any SoundcoreTransport)?
    private var session: SoundcoreSession?
    private var listeningTask: Task<Void, Never>?
    private var peripheral: UUID?
    private var timer: Task<Void, Never>?
    private var idleTimer: Task<Void, Never>?
    private var origin: Origin = .person
    /// An intent waiting for Bluetooth to come back on.
    private var deferredIntent: Intent?
    private var activity = 0
    private var listing: [SoundcoreRecording] = []
    private var activeRecordingID: UInt32?
    /// The recorder has been listed since this connection was confirmed. Until then `recordings` is
    /// the remembered list, which can name a recording that has since started, grown, or finished.
    private var listedThisConnection = false
    /// Listings under way (a refresh, or one after the recorder's button), for `isRefreshing`.
    private var listingsInFlight = 0
    /// The recording this device asked the recorder to start.
    private var startedHereID: UInt32?
    /// Redraws a remembered recording as unknown once it's too old to show.
    private var expiry: Task<Void, Never>?
    private var names: [UUID: String] = [:]
    /// Listen Live's captioner, its listeners, and where the live audio has reached (16 kHz frames).
    private var captioner: (any LiveCaptioning)?
    private var captionListeners: [Task<Void, Never>] = []
    private var captionSession = UUID()
    private var liveFrames: AVAudioFramePosition = 0
    private var lastLiveProgress = Date.distantPast
    private let liveSleep = SleepAssertion(reason: "Listening live to Soundcore Work")
    private var isDemo = false

    public init(device: ConfiguredDevice, environment: DeviceEnvironment) {
        storage = environment.storage(for: device, method: .direct)
        timing = environment.soundcoreTiming
        stagingDirectory = environment.stagingDirectory
        makeTransport = environment.soundcoreTransport
        captionHooks = environment.liveCaptions
        importsAutomatically = device.importsAutomatically
        isEnabled = device.isEnabled(.direct)
    }

    // MARK: DeviceConnection

    public var state: ConnectionState {
        if managedElsewhere != nil, remembered != nil {
            switch phase {
            case .connected: return .connected
            case .unavailable: return .unavailable
            default: return .notConnected
            }
        }
        switch phase {
        case .idle: return remembered == nil ? .notSetUp : .notConnected
        case .waitingForRadio(.discover), .searching(target: nil): return .searching
        case .waitingForRadio(.automatic), .waitingInRange: return .notConnected
        case .waitingForRadio(.reconnect), .searching, .connecting, .opening:
            return reconnectAttempt > 0 ? .reconnecting : .connecting
        case .backingOff: return .reconnecting
        case .connected: return .connected
        case .unavailable: return .unavailable
        }
    }

    public var isSetUp: Bool { remembered != nil }
    public var lastConnectedAt: Date? { remembered?.lastConnectedAt }

    /// Live while connected. Otherwise the last confirmed values with their time; recording only while
    /// a recording seen then is recent enough to show as "Recording · as of 10:07", else unknown.
    public var status: DeviceStatus? {
        if case .connected = phase, let info {
            return info.status(at: statusUpdatedAt ?? Date(), activeRecordingStart: startDate(of: activeRecordingID))
        }
        guard let snapshot = remembered, let info = snapshot.info, let date = snapshot.statusUpdatedAt else { return nil }
        var status = info.status(at: date, activeRecordingStart: nil)
        if let known = recordingState, known.isRecording {
            status.isRecording = true
            status.recordingStartedAt = known.startedAt
        } else {
            status.isRecording = nil
        }
        return status
    }

    /// What the recorder is recording: live while connected; otherwise as last confirmed, for at most
    /// `SoundcoreTiming.lastKnownRecording` (nobody can see it stop meanwhile), then unknown (nil).
    /// Nil too when it wasn't recording when last seen.
    public var recordingState: SoundcoreRecordingState? { recordingState(at: Date()) }

    public func recordingState(at now: Date) -> SoundcoreRecordingState? {
        if case .connected = phase, let info {
            let active = listedThisConnection ? activeRecordingID : remembered?.activeRecordingID
            return SoundcoreRecordingState(isRecording: info.isRecording, activeRecordingID: active, startedAt: startDate(of: active),
                                           asOf: statusUpdatedAt ?? now, isLive: true, startedHere: active != nil && active == startedHereID)
        }
        guard let snapshot = remembered, let info = snapshot.info, let asOf = snapshot.statusUpdatedAt,
              info.isRecording || snapshot.activeRecordingID != nil,
              now.timeIntervalSince(asOf) < Self.seconds(timing.lastKnownRecording) else { return nil }
        let active = snapshot.activeRecordingID
        return SoundcoreRecordingState(isRecording: info.isRecording, activeRecordingID: active, startedAt: startDate(of: active),
                                       asOf: asOf, isLive: false, startedHere: active != nil && active == startedHereID)
    }

    private func startDate(of id: UInt32?) -> Date? {
        id.flatMap { SoundcoreRecording(id: $0, size: 0).start(correction: clockCorrection) }
    }

    /// The recorder's clock as last measured, when it was this recorder.
    public var clock: SoundcoreClock? {
        guard let clock = remembered?.clock, clock.serial == recorderSerial else { return nil }
        return clock
    }

    private var clockCorrection: TimeInterval { clock?.correction ?? 0 }

    /// A Start the recorder confirmed: its new recording's ID is when it started by its own clock.
    private func measureClock(recordingID: UInt32, sentAt: Date) {
        guard let serial = recorderSerial, var snapshot = remembered else { return }
        let measured = SoundcoreClock(serial: serial, recordingID: recordingID, sentAt: sentAt)
        snapshot.clock = measured
        remembered = snapshot
        persist()
        SoundcoreClocks.record(measured)
        rebuildRecordings()
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    public var summary: String {
        let automatic = importsAutomatically
        if let owner = managedElsewhere, state == .notConnected {
            return "Managed by \(owner.ownerName)"
        }
        switch state {
        case .connected: return "Connected"
        case .searching: return "Looking for Soundcore Work…"
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .unavailable: return problem?.title ?? "Bluetooth isn’t available."
        case .notSetUp: return "Not set up"
        case .notConnected:
            if !isEnabled { return "Off in Settings › Devices." }
            return automatic ? "Connects when it’s nearby." : "Take it out of its case to connect."
        }
    }

    public func activate() {
        guard !isDemo else { return }
        remembered = storage.decode(SoundcoreSnapshot.self, "recorder")
        if let clock { SoundcoreClocks.record(clock) }
        if let remembered {
            listing = remembered.recordings
            inventoryUpdatedAt = remembered.recordingsUpdatedAt
            rebuildRecordings()
        }
        scheduleRecordingExpiry()
        // Publishing first lets the session apply ownership now that the serial is known, so a
        // recorder another device manages is never reached for.
        publish()
        if remembered != nil, isEnabled, importsAutomatically { armAutomatic(after: nil) }
    }

    /// Connect or Reconnect: the remembered recorder directly, then a scan for it.
    public func connect() {
        guard isEnabled, remembered != nil, managedElsewhere == nil else { return }
        if case .connected = phase { return }
        cancelTimer()
        problem = nil
        origin = .person
        reconnectAttempt = 0
        begin(.reconnect)
    }

    public func disconnect() { disconnect(rearm: true) }

    /// After a handoff: waits for the recorder with no deadline (like automatic import, whatever its
    /// preference), because the device that had it may still be finishing before it lets go.
    public func connectWhenAvailable() {
        guard isEnabled, remembered != nil, managedElsewhere == nil else { return }
        switch phase {
        case .idle, .backingOff, .waitingForRadio(.automatic): break
        default: return
        }
        cancelTimer()
        problem = nil
        origin = .person
        reconnectAttempt = 0
        begin(.automatic)
    }

    public func refresh() {
        guard case .connected = phase, let session, !isRefreshing, !live.isListening else { return }
        beginListing()
        Task {
            await perform {
                self.applyStatus(try await session.readStatus())
                self.applyListing(try await session.listRecordings())
            }
            self.endListing()
        }
    }

    /// The recorder started or stopped on its own (its button): list it again, so a new recording
    /// shows as in progress and a finished one appears with its final size. Imports wait meanwhile.
    private func relist() {
        guard let session else { return }
        beginListing()
        Task {
            await perform { self.applyListing(try await session.listRecordings()) }
            self.endListing()
        }
    }

    private func beginListing() {
        listingsInFlight += 1
        if !isRefreshing { isRefreshing = true }
        publish()
    }

    private func endListing() {
        listingsInFlight = max(0, listingsInFlight - 1)
        if listingsInFlight == 0 { isRefreshing = false }
        publish()
    }

    public func refreshIfStale() {
        // The device page appeared: the person is here, so the connection isn't let go as quickly.
        if case .connected = phase { origin = .person; scheduleIdleRelease() }
        guard case .connected = phase, !isRefreshing else { return }
        let stale = { (date: Date?) in date.map { Date().timeIntervalSince($0) > 60 } ?? true }
        if stale(statusUpdatedAt) || stale(inventoryUpdatedAt) { refresh() }
    }

    public func dismissProblem() { problem = nil; publish() }

    public func forget() {
        disconnect(rearm: false)
        cancelTimer()
        remembered = nil
        listing = []
        activeRecordingID = nil
        startedHereID = nil
        expiry?.cancel()
        recordings = []
        inventoryUpdatedAt = nil
        statusUpdatedAt = nil
        problem = nil
        origin = .person
        storage.removeAll()
        publish()
    }

    public func shutDown() {
        disconnect(rearm: false)
        transport?.stopScan()
        transport = nil
    }

    public func transfer(_ recording: DeviceRecording,
                  progress: @escaping @MainActor (TransferPhase, UInt64) -> Void) async throws -> TransferredAudio {
        guard case .connected = phase, let session else { throw DeviceTransferError.notConnected }
        guard let id = UInt32(recording.id) else { throw DeviceTransferError.rejected("Not a Soundcore recording.") }
        let native = listing.first { $0.id == id } ?? SoundcoreRecording(id: id, size: UInt32(clamping: recording.byteCount ?? 0))
        beginActivity()
        defer { endActivity() }
        let url = stagingDirectory.appendingPathComponent("Soundcore-\(id)-\(UUID().uuidString.prefix(8)).wav")
        do {
            _ = try await session.download(native, to: url) { phase, bytes in progress(phase, bytes) }
            keyExchangeComplete = session.keyExchangeComplete
            let serial = info?.serial ?? remembered?.serial
            return TransferredAudio(url: url, isStaged: true, serial: serial?.isEmpty == false ? serial : nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            lastTechnicalProblem = error.localizedDescription
            throw DeviceTransferError(soundcore: error)
        }
    }

    /// Listed since this connection was confirmed, and not being listed again.
    public var isInventoryCurrent: Bool {
        guard case .connected = phase else { return false }
        return listedThisConnection && !isRefreshing
    }

    public func automaticImports(links: DeviceLibraryLinks, since: Date, excluding: Set<String>) -> [DeviceRecording] {
        // The device that manages the recorder imports; its recordings arrive here through sync.
        // Only from a listing made on this connection: the remembered one may still show a recording
        // in progress as finished, and importing it early under its final ID would block the rest.
        guard case .connected = phase, importsAutomatically, managedElsewhere == nil, isInventoryCurrent else { return [] }
        return recordings.filter { recording in
            !recording.isInProgress && links.imported[recording.id] == nil && !excluding.contains(recording.id)
                && (recording.startedAt ?? .distantPast) >= since
        }
    }

    // MARK: Discovery (setup)

    public func search() {
        cancelTimer()
        problem = nil
        origin = .person
        reconnectAttempt = 0
        connectingTo = nil
        begin(.discover)
    }

    public func stopSearching() {
        switch phase {
        case .searching(target: nil), .waitingForRadio(.discover):
            cancelTimer()
            transport?.stopScan()
            phase = .idle
        case .connecting(let id) where connectingTo != nil:
            cancelTimer()
            transport?.disconnect(id)
            peripheral = nil
            connectingTo = nil
            phase = .idle
        default: return
        }
        publish()
    }

    public func connect(to recorder: DiscoveredRecorder) {
        guard let id = UUID(uuidString: recorder.id) else { return }
        transport?.stopScan()
        cancelTimer()
        origin = .person
        reconnectAttempt = 0
        problem = nil
        connectingTo = recorder.id
        open(id, deadline: timing.connect, fallbackToScan: false)
        publish()
    }

    // MARK: Record control

    public func startRecording() { sendRecording(true) }
    public func pauseRecording() { sendRecording(false) }

    private func sendRecording(_ on: Bool) {
        guard case .connected = phase, let session, !recordCommandPending else { return }
        origin = .person
        recordCommandPending = true
        publish()
        let before = activeRecordingID
        Task {
            var confirmed = false
            await perform {
                let sentAt = Date()
                _ = try await session.setRecording(on)
                let deadline = ContinuousClock.now.advanced(by: self.timing.recordConfirm)
                while !confirmed, ContinuousClock.now < deadline {
                    let status = try await session.readStatus()
                    self.applyStatus(status)
                    if status.isRecording == on { confirmed = true } else { try await Task.sleep(for: .milliseconds(500)) }
                }
                if confirmed {
                    self.applyListing(try await session.listRecordings())
                    if on, let started = self.activeRecordingID {
                        self.startedHereID = started
                        // A new recording (not one resumed on firmware that keeps it open) dates the clock.
                        if started != before { self.measureClock(recordingID: started, sentAt: sentAt) }
                    }
                }
            }
            if !confirmed, self.session === session { self.problem = SoundcoreIssue.didNotConfirm.problem }
            self.recordCommandPending = false
            self.publish()
        }
    }

    // MARK: Listen Live

    public func startListening() {
        guard case .connected = phase, let session, !live.isListening else { return }
        guard info?.isRecording == true else { problem = SoundcoreIssue.notRecording.problem; publish(); return }
        origin = .person
        problem = nil
        live.isListening = true
        live.saved = nil
        live.receivedSeconds = 0
        liveSleep.hold(true)
        beginActivity()
        startCaptions()
        publish()
        let staging = stagingDirectory
        listeningTask = Task {
            do {
                let result = try await session.listen(
                    destination: { staging.appendingPathComponent("Soundcore-Live-\($0)-\(UUID().uuidString.prefix(8)).wav") },
                    onPCM: { self.receiveLivePCM($0) },
                    progress: { _, bytes in self.liveProgress(bytes) })
                let id = String(result.recordingID)
                self.live.saved = .init(seconds: result.download.seconds, recordingID: id)
                self.onLiveSaved?(result.download.url, id, result.download.seconds)
            } catch {
                if (error as? SoundcoreError) == .liveFileUnavailable { self.problem = SoundcoreIssue.notRecording.problem }
                else if !(error is CancellationError), (error as? SoundcoreError) != .disconnected { self.lastTechnicalProblem = error.localizedDescription }
            }
            self.live.isListening = false
            self.listeningTask = nil
            self.endCaptions()
            self.liveSleep.hold(false)
            self.endActivity()
            self.publish()
        }
    }

    /// Saves what arrived as a conversation. The recorder keeps recording.
    public func stopListening() {
        // Finish an active transfer first so its received audio survives; cancellation also
        // stops setup or removes a listener waiting behind a different transfer.
        session?.stopListening()
        listeningTask?.cancel()
    }

    private func liveProgress(_ bytes: UInt64) {
        let now = Date()
        guard now.timeIntervalSince(lastLiveProgress) >= 1 else { return }
        lastLiveProgress = now
        live.receivedSeconds = Double(bytes) / SoundcoreRecording.bytesPerSecond
    }

    /// Live captions of what's arriving, on the shared DaybookCaptions engine: tentative, shown while
    /// listening, never saved or used as the transcript. A captioner that can't run or fails changes
    /// only `live.captionState`; the audio is saved regardless.
    private func startCaptions() {
        endCaptions()
        liveFrames = 0
        guard let captioner = captionHooks.makeCaptioner() else { return }
        self.captioner = captioner
        let token = UUID()
        captionSession = token
        live.captionState = .preparing
        captionListeners = [
            Task { [weak self] in
                for await segments in captioner.updates {
                    guard let self, self.captionSession == token else { return }
                    self.live.captions = segments
                }
            },
            Task { [weak self] in
                for await state in captioner.states {
                    guard let self, self.captionSession == token else { return }
                    self.live.captionState = state
                }
            }
        ]
        let locale = captionHooks.locale()
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        Task { await captioner.start(locale: locale, sourceFormat: format) }
    }

    /// Hands each decoded packet to the captioner as it arrives, at the recorder's own rate and in its
    /// own bursts, stamped with its place in the live audio so a burst or a gap keeps its time.
    private func receiveLivePCM(_ buffer: AVAudioPCMBuffer) {
        guard live.isListening, buffer.frameLength > 0 else { return }
        let time = AVAudioTime(sampleTime: liveFrames, atRate: buffer.format.sampleRate)
        liveFrames += AVAudioFramePosition(buffer.frameLength)
        captioner?.append(buffer, at: time)
    }

    /// Listening ended: the captions go with it, and the captioner finishes on its own time.
    private func endCaptions() {
        captionSession = UUID()
        captionListeners.forEach { $0.cancel() }
        captionListeners = []
        if let captioner {
            self.captioner = nil
            Task { await captioner.finish() }
        }
        if !live.captions.isEmpty { live.captions = [] }
        if live.captionState != .off { live.captionState = .off }
    }

    // MARK: Details

    public var details: [DeviceDetail] {
        let status = status
        let connected = state.isConnected
        let asOf = connected ? "" : status.map { ", as of " + $0.updatedAt.formatted(date: .omitted, time: .shortened) } ?? ""
        var rows = [
            DeviceDetail(label: "Recorder battery", value: BatteryFormat.label(status?.battery) + (status?.battery?.level == nil ? "" : asOf)),
            DeviceDetail(label: "Case battery", value: BatteryFormat.label(status?.caseBattery) + (status?.caseBattery?.level == nil ? "" : asOf)),
            DeviceDetail(label: "Storage", value: status?.storage.map(StorageFormat.detail) ?? "Unknown"),
            DeviceDetail(label: "Recording", value: connected ? (info?.isRecording == true ? "Recording" : "Not recording")
                         : status?.isRecording == true ? "Recording, as of " + (status?.updatedAt.formatted(date: .omitted, time: .shortened) ?? "")
                         : "Unknown while not connected"),
            DeviceDetail(label: "Recorder firmware", value: status?.firmware ?? "Unknown"),
            DeviceDetail(label: "Case firmware", value: status?.caseFirmware ?? "Unknown")
        ]
        if let serial = status?.serial ?? (remembered?.serial.isEmpty == false ? remembered?.serial : nil) {
            rows.append(DeviceDetail(label: "Serial number", value: maskedSerial(serial), copyValue: serial))
        } else {
            rows.append(DeviceDetail(label: "Serial number", value: "Unknown"))
        }
        return rows
    }

    public var technicalDetails: [DeviceDetail] {
        var rows = [
            DeviceDetail(label: "Connection", value: "Bluetooth LE, community-documented protocol"),
            DeviceDetail(label: "Audio key exchange", value: keyExchangeComplete ? "Complete" : "Not yet in this connection")
        ]
        if let session, session.rejectedFrames > 0 {
            rows.append(DeviceDetail(label: "Malformed frames ignored", value: "\(session.rejectedFrames)"))
        }
        if let clock {
            rows.append(DeviceDetail(label: "Recorder clock", value: clock.summary))
        }
        return rows
    }

    // MARK: The state machine

    private func begin(_ intent: Intent) {
        // Setup's search is the person's own action; reconnecting and automatic import aren't.
        if intent != .discover, managedElsewhere != nil {
            phase = .idle
            publish()
            return
        }
        phase = .waitingForRadio(intent)
        if transport == nil {
            let made = makeTransport()
            made.events = self
            transport = made
        }
        transport?.activate()
        if transport?.radio == .poweredOn { proceed(intent) } else if let radio = transport?.radio { applyRadio(radio) }
        publish()
    }

    private func proceed(_ intent: Intent) {
        switch intent {
        case .discover: startScan(target: nil)
        case .reconnect: connectRemembered(timed: true)
        case .automatic: connectRemembered(timed: false)
        }
    }

    private func connectRemembered(timed: Bool) {
        guard let transport, let id = remembered?.deviceID else { phase = .idle; return }
        if transport.canReconnect(to: id) {
            if timed { open(id, deadline: timing.reconnect, fallbackToScan: true) }
            else { phase = .waitingInRange(id); peripheral = id; transport.connect(id) }
        } else {
            startScan(target: id)
        }
    }

    private func open(_ id: UUID, deadline: Duration, fallbackToScan: Bool) {
        phase = .connecting(id)
        peripheral = id
        // The deadline starts first: a transport may report failure before `connect` returns.
        startTimer(deadline) { [weak self] in self?.connectTimedOut(id, fallbackToScan: fallbackToScan) }
        transport?.connect(id)
    }

    private func startScan(target: UUID?) {
        phase = .searching(target: target)
        if target == nil { discovered = []; searchFoundNothing = false }
        transport?.startScan()
        startTimer(timing.scan) { [weak self] in self?.scanTimedOut(target) }
    }

    private func scanTimedOut(_ target: UUID?) {
        transport?.stopScan()
        if target != nil {
            failedToReach(.notFound)
        } else {
            searchFoundNothing = discovered.isEmpty
            phase = .idle
        }
        publish()
    }

    private func connectTimedOut(_ id: UUID, fallbackToScan: Bool) {
        transport?.disconnect(id)
        peripheral = nil
        if fallbackToScan { startScan(target: id) } else { failedToReach(.connectTimeout) }
        publish()
    }

    /// An attempt didn't reach the recorder: keep to the backoff schedule if reconnecting, tell the
    /// person if they asked, and otherwise wait quietly for the next automatic attempt.
    private func failedToReach(_ issue: SoundcoreIssue) {
        connectingTo = nil
        if reconnectAttempt > 0 { scheduleReconnect(); return }
        phase = .idle
        if origin == .person { problem = issue.problem } else { armAutomatic(after: timing.automaticCooldown) }
    }

    private func scheduleReconnect() {
        reconnectAttempt += 1
        guard reconnectAttempt <= timing.backoff.count, remembered != nil, isEnabled, managedElsewhere == nil else {
            reconnectAttempt = 0
            phase = .idle
            if importsAutomatically && isEnabled && remembered != nil { armAutomatic(after: nil) }
            publish()
            return
        }
        phase = .backingOff(attempt: reconnectAttempt)
        startTimer(timing.backoff[reconnectAttempt - 1]) { [weak self] in self?.begin(.reconnect) }
        publish()
    }

    private func armAutomatic(after delay: Duration?) {
        guard importsAutomatically, isEnabled, remembered != nil, managedElsewhere == nil else { return }
        origin = .automatic
        if let delay {
            phase = .idle
            startTimer(delay) { [weak self] in self?.armAutomatic(after: nil) }
        } else {
            begin(.automatic)
        }
    }

    private func stopAutomatic() {
        cancelTimer()
        if case .waitingInRange(let id) = phase { transport?.disconnect(id); peripheral = nil }
        phase = .idle
        origin = .person
        publish()
    }

    private func disconnect(rearm: Bool) {
        cancelTimer()
        reconnectAttempt = 0
        connectingTo = nil
        transport?.stopScan()
        if let peripheral { dropLink(peripheral) }
        phase = .idle
        if rearm, importsAutomatically, isEnabled, remembered != nil { armAutomatic(after: timing.automaticCooldown) }
        publish()
    }

    /// Ends the link and everything that belonged to it. Transfers in flight fail as disconnected
    /// (the queue keeps the recording for the reconnect), and Listen Live keeps what arrived.
    private func dropLink(_ id: UUID) {
        idleTimer?.cancel()
        if case .connected = phase, var snapshot = remembered {
            snapshot.lastConnectedAt = Date()
            remembered = snapshot
            persist()
        }
        let closing = session
        session = nil
        closing?.close()
        transport?.disconnect(id)
        peripheral = nil
        info = nil
        activeRecordingID = nil
        listedThisConnection = false
        recordCommandPending = false
        keyExchangeComplete = false
        rebuildRecordings()
        scheduleRecordingExpiry()
    }

    /// A recording seen before the link went is shown with its time until it's too old to show;
    /// then the page redraws it as unknown.
    private func scheduleRecordingExpiry() {
        expiry?.cancel()
        guard let known = recordingState, !known.isLive else { return }
        let remaining = known.asOf.addingTimeInterval(Self.seconds(timing.lastKnownRecording)).timeIntervalSinceNow
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, remaining) + 0.01))
            guard !Task.isCancelled, let self else { return }
            self.objectWillChange.send()
            self.rebuildRecordings()
            self.publish()
        }
    }

    private func applyRadio(_ radio: RadioState) {
        switch radio {
        case .poweredOn:
            if case .waitingForRadio(let intent) = phase { proceed(intent) }
            else if case .unavailable = phase {
                problem = nil
                phase = .idle
                if let intent = deferredIntent { deferredIntent = nil; begin(intent) }
                else if importsAutomatically { armAutomatic(after: nil) }
            }
        case .poweredOff, .unauthorized, .unsupported:
            if case .waitingForRadio(let intent) = phase, intent != .automatic { deferredIntent = intent }
            cancelTimer()
            transport?.stopScan()
            if let peripheral {
                // Linked when the radio went away: reconnect when it's back, so waiting imports resume.
                if case .connected = phase { deferredIntent = .reconnect }
                dropLink(peripheral)
            }
            reconnectAttempt = 0
            connectingTo = nil
            phase = .unavailable(radio)
            let issue: SoundcoreIssue = radio == .poweredOff ? .bluetoothOff : radio == .unauthorized ? .bluetoothDenied : .bluetoothUnsupported
            problem = issue.problem
        case .unknown, .resetting:
            let intent: Intent?
            if case .waitingForRadio(let waiting) = phase { intent = waiting }
            else if case .searching = phase { intent = remembered == nil ? .discover : .reconnect }
            else { intent = peripheral != nil ? .reconnect : deferredIntent }
            cancelTimer()
            transport?.stopScan()
            if let peripheral { dropLink(peripheral) }
            connectingTo = nil
            deferredIntent = nil
            if let intent { phase = .waitingForRadio(intent) }
            else { phase = .unavailable(radio) }
        }
    }

    private func linkIsUp(_ id: UUID) {
        cancelTimer()
        phase = .opening(id)
        peripheral = id
        let transport = transport
        let session = SoundcoreSession(timing: timing) { data in
            guard let transport else { throw SoundcoreError.disconnected }
            try transport.send(data)
        }
        session.onPush = { [weak self] in self?.receivePush($0) }
        self.session = session
        publish()
        Task { await confirm(id, session) }
    }

    /// The recorder answers a status request before it counts as connected.
    private func confirm(_ id: UUID, _ session: SoundcoreSession) async {
        do {
            let status = try await session.readStatus()
            guard self.session === session else { return }
            listedThisConnection = false
            phase = .connected(id)
            reconnectAttempt = 0
            connectingTo = nil
            problem = nil
            remember(id, status)
            applyStatus(status)
            scheduleIdleRelease()
            publish()
            refresh()
        } catch {
            guard self.session === session else { return }
            lastTechnicalProblem = error.localizedDescription
            let reconnecting = reconnectAttempt > 0
            dropLink(id)
            if reconnecting { scheduleReconnect() } else { phase = .idle; problem = SoundcoreIssue.rejected.problem }
            publish()
        }
    }

    private func remember(_ id: UUID, _ status: SoundcoreDeviceInfo) {
        var snapshot = remembered?.deviceID == id ? remembered! : SoundcoreSnapshot(deviceID: id, name: names[id] ?? remembered?.name ?? "Soundcore Work")
        if let name = names[id] { snapshot.name = name }
        snapshot.lastConnectedAt = Date()
        if remembered?.deviceID != id { listing = []; snapshot.recordings = [] }
        remembered = snapshot
        persist()
    }

    private func applyStatus(_ status: SoundcoreDeviceInfo) {
        info = status
        statusUpdatedAt = Date()
        if var snapshot = remembered {
            snapshot.apply(status, at: statusUpdatedAt!)
            remembered = snapshot
            persist()
        }
        rebuildRecordings()
    }

    private func applyListing(_ result: SoundcoreSession.Listing) {
        listing = result.recordings.sorted { $0.id > $1.id }
        activeRecordingID = result.activeRecordingID
        listedThisConnection = true
        inventoryUpdatedAt = Date()
        if var snapshot = remembered {
            snapshot.recordings = Array(listing.prefix(1_000))
            snapshot.recordingsUpdatedAt = inventoryUpdatedAt
            snapshot.activeRecordingID = activeRecordingID
            remembered = snapshot
            persist()
        }
        rebuildRecordings()
        publish()
    }

    private func receivePush(_ push: SoundcoreSession.Push) {
        guard var current = info else { return }
        switch push {
        case .battery(let recorder, let caseLevel):
            current.microphoneBattery = recorder ?? current.microphoneBattery
            current.caseBattery = caseLevel ?? current.caseBattery
        case .charging(let recorder, let caseCharging):
            current.microphoneCharging = recorder
            current.caseCharging = caseCharging
        case .recording(let on):
            current.isRecording = on
            // Either way the list changes: a recording appears in progress, or one is finished.
            relist()
        }
        applyStatus(current)
        publish()
    }

    /// The recording in progress is shown as "Recording now" and never offered for import. It's the
    /// one the recorder names as active, whether or not it says it's recording: firmware may list the
    /// file while it grows, or keep it open while paused. Until this connection has listed it, it's
    /// the one named at the last listing (while that's recent enough to show, when not connected).
    private func rebuildRecordings() {
        let recordingNow: UInt32?
        if case .connected = phase {
            recordingNow = listedThisConnection ? activeRecordingID : remembered?.activeRecordingID
        } else {
            recordingNow = recordingState?.activeRecordingID
        }
        let correction = clockCorrection
        var result = listing.map { $0.deviceRecording(inProgress: $0.id == recordingNow, clockCorrection: correction) }
        if let recordingNow, !listing.contains(where: { $0.id == recordingNow }) {
            result.insert(SoundcoreRecording(id: recordingNow, size: 0).deviceRecording(inProgress: true, clockCorrection: correction), at: 0)
        }
        if result != recordings { recordings = result }
    }

    private func persist() { storage.encode(remembered, "recorder") }

    // MARK: Activity and letting go

    private func perform(_ operation: () async throws -> Void) async {
        beginActivity()
        defer { endActivity() }
        do { try await operation() } catch {
            if (error as? SoundcoreError) != .disconnected, !(error is CancellationError) { lastTechnicalProblem = error.localizedDescription }
        }
    }

    private func beginActivity() {
        activity += 1
        idleTimer?.cancel()
    }

    private func endActivity() {
        activity = max(0, activity - 1)
        scheduleIdleRelease()
    }

    private func scheduleIdleRelease() {
        idleTimer?.cancel()
        guard case .connected = phase, activity == 0, !live.isListening else { return }
        let wait = managedElsewhere != nil ? .zero : origin == .automatic ? timing.automaticIdleRelease : timing.idleRelease
        idleTimer = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.releaseIdle()
        }
    }

    /// Nothing has happened for a while: let the recorder go so the phone app can reach it.
    private func releaseIdle() {
        guard case .connected = phase, activity == 0, !live.isListening else { return }
        disconnect(rearm: true)
    }

    private func startTimer(_ delay: Duration, _ action: @escaping @MainActor () -> Void) {
        timer?.cancel()
        timer = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        }
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
    }

    private func publish() { onChange?() }

    #if DEBUG
    /// Puts the connection into a representative state for screenshots. Never touches Bluetooth.
    public func applyDemo(phase: Phase, remembered: SoundcoreSnapshot?, info: SoundcoreDeviceInfo?, listing: [SoundcoreRecording],
                   activeRecordingID: UInt32?, discovered: [DiscoveredRecorder] = [], searchFoundNothing: Bool = false,
                   problem: DeviceProblem? = nil, reconnectAttempt: Int = 0, connectingTo: String? = nil) {
        isDemo = true
        self.phase = phase
        self.remembered = remembered
        self.info = info
        self.statusUpdatedAt = info == nil ? nil : Date().addingTimeInterval(-20)
        self.listing = listing.sorted { $0.id > $1.id }
        self.activeRecordingID = activeRecordingID
        self.inventoryUpdatedAt = listing.isEmpty ? nil : (info == nil ? remembered?.statusUpdatedAt : Date())
        self.discovered = discovered
        self.searchFoundNothing = searchFoundNothing
        self.problem = problem
        self.reconnectAttempt = reconnectAttempt
        self.connectingTo = connectingTo
        self.keyExchangeComplete = info != nil
        if problem != nil { lastTechnicalProblem = "The peripheral disconnected unexpectedly." }
        rebuildRecordings()
    }
    #endif
}

extension SoundcoreConnection: SoundcoreTransportEvents {
    public func transportRadioChanged(_ radio: RadioState) {
        applyRadio(radio)
        publish()
    }

    public func transportDiscovered(_ id: UUID, name: String, rssi: Int) {
        names[id] = name
        guard case .searching(let target) = phase else { return }
        if let target {
            guard target == id else { return }
            transport?.stopScan()
            open(id, deadline: timing.connect, fallbackToScan: false)
        } else {
            let strength = SignalStrength(rssi: rssi)
            if let index = discovered.firstIndex(where: { $0.id == id.uuidString }) {
                discovered[index].signal = strength
            } else {
                let sameName = discovered.filter { $0.name == name || $0.name.hasPrefix(name + " · ") }.count
                discovered.append(DiscoveredRecorder(id: id.uuidString, name: sameName == 0 ? name : "\(name) · \(sameName + 1)", signal: strength))
            }
        }
        publish()
    }

    public func transportReady(_ id: UUID) {
        switch phase {
        case .connecting(id), .waitingInRange(id): linkIsUp(id)
        default: transport?.disconnect(id)
        }
    }

    public func transportFailed(_ id: UUID, _ failure: TransportFailure) {
        guard peripheral == id else { return }
        cancelTimer()
        peripheral = nil
        switch failure {
        case .unsupported(let detail):
            lastTechnicalProblem = detail
            if session != nil { dropLink(id) }
            reconnectAttempt = 0
            connectingTo = nil
            phase = .idle
            problem = SoundcoreIssue.rejected.problem
        case .connectFailed(let detail):
            lastTechnicalProblem = detail ?? lastTechnicalProblem
            if case .waitingInRange = phase { armAutomatic(after: timing.automaticCooldown) } else { failedToReach(.connectTimeout) }
        }
        publish()
    }

    public func transportDisconnected(_ id: UUID, error: String?) {
        guard peripheral == id else { return }
        if let error { lastTechnicalProblem = error }
        let wasLinked: Bool
        switch phase {
        case .connected, .opening: wasLinked = true
        default: wasLinked = false
        }
        cancelTimer()
        dropLink(id)
        if wasLinked {
            // Unexpected: try again on the backoff schedule. The import queue waits for the reconnect.
            reconnectAttempt = 0
            scheduleReconnect()
        } else {
            failedToReach(.connectTimeout)
        }
        publish()
    }

    public func transportReceived(_ data: Data) {
        session?.receive(data)
    }
}
