import Combine
import DaybookCore
import Foundation

/// Every recorder the person added: their sessions, persisted configuration, setup, and the
/// library links each needs. It publishes only when devices are added, removed, or renamed;
/// each session publishes its own activity.
@MainActor
public final class DeviceHub: ObservableObject {
    @Published public private(set) var sessions: [DeviceSession] = []
    /// A device being set up. It joins `sessions` once one of its methods is set up.
    @Published public private(set) var pendingSetup: DeviceSession?
    public let environment: DeviceEnvironment
    public var importer: DeviceImporter? { didSet { (sessions + [pendingSetup].compactMap { $0 }).forEach { $0.importer = importer } } }

    private var meetings: [Meeting] = []
    private var libraryReady = false
    private var started = false
    private var librarySubscription: AnyCancellable?
    private var ownershipSubscription: AnyCancellable?
    /// The library's recorder ownership and this device's sync ID, once known.
    private var ownership: (owners: [RecorderOwnership], thisDevice: String)?

    public static let storageKey = "devices.configured"

    public var devices: [ConfiguredDevice] { sessions.map(\.device) }
    public var hasDevices: Bool { !sessions.isEmpty }

    public init(environment: DeviceEnvironment) {
        var environment = environment
        #if DEBUG
        // Demos and the simulator never touch Bluetooth, and the simulator keeps its devices in a
        // throwaway suite so they never reach a real or shared library's preferences.
        let demo = Self.demo
        if let transport = demo.transport { environment.soundcoreTransport = transport }
        if let name = demo.simulatorSuite, let suite = UserDefaults(suiteName: name) {
            suite.removePersistentDomain(forName: name)
            environment.defaults = suite
        }
        #endif
        self.environment = environment
        #if DEBUG
        if demo.isRequested { demo.load?(self); return }
        #endif
        DeviceHubMigration.migrateIfNeeded(environment.defaults)
        let stored = environment.defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([ConfiguredDevice].self, from: $0) } ?? []
        sessions = stored.compactMap(makeSession)
    }

    /// Restores folders and, where the person allowed it, reconnects to remembered recorders.
    public func start() {
        guard !started else { return }
        started = true
        sessions.forEach { $0.activate() }
    }

    public func shutDown() {
        sessions.forEach { $0.shutDown() }
        pendingSetup?.shutDown()
    }

    public func session(_ id: String) -> DeviceSession? { sessions.first { $0.id == id } }
    public func session(kind: String) -> DeviceSession? { sessions.first { $0.kind.id == kind } }

    /// Follows the library: its conversations, and whether it has loaded.
    public func observeLibrary(_ library: AnyPublisher<([Meeting], Bool), Never>) {
        librarySubscription = library.sink { [weak self] meetings, ready in self?.libraryChanged(meetings, ready: ready) }
    }

    /// The library's ownership records changed. Sessions whose recorder another device owns stop
    /// connecting to it; one this device owns, or nobody does, connects as usual.
    public func recorderOwnersChanged(_ owners: [RecorderOwnership], thisDevice: String) {
        ownership = (owners, thisDevice)
        sessions.forEach { $0.applyOwnership(owners, thisDevice: thisDevice) }
    }

    /// Follows the library's ownership records: (owners, this device's sync ID).
    public func observeOwnership(_ owners: AnyPublisher<([RecorderOwnership], String), Never>) {
        ownershipSubscription = owners.sink { [weak self] owners, thisDevice in self?.recorderOwnersChanged(owners, thisDevice: thisDevice) }
    }

    /// The library changed: every device recomputes which of its recordings are already in it.
    public func libraryChanged(_ meetings: [Meeting], ready: Bool) {
        self.meetings = meetings
        libraryReady = libraryReady || ready
        sessions.forEach { $0.libraryChanged(meetings, ready: libraryReady) }
        pendingSetup?.libraryChanged(meetings, ready: libraryReady)
    }

    // MARK: Setup

    /// Starts setting up a device of this kind. A kind that allows only one returns the existing
    /// device, so setup can add its other methods.
    @discardableResult
    public func beginSetup(_ kind: DeviceKind) -> DeviceSession? {
        if !kind.allowsMultiple, let existing = session(kind: kind.id) { return existing }
        if let pendingSetup, pendingSetup.kind == kind { return pendingSetup }
        cancelSetup()
        let number = sessions.filter { $0.kind == kind }.count
        let device = ConfiguredDevice(kind: kind, name: number == 0 ? kind.name : "\(kind.name) \(number + 1)")
        guard let session = makeSession(device) else { return nil }
        session.activate()
        session.libraryChanged(meetings, ready: libraryReady)
        #if DEBUG
        Self.demo.prepareSetup?(session)
        #endif
        pendingSetup = session
        return session
    }

    /// A method of the device being set up is ready: it becomes a configured device.
    public func commitSetup() {
        guard let session = pendingSetup else { return }
        pendingSetup = nil
        sessions.append(session)
        if let ownership { session.applyOwnership(ownership.owners, thisDevice: ownership.thisDevice) }
        persist()
    }

    /// Setup was cancelled before any method was set up.
    public func cancelSetup() {
        guard let session = pendingSetup else { return }
        pendingSetup = nil
        session.connections.forEach { $0.forget() }
        session.shutDown()
    }

    /// Adds a device set up somewhere other than `beginSetup`, with its own ID: an iPhone paired
    /// over Daybook's local link joins under the phone's ID. Returns the session that has the ID
    /// when there is one already.
    @discardableResult
    public func add(_ device: ConfiguredDevice) -> DeviceSession? {
        if let existing = session(device.id) { return existing }
        guard let session = makeSession(device) else { return nil }
        if started { session.activate() }
        session.libraryChanged(meetings, ready: libraryReady)
        sessions.append(session)
        persist()
        return session
    }

    /// Removes a device. Recordings already imported stay in the library.
    public func remove(_ id: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions.remove(at: index)
        session.shutDown()
        session.connections.forEach { $0.forget() }
        persist()
    }

    public func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let session = session(id) else { return }
        session.update { $0.name = String(trimmed.prefix(60)) }
        objectWillChange.send()
    }

    /// Removes the device when its last method is forgotten.
    public func forget(_ method: ConnectionMethodKind, of id: String) {
        guard let session = session(id) else { return }
        session.forget(method)
        if session.setUpMethods.isEmpty { remove(id) }
    }

    // MARK: Sessions

    private func makeSession(_ device: ConfiguredDevice) -> DeviceSession? {
        guard let integration = DeviceCatalog.integration(device.kindID) else { return nil }
        let kind = integration.kind
        let connections: [any DeviceConnection] = kind.implementedMethods.compactMap { method in
            if method.kind == .files {
                // A kind may bring its own files method (Daybook on iPhone's arrive through sync);
                // otherwise it's the shared watched folder.
                return integration.makeConnection(.files, for: device, environment: environment)
                    ?? ImportFolderWatcher(storage: environment.storage(for: device, method: .files))
            }
            return integration.makeConnection(method.kind, for: device, environment: environment)
        }
        let session = DeviceSession(device: device, kind: kind, connections: connections, defaults: environment.defaults)
        session.importer = importer
        session.onDeviceChange = { [weak self] _ in self?.persist() }
        return session
    }

    private func persist() {
        #if DEBUG
        if Self.demo.isRequested { return }
        #endif
        if let data = try? JSONEncoder().encode(devices) { environment.defaults.set(data, forKey: Self.storageKey) }
    }

    #if DEBUG
    /// Debug-only demo hooks. The Mac app's `DeviceDemo` installs them before the hub is made, so
    /// demos and the simulator never touch Bluetooth or the everyday preferences.
    public static var demo = DeviceHubDemo()

    /// Demo only: shows sessions built from demo configuration.
    public func loadDemo(_ devices: [ConfiguredDevice]) -> [DeviceSession] {
        sessions = devices.compactMap(makeSession)
        return sessions
    }
    #endif
}

#if DEBUG
/// What a debug demo replaces in the hub. Inert by default.
@MainActor
public struct DeviceHubDemo {
    /// Replaces the Bluetooth link for Soundcore.
    public var transport: (() -> any SoundcoreTransport)?
    /// A throwaway preferences suite for the simulator's devices, emptied at launch.
    public var simulatorSuite: String?
    /// A demo scenario was asked for: the hub shows its fixtures and persists nothing.
    public var isRequested = false
    /// Fills the hub with the scenario's devices.
    public var load: ((DeviceHub) -> Void)?
    /// Puts a device being set up into the scenario's state.
    public var prepareSetup: ((DeviceSession) -> Void)?

    public init(transport: (() -> any SoundcoreTransport)? = nil, simulatorSuite: String? = nil, isRequested: Bool = false,
                load: ((DeviceHub) -> Void)? = nil, prepareSetup: ((DeviceSession) -> Void)? = nil) {
        self.transport = transport; self.simulatorSuite = simulatorSuite; self.isRequested = isRequested
        self.load = load; self.prepareSetup = prepareSetup
    }
}
#endif

/// Libraries set up before devices existed kept one import folder and one Soundcore recorder in
/// global preferences. The first launch with devices moves them into configured devices.
public enum DeviceHubMigration {
    public enum Legacy {
        public static let folderBookmark = "importFolderBookmark"
        public static let fingerprints = "importedFileFingerprints"
        public static let folderSource = "importFolderSource"
        public static let lastImport = "importFolderLastImport"
        public static let recorder = "soundcoreRememberedRecorder"
        public static let bluetooth = "soundcoreConnectsOverBluetooth"
        public static let automatic = "soundcoreImportsWhenConnected"
        public static let all = [folderBookmark, fingerprints, folderSource, lastImport, recorder, bluetooth, automatic]
    }

    /// Legacy recorder record, as the earlier controller stored it.
    private struct LegacyRecorder: Decodable {
        public var deviceID: UUID
        public var name: String
        public var serial: String?
        public var lastConnectedAt: Date?
    }

    @MainActor
    public static func migrateIfNeeded(_ defaults: UserDefaults) {
        guard defaults.data(forKey: DeviceHub.storageKey) == nil else { return }
        var devices: [ConfiguredDevice] = []
        let soundcoreKind = SoundcoreWorkIntegration().kind
        let otherKind = OtherRecorderIntegration().kind

        if let bookmark = defaults.data(forKey: Legacy.folderBookmark) {
            let fromOtherRecorder = defaults.string(forKey: Legacy.folderSource) == AudioSource.imported.rawValue
            let device = ConfiguredDevice(kind: fromOtherRecorder ? otherKind : soundcoreKind)
            let storage = DeviceStorage(defaults: defaults, prefix: "device.\(device.id).files.")
            storage.set(bookmark, ImportFolderWatcher.Keys.bookmark)
            // "path|size|mtime" fingerprints become name-and-size recording IDs.
            let completed = (defaults.stringArray(forKey: Legacy.fingerprints) ?? []).compactMap { key -> String? in
                let parts = key.components(separatedBy: "|")
                guard parts.count >= 3, let size = Int(parts[parts.count - 2]) else { return nil }
                let path = parts.dropLast(2).joined(separator: "|")
                return ImportFolderWatcher.recordingID(name: (path as NSString).lastPathComponent, size: size)
            }
            storage.set(completed.sorted(), ImportFolderWatcher.Keys.completed)
            storage.set(defaults.object(forKey: Legacy.lastImport), ImportFolderWatcher.Keys.lastImport)
            devices.append(device)
        }

        if let data = defaults.data(forKey: Legacy.recorder), let legacy = try? JSONDecoder().decode(LegacyRecorder.self, from: data) {
            var device = devices.first { $0.kindID == soundcoreKind.id } ?? ConfiguredDevice(kind: soundcoreKind)
            device.importsAutomatically = defaults.bool(forKey: Legacy.automatic)
            if defaults.object(forKey: Legacy.bluetooth) as? Bool == false { device.disabledMethods.insert(.direct) }
            var snapshot = SoundcoreSnapshot(deviceID: legacy.deviceID, name: legacy.name, serial: legacy.serial ?? "")
            snapshot.lastConnectedAt = legacy.lastConnectedAt
            DeviceStorage(defaults: defaults, prefix: "device.\(device.id).direct.").encode(snapshot, "recorder")
            devices.removeAll { $0.id == device.id }
            devices.insert(device, at: 0)
        }

        if let data = try? JSONEncoder().encode(devices) { defaults.set(data, forKey: DeviceHub.storageKey) }
        Legacy.all.forEach(defaults.removeObject(forKey:))
    }
}
