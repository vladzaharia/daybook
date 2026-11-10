import Darwin
import Foundation

/// Rebuildable app-group snapshots. The old directory name keeps existing Recent Conversations
/// snapshots readable; both the directory and each snapshot are excluded from device backups.
struct SharedWidgetCache {
    static let directoryName = "RecentConversationsCache"
    /// How long a widget that found its snapshot locked away waits to read it again. The app reloads it sooner when it
    /// writes the snapshot after the unlock.
    static let lockedRetry: TimeInterval = 15 * 60

    let fileName: String

    static var groupContainer: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedRecordingState.appGroup)
    }

    func cacheDirectory(in container: URL) -> URL {
        container.appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    func snapshotFile(in container: URL) -> URL {
        cacheDirectory(in: container).appendingPathComponent(fileName)
    }

    /// An unprotected or unreadable snapshot is never handed to the widget.
    func load<Value: Decodable>(_ type: Value.Type, from container: URL? = Self.groupContainer) -> Value? {
        if case .value(let value) = read(type, from: container) { return value }
        return nil
    }

    /// What reading a snapshot found.
    enum Read<Value> {
        case value(Value)
        /// None, or none the widget may show (unprotected, damaged).
        case missing
        /// There, but it can't be read now: "Protect while iPhone is locked" keeps it, and the iPhone is locked.
        case locked
    }

    /// The snapshot, telling one that's there but can't be read while the iPhone is locked from one that isn't there.
    func read<Value: Decodable>(_ type: Value.Type, from container: URL? = Self.groupContainer) -> Read<Value> {
        guard let container else { return .missing }
        let directory = cacheDirectory(in: container)
        let file = snapshotFile(in: container)
        guard Self.isExcluded(directory), Self.isExcluded(file) else {
            return ProtectionClass.cannotOpen(file) ? .locked : .missing
        }
        guard let data = try? Data(contentsOf: file) else { return ProtectionClass.cannotOpen(file) ? .locked : .missing }
        guard let value = try? JSONDecoder().decode(type, from: data) else { return .missing }
        return .value(value)
    }

    /// Prepare and exclude a temporary file inside the already-excluded directory before atomically
    /// replacing the snapshot. A failure never publishes an unexcluded file or uses preferences.
    /// `protects` ("Protect while iPhone is locked"): the folder and the file are class A, unreadable while the iPhone
    /// is locked, as the library is, and a file that can't be given it is never published either. Otherwise they keep
    /// the class they have (the folder's, which switching back puts back, `LibraryProtection`).
    @discardableResult
    func save<Value: Encodable>(_ value: Value, to container: URL? = Self.groupContainer, protects: Bool = false,
                                setExcluded: (inout URL) throws -> Void = Self.setExcluded) -> Bool {
        guard let container else { return false }
        var directory = cacheDirectory(in: container)
        let file = snapshotFile(in: container)
        var temporary = directory.appendingPathComponent(".\(fileName).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.exclude(&directory, setExcluded: setExcluded)
            if protects, ProtectionClass.of(directory) != .complete { try ProtectionClass.set(.complete, on: directory) }
            let data = try JSONEncoder().encode(value)
            try data.write(to: temporary)
            if protects, ProtectionClass.of(temporary) != .complete { try ProtectionClass.set(.complete, on: temporary) }
            try Self.exclude(&temporary, setExcluded: setExcluded)
            guard rename(temporary.path, file.path) == 0 else { return false }
            guard Self.isExcluded(file) else {
                try? FileManager.default.removeItem(at: file)
                return false
            }
            return true
        } catch {
            return false
        }
    }

    private static func isExcluded(_ url: URL) -> Bool {
        let freshURL = URL(fileURLWithPath: url.path)
        return (try? freshURL.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true
    }

    /// Kept injectable so failures at either exclusion point can be exercised without backup services.
    static func setExcluded(_ url: inout URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    private static func exclude(_ url: inout URL, setExcluded: (inout URL) throws -> Void) throws {
        try setExcluded(&url)
        guard isExcluded(url) else { throw CocoaError(.fileWriteUnknown) }
    }
}
