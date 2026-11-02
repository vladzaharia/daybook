import Foundation

/// A device's presence record put into a sync folder directly, in the format every replica writes and reads
/// (`SyncDeviceRecord`, `Devices/<SHA-256 of the device ID>.json`; docs/icloud-sync.md, "Devices and
/// presence"): what a device that last synced there at `lastSeen` would have left. For debug runs and tests
/// that need, say, a Mac that last synced two hours ago, without hand-written JSON.
public enum SyncPresenceRecord {
    public static func write(deviceID: String, displayName: String, deviceClass: SyncDeviceClass, canProcess: Bool,
                             audioPolicy: SyncAudioPolicy?, lastSeen: Date, intoSyncFolder folder: URL) throws {
        let record = SyncDeviceRecord(deviceID: deviceID, deviceClass: deviceClass, displayName: displayName, canProcess: canProcess,
                                      audioPolicy: audioPolicy?.rawValue, lastSeen: lastSeen)
        let directory = folder.appendingPathComponent(SyncPresenceFiles.directory, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try SyncPresenceFiles.encode(record).write(to: directory.appendingPathComponent(SyncPresenceFiles.fileName(for: deviceID)),
                                                   options: .atomic)
    }
}
