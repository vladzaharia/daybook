import Combine
import DaybookCaptions
import DaybookCore
import Foundation

/// Copies transferred audio into the library with its device identity, adding it to `attachTo`
/// when given. Returns the conversation that holds it.
public typealias DeviceImporter = @MainActor (_ url: URL, _ identity: DeviceRecordingIdentity, _ attachTo: UUID?,
                                       _ source: AudioSource) async throws -> UUID

/// One configured device at runtime: its connections, its import queue (one transfer at a time),
/// what the library already holds from it, and its problems. Views observe a session, so a
/// transfer's progress redraws only the device's own surfaces.
@MainActor
public final class DeviceSession: ObservableObject, Identifiable {
    @Published public private(set) var device: ConfiguredDevice
    public let kind: DeviceKind
    /// In the kind's order of preference.
    public private(set) var connections: [any DeviceConnection] = []
    @Published public private(set) var queue = DeviceImportQueue()
    @Published public private(set) var phase: TransferPhase?
    @Published public private(set) var receivedBytes: UInt64 = 0
    /// For the whole batch; nil until about ten seconds of samples.
    @Published public private(set) var secondsLeft: TimeInterval?
    @Published public private(set) var failures: [DeviceImportFailure] = []
    @Published public private(set) var transferProblem: DeviceProblem?
    @Published public private(set) var links = DeviceLibraryLinks()
    /// Listen Live's captions, oldest first: tentative text made on this device from the recorder's
    /// live audio (DaybookCaptions), replaced in place as it's revised. Never the transcript: not
    /// saved, synced, or summarized. Empty when not listening, or when captions can't run here.
    @Published public private(set) var liveCaptions: [LiveCaptionSegment] = []
    /// The recorder's live audio is arriving on this device (Listen Live).
    @Published public private(set) var isListeningLive = false
    /// Selection and presentation state for the device's views.
    public let browser = DeviceBrowser()

    public nonisolated let id: String
    public var importer: DeviceImporter?
    /// Persists a changed configuration.
    public var onDeviceChange: ((ConfiguredDevice) -> Void)?
    /// Libraries load after devices start; nothing imports automatically until then.
    public private(set) var libraryReady = false
    private var meetings: [Meeting] = []
    /// What the links were last built from.
    private var linkInputs: (tracks: [DeviceLibraryIndex.Track], serial: String?)?
    /// How often the links were rebuilt (tests).
    private(set) var linkRebuilds = 0
    private var runner: Task<Void, Never>?
    private var runnerToken: UUID?
    private var rate = TransferRateEstimator()
    private var lastProgressPublish = Date.distantPast
    private var evaluationScheduled = false
    private var subscriptions: Set<AnyCancellable> = []
    private let sleep: SleepAssertion
    private let retryPolicy: DeviceRetryPolicy
    private let defaults: UserDefaults
    private var wasConnected: [ConnectionMethodKind: Bool] = [:]
    /// The library's ownership records and this device's sync ID, kept so ownership is applied again
    /// when the recorder's serial becomes known.
    private var ownership: (owners: [RecorderOwnership], thisDevice: String)?
    /// Handing the recorder to another device: the transfer in progress finishes, nothing else starts.
    @Published public private(set) var isHandingOff = false
    /// Recordings the device that let go of the recorder had waiting; they import here once the
    /// recorder is connected and lists them.
    @Published public private(set) var adoptedImports: [DeviceHandedOffImport] = []
    private var adoptedAt: Date?
    /// Recordings another device imported that haven't reached this library through sync yet, and
    /// when we heard: never offered or imported automatically here meanwhile, so nothing is imported twice.
    public private(set) var arrivingThroughSync: [String: Date] = [:]

    public init(device: ConfiguredDevice, kind: DeviceKind, connections: [any DeviceConnection], defaults: UserDefaults,
         retryPolicy: DeviceRetryPolicy = DeviceRetryPolicy()) {
        self.device = device
        self.id = device.id
        self.kind = kind
        self.defaults = defaults
        self.retryPolicy = retryPolicy
        sleep = SleepAssertion(reason: "Importing recordings from \(device.name)")
        self.connections = connections
        for connection in connections {
            connection.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
            connection.onChange = { [weak self, method = connection.method] in self?.connectionChanged(method) }
        }
        browser.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        if let soundcore = direct as? SoundcoreConnection {
            soundcore.onLiveSaved = { [weak self] url, id, seconds in self?.saveLive(url: url, recordingID: id, seconds: seconds) }
        }
        if let listening = connections.lazy.compactMap({ $0 as? any LiveListeningConnection }).first {
            listening.live.$captions.removeDuplicates().sink { [weak self] in self?.liveCaptions = $0 }.store(in: &subscriptions)
            listening.live.$isListening.removeDuplicates().sink { [weak self] in self?.isListeningLive = $0 }.store(in: &subscriptions)
        }
    }

    public func activate() { connections.forEach { $0.activate() } }

    public func shutDown() {
        stopAll()
        connections.forEach { $0.shutDown() }
    }

    // MARK: Connections

    public func connection(_ method: ConnectionMethodKind) -> (any DeviceConnection)? { connections.first { $0.method == method } }
    public var direct: (any DeviceConnection)? { connection(.direct) }
    public var files: ImportFolderWatcher? { connection(.files) as? ImportFolderWatcher }

    /// The connection whose recordings the list shows: the first method that's set up and on, in
    /// order of preference.
    public var primary: (any DeviceConnection)? {
        connections.first { $0.isSetUp && device.isEnabled($0.method) } ?? connections.first { $0.isSetUp } ?? connections.first
    }

    /// Methods that are set up, in order of preference.
    public var setUpMethods: [ConnectionMethodKind] { connections.filter(\.isSetUp).map(\.method) }

    public var state: ConnectionState { primary?.state ?? .notSetUp }
    public var isConnected: Bool { state.isConnected }
    /// The device page draws the recorder as connected only for a real link, not a watched folder.
    public var isLinked: Bool { direct?.state.isConnected == true }

    /// Another device manages this recorder over Bluetooth: this one doesn't connect, and the
    /// recordings arrive through sync. Nil for kinds without a direct method.
    public var managedElsewhere: RecorderOwnership? { (direct as? any ManagedConnection)?.managedElsewhere }

    /// The recorder's serial number, from its status or the remembered recorder.
    public var recorderSerial: String? {
        if let serial = status?.serial, !serial.isEmpty { return serial }
        return (direct as? any ManagedConnection)?.recorderSerial
    }

    /// Applies the library's ownership records: a recorder another device owns isn't connected here.
    public func applyOwnership(_ owners: [RecorderOwnership], thisDevice: String) {
        ownership = (owners, thisDevice)
        reapplyOwnership()
    }

    private func reapplyOwnership() {
        guard let ownership, let managed = direct as? any ManagedConnection else { return }
        let owner = recorderSerial.flatMap { serial in owners(ownership.owners, serial: serial) }
        let elsewhere = owner.flatMap { $0.ownerID == ownership.thisDevice ? nil : $0 }
        if managed.managedElsewhere != elsewhere { managed.managedElsewhere = elsewhere }
    }

    private func owners(_ owners: [RecorderOwnership], serial: String) -> RecorderOwnership? {
        owners.first { $0.kind == kind.id && $0.serial == serial }
    }
    public var status: DeviceStatus? { direct?.status }
    public var capabilities: DeviceCapabilities { primary?.capabilities ?? [] }

    /// One problem at a time: a transfer's first, then the primary connection's, then any other's.
    public var problem: DeviceProblem? {
        transferProblem ?? primary?.problem ?? connections.lazy.compactMap(\.problem).first
    }

    /// New and already-imported recordings, from the primary connection.
    public var split: DeviceRecordingSplit { DeviceRecordingSplit(recordings: primary?.recordings ?? [], links: links) }

    /// New recordings that aren't queued, for the sidebar badge and the page's Import button. A
    /// recording another device already imported, still on its way through sync, isn't new.
    public var newRecordings: [DeviceRecording] {
        split.new.filter { !queue.contains($0.id) && arrivingThroughSync[$0.id] == nil }
    }

    /// Progress through the batch, for the sidebar ring; nil when idle or waiting to reconnect.
    public var importProgress: Double? {
        guard queue.isActive, !queue.isSuspended else { return nil }
        return queue.fraction(current: phase?.fraction)
    }

    private func connectionChanged(_ method: ConnectionMethodKind) {
        guard let connection = connection(method) else { return }
        // The serial arrives with the first connection; ownership may apply from then on.
        if method == .direct { reapplyOwnership() }
        let connected = connection.state.isConnected
        let becameConnected = connected && wasConnected[method] != true
        wasConnected[method] = connected
        if becameConnected, queue.isSuspended, connection.problem == nil {
            queue.resume()
            if transferProblem?.id == "disconnectedDuringImport" { transferProblem = nil }
        }
        checkLowStorage()
        scheduleEvaluation()
    }

    // MARK: Library

    public func libraryChanged(_ meetings: [Meeting], ready: Bool) {
        libraryChanged(meetings, index: DeviceLibraryIndex(meetings: meetings), ready: ready)
    }

    /// The library changed, with its recorder tracks already indexed (the hub indexes once for every device).
    public func libraryChanged(_ meetings: [Meeting], index: DeviceLibraryIndex, ready: Bool) {
        self.meetings = meetings
        let serial = status?.serial ?? (direct as? SoundcoreConnection)?.remembered?.serial
        let tracks = index.tracks(kind: kind.id)
        // Only this kind's tracks (and the recorder's serial) decide the links; anything else in the
        // library changing leaves them as they are.
        var changed = linkInputs?.tracks != tracks || linkInputs?.serial != serial
        #if DEBUG
        // Demo links match by time, from the whole library.
        if demoLinks != nil { changed = true }
        #endif
        if changed {
            linkInputs = (tracks, serial)
            linkRebuilds += 1
            var updated = DeviceLibraryLinks(tracks: tracks, serial: serial)
            #if DEBUG
            if let demoLinks { updated = demoLinks(meetings) }
            #endif
            if updated != links { links = updated }
        }
        for case let backed as any LibraryBackedConnection in connections { backed.libraryChanged(meetings) }
        if ready && !libraryReady { libraryReady = true }
        // A recording another device imported has arrived (or never will, after a day): it counts normally.
        let stale = Date().addingTimeInterval(-86_400)
        arrivingThroughSync = arrivingThroughSync.filter { links.imported[$0.key] == nil && $0.value > stale }
        scheduleEvaluation()
    }

    /// Conversations recorded on this Mac that overlap a recording.
    public func overlaps(_ recording: DeviceRecording) -> [DeviceOverlap] {
        guard let start = recording.startedAt, let length = recording.length else { return [] }
        return DeviceOverlap.find(start: start, duration: length.seconds, in: meetings)
    }

    // MARK: Preferences

    public func update(_ change: (inout ConfiguredDevice) -> Void) {
        var updated = device
        change(&updated)
        guard updated != device else { return }
        device = updated
        if let soundcore = direct as? SoundcoreConnection {
            soundcore.importsAutomatically = updated.importsAutomatically
            soundcore.isEnabled = updated.isEnabled(.direct)
        }
        if let files {
            if updated.isEnabled(.files) { if files.isSetUp && !files.isWatching { files.connect() } } else { files.disconnect() }
        }
        onDeviceChange?(updated)
        scheduleEvaluation()
    }

    /// Forgets one method. Its waiting imports leave the queue; imported recordings stay.
    public func forget(_ method: ConnectionMethodKind) {
        if queue.current?.method == method { stopCurrent() }
        queue.remove(method: method)
        connection(method)?.forget()
    }

    /// Disconnect: stops this method's imports first, so a deliberate disconnect isn't reported as a problem.
    public func disconnect(_ method: ConnectionMethodKind? = nil) {
        let method = method ?? primary?.method ?? .direct
        if queue.current?.method == method { stopCurrent() }
        queue.remove(method: method)
        if !queue.isActive { batchEnded() }
        connection(method)?.disconnect()
    }

    public func connect() {
        transferProblem = nil
        primary?.dismissProblem()
        primary?.connect()
    }

    /// After a handoff: connects to the recorder as soon as the device that had it lets go.
    public func connectWhenAvailable() {
        transferProblem = nil
        guard let managed = direct as? any ManagedConnection else { return connect() }
        managed.dismissProblem()
        managed.connectWhenAvailable()
    }

    // MARK: Importing

    /// Queues recordings from the primary connection. One transfer runs at a time; the rest wait.
    /// `automatic` marks imports Daybook started on its own (a multipoint recording's file).
    public func importRecordings(_ recordings: [DeviceRecording], attachTo: UUID? = nil, automatic: Bool = false) {
        guard let primary else { return }
        enqueue(recordings, method: primary.method, attachTo: attachTo, automatic: automatic)
    }

    private func enqueue(_ recordings: [DeviceRecording], method: ConnectionMethodKind, attachTo: UUID?, automatic: Bool) {
        guard !recordings.isEmpty else { return }
        let added = queue.enqueue(recordings, method: method, attachTo: attachTo, automatic: automatic)
        guard !added.isEmpty else { return }
        failures.removeAll { added.contains($0.id) }
        if transferProblem?.isTransferProblem == true { transferProblem = nil }
        if !automatic { DeviceNotifications.requestAuthorizationIfNeeded() }
        if let connection = connection(method), !connection.state.isConnected, !automatic, !connection.state.isBusy {
            connection.connect()
        }
        pump()
    }

    /// Stops the recording that's transferring now. What arrived is discarded; the recorder keeps it.
    public func stopCurrent() {
        guard queue.current != nil else { return }
        let imported = queue.imported
        cancelRunner()
        queue.stopCurrent()
        if queue.isActive { pump() } else { batchEnded(imported: imported) }
    }

    /// Stops importing altogether.
    public func stopAll() {
        let imported = queue.imported
        cancelRunner()
        queue.stopAll()
        batchEnded(imported: imported)
    }

    public func removeFromQueue(_ id: String) {
        queue.remove(id)
        if !queue.isActive { batchEnded() }
    }

    /// Recently imported › Try Again.
    public func retry(_ failure: DeviceImportFailure) {
        failures.removeAll { $0.id == failure.id }
        enqueue([failure.recording], method: failure.method, attachTo: nil, automatic: false)
    }

    /// The banner's Try Again: the failed recording again, or the connection again.
    public func tryAgain() {
        let problem = self.problem
        transferProblem = nil
        if problem?.isTransferProblem == true, let failure = failures.first {
            retry(failure)
        } else {
            primary?.dismissProblem()
            if let discovering = primary as? any DiscoveringConnection, primary?.isSetUp != true { discovering.search() }
            else { primary?.connect() }
        }
    }

    public func dismissProblem() {
        if transferProblem != nil { transferProblem = nil } else { primary?.dismissProblem(); connections.forEach { $0.dismissProblem() } }
    }

    private func cancelRunner() {
        runnerToken = nil
        runner?.cancel()
        runner = nil
        phase = nil
        receivedBytes = 0
        secondsLeft = nil
    }

    private func pump() {
        #if DEBUG
        if demoFrozen { return }
        #endif
        guard runner == nil, libraryReady, !isHandingOff, let item = queue.next else { return }
        // A recorder another device manages isn't reached for: its waiting imports move to that device.
        guard device.isEnabled(item.method), let connection = connection(item.method), connection.state.isConnected,
              item.method != .direct || managedElsewhere == nil else {
            queue.suspend()
            return
        }
        // A recorder is listed again after it connects: until then, what's shown may be a recording
        // that has since started or grown. The listing publishes, which pumps again.
        if item.method == .direct, !connection.isInventoryCurrent { return }
        // Still being recorded (or paused, on firmware that keeps the file open): it isn't ready, and
        // importing it now would keep only part of it. It's offered again once it's finished.
        if connection.recordings.contains(where: { $0.id == item.id && $0.isInProgress }) {
            queue.remove(item.id)
            if queue.isActive { pump() } else { batchEnded(imported: queue.imported) }
            return
        }
        guard let started = queue.startNext() else { return }
        let token = UUID()
        runnerToken = token
        if queue.imported + queue.failed == 0 && started.attempts == 0 { rate.reset() }
        phase = .preparing
        receivedBytes = 0
        lastProgressPublish = .distantPast
        sleep.hold(true)
        runner = Task { [weak self] in await self?.run(started, on: connection, token: token) }
    }

    private enum Outcome { case imported, failed(DeviceTransferError, String) }

    private func run(_ item: DeviceImportQueue.Item, on connection: any DeviceConnection, token: UUID) async {
        let outcome: Outcome
        do {
            let audio = try await connection.transfer(item.recording) { [weak self] phase, bytes in
                self?.progress(phase, bytes, token: token)
            }
            defer { if audio.isStaged { try? FileManager.default.removeItem(at: audio.url) } }
            guard runnerToken == token else { return }
            phase = .finishing
            do {
                guard let importer else { throw DaybookError.libraryUnavailable }
                let identity = DeviceRecordingIdentity(kind: kind.id, serial: audio.serial, recordingID: item.recording.id)
                // Another device's import of it may have arrived through sync while this transferred:
                // the library keeps the one it has rather than a second conversation.
                if DeviceLibraryLinks.meeting(holding: identity, in: meetings) == nil {
                    _ = try await importer(audio.url, identity, item.attachTo ?? links.partial[item.recording.id], kind.audioSource)
                }
                connection.didImport(item.recording)
                outcome = .imported
            } catch {
                outcome = .failed(.unreadable(ImportFolderWatcher.failureMessage(error)), ImportFolderWatcher.failureMessage(error))
            }
        } catch is CancellationError {
            return
        } catch let error as DeviceTransferError {
            outcome = .failed(error, Self.message(for: error))
        } catch {
            outcome = .failed(.integrity(error.localizedDescription), Self.message(for: .integrity(error.localizedDescription)))
        }
        guard runnerToken == token else { return }
        finish(item, outcome)
    }

    private func finish(_ item: DeviceImportQueue.Item, _ outcome: Outcome) {
        runner = nil
        runnerToken = nil
        switch outcome {
        case .imported:
            queue.finishCurrent()
            rate.transferFinished()
            failures.removeAll { $0.id == item.id }
            if transferProblem?.isTransferProblem == true { transferProblem = nil }
        case .failed(.disconnected, _), .failed(.notConnected, _):
            // The recording waits at the front and imports again after the reconnect.
            queue.failCurrent(requeue: true)
            transferProblem = problem(for: .disconnected, method: item.method)
        case .failed(let error, _) where retryPolicy.shouldRetry(error, attempts: item.attempts):
            queue.retryCurrent()
        case .failed(let error, let message):
            queue.failCurrent(requeue: false)
            failures.removeAll { $0.id == item.id }
            failures.insert(DeviceImportFailure(recording: item.recording, method: item.method, message: message, date: Date()), at: 0)
            if failures.count > 20 { failures.removeLast(failures.count - 20) }
            if item.method != .files { transferProblem = problem(for: error, method: item.method) }
        }
        phase = nil
        receivedBytes = 0
        if queue.isActive {
            if queue.isSuspended { sleep.hold(false) }
            pump()
        } else {
            batchEnded(imported: queue.imported)
        }
    }

    private func batchEnded(imported: Int = 0) {
        secondsLeft = nil
        phase = nil
        rate.reset()
        sleep.hold(false)
        if imported > 0 { DeviceNotifications.postBatchImported(count: imported, device: device.name, id: device.id) }
    }

    /// Publishes progress at most four times a second.
    private func progress(_ next: TransferPhase, _ bytes: UInt64, token: UUID) {
        guard runnerToken == token else { return }
        let now = Date()
        rate.record(bytes: bytes, at: now)
        let phaseChanged: Bool
        switch (phase, next) {
        case (.receiving?, .receiving): phaseChanged = false
        default: phaseChanged = phase != next
        }
        guard phaseChanged || now.timeIntervalSince(lastProgressPublish) >= 0.25 else { return }
        lastProgressPublish = now
        phase = next
        receivedBytes = bytes
        secondsLeft = rate.secondsLeft(remainingBytes: queue.remainingBytes(currentReceived: bytes))
    }

    /// A Listen Live portion becomes a conversation now; the full recording joins it later.
    private func saveLive(url: URL, recordingID: String, seconds: TimeInterval) {
        // With nowhere to put it, the staged audio goes now (the recorder still has the recording).
        guard let importer else { try? FileManager.default.removeItem(at: url); return }
        let identity = DeviceRecordingIdentity(kind: kind.id, serial: status?.serial, recordingID: DeviceLibraryLinks.partialID(recordingID))
        Task {
            defer { try? FileManager.default.removeItem(at: url) }
            _ = try? await importer(url, identity, links.partial[recordingID] ?? links.imported[recordingID], kind.audioSource)
        }
    }

    // MARK: Automatic import

    private func scheduleEvaluation() {
        guard !evaluationScheduled else { return }
        evaluationScheduled = true
        Task { [weak self] in
            await Task.yield()
            self?.evaluationScheduled = false
            self?.evaluate()
        }
    }

    /// Resumes the queue when its method is back, and queues what should import on its own.
    private func evaluate() {
        #if DEBUG
        if demoFrozen { return }
        #endif
        if queue.isSuspended, let next = queue.waiting.first, connection(next.method)?.state.isConnected == true { queue.resume() }
        guard libraryReady, !isHandingOff else { return }
        importAdopted()
        for connection in connections where device.isEnabled(connection.method) && connection.state.isConnected {
            let excluded = Set(queue.ids + failures.map(\.id) + arrivingThroughSync.keys)
            let candidates = connection.automaticImports(links: links, since: device.automaticImportsSince, excluding: excluded)
            enqueue(candidates, method: connection.method, attachTo: nil, automatic: true)
        }
        pump()
    }

    // MARK: Handing the recorder over (docs/devices.md, "Handing a recorder over")

    /// Stops starting transfers so the recorder can be let go: the one in progress finishes (a
    /// transfer can't resume on another device; it would start again from the beginning), and
    /// automatic import waits.
    public func holdForHandoff() {
        guard !isHandingOff else { return }
        isHandingOff = true
    }

    /// The handoff didn't happen: importing carries on here.
    public func endHandoffHold() {
        guard isHandingOff else { return }
        isHandingOff = false
        scheduleEvaluation()
    }

    /// Nothing would be cut off by letting the recorder go now: no transfer, and no Listen Live.
    public var canLetGo: Bool {
        queue.current == nil && (direct as? any LiveListeningConnection)?.live.isListening != true
    }

    /// The transfer that must finish before the recorder can be let go, with its progress.
    public var transferToFinish: (recording: DeviceRecording, secondsLeft: TimeInterval?)? {
        guard let current = queue.current, current.method == .direct else { return nil }
        return (current.recording, secondsLeft)
    }

    /// Takes the recorder's waiting imports out of the queue, for the device taking it over.
    public func takeWaitingImports() -> [DeviceHandedOffImport] {
        let waiting = queue.waiting.filter { $0.method == .direct }
        guard !waiting.isEmpty else { return [] }
        queue.remove(method: .direct)
        if !queue.isActive { batchEnded() }
        return waiting.map { DeviceHandedOffImport(recordingID: $0.recording.id, attachTo: $0.attachTo, isAutomatic: $0.isAutomatic) }
    }

    /// The recorder came from another device: import what it had waiting once the recorder is
    /// connected here and lists those recordings, and leave alone what it imported until that
    /// reaches this library through sync.
    public func adoptHandedOffImports(_ imports: [DeviceHandedOffImport], alreadyImported: [String], at now: Date = Date()) {
        for id in alreadyImported where links.imported[id] == nil { arrivingThroughSync[id] = now }
        let fresh = imports.filter { item in
            links.imported[item.recordingID] == nil && !queue.contains(item.recordingID)
                && !adoptedImports.contains { $0.recordingID == item.recordingID }
        }
        if !fresh.isEmpty {
            adoptedImports += fresh
            adoptedAt = now
        }
        scheduleEvaluation()
    }

    /// Queues adopted imports the recorder lists. Ones it doesn't list after a fresh listing are
    /// gone from it (or imported already), and are dropped.
    private func importAdopted() {
        guard !adoptedImports.isEmpty, let direct, direct.state.isConnected, direct.isInventoryCurrent,
              let listed = direct.inventoryUpdatedAt else { return }
        let recordings = Dictionary(direct.recordings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var remaining: [DeviceHandedOffImport] = []
        var recordingNow: [DeviceHandedOffImport] = []
        for item in adoptedImports {
            if links.imported[item.recordingID] != nil || arrivingThroughSync[item.recordingID] != nil { continue }
            if let recording = recordings[item.recordingID], !recording.isInProgress {
                // Automatic: the person asked on the other device, not here, so this one doesn't ask
                // for notification permission or keep the recorder longer than an automatic import.
                enqueue([recording], method: .direct, attachTo: item.attachTo, automatic: true)
            } else if recordings[item.recordingID]?.isInProgress == true {
                // Still being recorded: it waits, however many listings it takes.
                recordingNow.append(item)
            } else {
                remaining.append(item)
            }
        }
        adoptedImports = (listed > (adoptedAt ?? .distantFuture) ? [] : remaining) + recordingNow
    }

    /// The conversation a recording goes into once it's imported, when the device that let go of the
    /// recorder named one (a Mac recording that asked the recorder to record too).
    public func conversationWaiting(for recordingID: String) -> UUID? {
        adoptedImports.first { $0.recordingID == recordingID }?.attachTo
    }

    /// Warns once a day when the recorder is nearly full, because Soundcore overwrites its oldest recordings.
    private func checkLowStorage() {
        guard let storage = status?.storage, StorageFormat.isLow(storage), isLinked else { return }
        let key = "device.\(device.id).lowStorageNotifiedAt"
        let last = defaults.object(forKey: key) as? Date
        guard last.map({ Date().timeIntervalSince($0) > 86_400 }) ?? true else { return }
        if DeviceNotifications.postLowStorage(storage, device: device.name, id: device.id) { defaults.set(Date(), forKey: key) }
    }

    // MARK: Copy

    private func problem(for error: DeviceTransferError, method: ConnectionMethodKind) -> DeviceProblem {
        if kind.id == SoundcoreWorkIntegration.id, method == .direct {
            switch error {
            case .disconnected: return SoundcoreIssue.disconnectedDuringImport.problem
            case .stalled: return SoundcoreIssue.stalled.problem
            case .rejected, .notConnected: return SoundcoreIssue.rejected.problem
            case .integrity, .unreadable: return SoundcoreIssue.integrity.problem
            }
        }
        let name = kind.shortName
        switch error {
        case .disconnected:
            return DeviceProblem(id: "disconnectedDuringImport", title: "\(device.name) disconnected during import",
                                 message: "The recording is still on your \(name).",
                                 actions: [.reconnect, .dismiss], isTransferProblem: true)
        default:
            return DeviceProblem(id: "importFailed", title: "This recording couldn’t be imported",
                                 message: "Some audio didn’t arrive intact. The recording is still on your \(name).",
                                 actions: [.tryAgain, .technicalDetails], isTransferProblem: true)
        }
    }

    private static func message(for error: DeviceTransferError) -> String {
        switch error {
        case .disconnected: return "Disconnected during import."
        case .stalled: return "Stopped sending audio."
        case .integrity: return "Some audio didn’t arrive intact."
        case .rejected: return "The recorder didn’t send it."
        case .unreadable(let message): return message
        case .notConnected: return "Not connected."
        }
    }

    #if DEBUG
    /// Demo only: links matched by time, since the demo library has no device identities.
    public var demoLinks: (([Meeting]) -> DeviceLibraryLinks)?
    /// Demo only: nothing imports or resumes on its own.
    public var demoFrozen = false

    /// Demo only: a queue, phase, and problems for screenshots.
    public func applyDemo(queue: DeviceImportQueue, phase: TransferPhase?, secondsLeft: TimeInterval?, failures: [DeviceImportFailure],
                   transferProblem: DeviceProblem?, receivedBytes: UInt64 = 0) {
        self.queue = queue
        self.phase = phase
        self.secondsLeft = secondsLeft
        self.failures = failures
        self.transferProblem = transferProblem
        self.receivedBytes = receivedBytes
    }
    #endif
}

/// A recording that was waiting to import when a recorder moved between devices: the device taking
/// over imports it (docs/devices.md, "Handing a recorder over").
public struct DeviceHandedOffImport: Equatable, Sendable {
    /// The recorder's stable recording ID.
    public var recordingID: String
    /// The conversation it was going into, when one was chosen.
    public var attachTo: UUID?
    public var isAutomatic: Bool

    public init(recordingID: String, attachTo: UUID? = nil, isAutomatic: Bool = false) {
        self.recordingID = recordingID
        self.attachTo = attachTo
        self.isAutomatic = isAutomatic
    }
}

/// Selection and presentation state for one device's views. It's separate from the connections,
/// so selecting a row redraws only the device views.
@MainActor
public final class DeviceBrowser: ObservableObject {
    /// A row in the device's list column.
    public enum Row: Hashable {
        case recording(String)
        /// The recording the device is making right now.
        case recordingNow

        public var recordingID: String? { if case .recording(let id) = self { return id } else { return nil } }
    }

    @Published public var selection: Set<Row> = []
    /// Already in Daybook is collapsed until opened.
    @Published public var showsImported = false
    @Published public var showingDetails = false
    @Published public var showsTechnicalDetails = false
    /// Asks to confirm stopping an import that has received more than a minute of audio.
    @Published public var stopRequest: StopRequest?
    /// Import and Add to › Choose Conversation…
    @Published public var choosingConversation: ConversationChoice?

    public struct StopRequest: Identifiable {
        public let id = UUID()
        /// "Today, 10:02 AM"
        public let title: String
        public let minutesReceived: Int
        public let stopsAll: Bool

        public init(title: String, minutesReceived: Int, stopsAll: Bool) {
            self.title = title
            self.minutesReceived = minutesReceived
            self.stopsAll = stopsAll
        }
    }

    public struct ConversationChoice: Identifiable {
        public let id = UUID()
        public let recordings: [DeviceRecording]

        public init(recordings: [DeviceRecording]) {
            self.recordings = recordings
        }
    }

    public var selectedRecordingIDs: [String] { selection.compactMap(\.recordingID) }
}
