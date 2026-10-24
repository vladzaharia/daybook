import Foundation

/// Presence file format, `Devices/<SHA-256 of the device ID>.json` in the sync folder. Each replica writes only
/// its own file, so presence never conflicts, and the journal never depends on it. Additive fields keep
/// `schemaVersion` 1; an incompatible change must bump it, and readers skip versions they don't know.
/// Daybook versions without presence never list `Devices/` and are unaffected by it.
struct SyncDeviceRecord: Codable, Equatable {
    static let currentFormat = "DaybookDevice"
    static let currentSchemaVersion = 1
    var format = SyncDeviceRecord.currentFormat
    var schemaVersion = SyncDeviceRecord.currentSchemaVersion
    var deviceID: String
    var deviceClass: SyncDeviceClass
    var displayName: String
    var canProcess: Bool
    /// `SyncAudioPolicy` raw value; a string so a future policy never makes the record unreadable.
    var audioPolicy: String?
    /// When the device last completed a sync pass, by its clock. ISO 8601.
    var lastSeen: Date

    func sameIdentity(as other: SyncDeviceRecord) -> Bool {
        var copy = self
        copy.lastSeen = other.lastSeen
        return copy == other
    }
}

enum SyncPresenceFiles {
    static let directory = "Devices"
    static let maximumBytes = 64 * 1024
    static func fileName(for deviceID: String) -> String { SyncDigest.sha256(data: Data(deviceID.utf8)) + ".json" }
    static func encode(_ record: SyncDeviceRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(record)
    }
    /// Lenient: unknown fields are ignored and unknown device classes read as `.other`. Another format, a
    /// newer schema version, or an oversized or malformed file is skipped rather than misread.
    static func decode(_ data: Data) -> SyncDeviceRecord? {
        struct Header: Decodable { var format: String?; var schemaVersion: Int? }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard data.count <= maximumBytes, let header = try? decoder.decode(Header.self, from: data),
              header.format == SyncDeviceRecord.currentFormat, header.schemaVersion == SyncDeviceRecord.currentSchemaVersion,
              let record = try? decoder.decode(SyncDeviceRecord.self, from: data), !record.deviceID.isEmpty else { return nil }
        return record
    }
}

extension LibrarySyncEngine {
    /// Changes how this replica describes itself (for example when a Mac finishes downloading models).
    /// The next pass rewrites the presence record; nil stops writing it.
    public func updateDevice(_ identity: SyncDeviceIdentity?) { device = identity }

    /// Writes this replica's presence record now, regardless of the refresh interval.
    public func publishPresence() throws { try writePresence(now: Date(), force: true) }

    func writePresence(now: Date, force: Bool) throws {
        guard let device else { return }
        let record = SyncDeviceRecord(deviceID: deviceID, deviceClass: device.deviceClass, displayName: device.displayName,
                                      canProcess: device.canProcess, audioPolicy: audioPolicy.rawValue, lastSeen: now)
        if !force, let last = presenceWritten, last.record.sameIdentity(as: record),
           now.timeIntervalSince(last.at) < presenceRefreshInterval { return }
        let directory = remoteRoot.appendingPathComponent(SyncPresenceFiles.directory, isDirectory: true)
        try SyncFiles.noSymlinks(directory, below: remoteRoot)
        try LocalFiles.directory(directory)
        let url = directory.appendingPathComponent(SyncPresenceFiles.fileName(for: deviceID))
        let bytes = try SyncPresenceFiles.encode(record)
        try SyncFiles.coordinateWrite(url, below: remoteRoot) { try LocalFiles.atomicWrite(bytes, to: $0) }
        presenceWritten = (record, now)
    }

    /// Devices known to this library, most recently seen first: every presence record, this device, and
    /// devices seen only on journal entries in the last pass (older Daybook versions, with no presence).
    /// Presence files still downloading are requested and listed on a later call.
    public func knownDevices(now: Date = Date()) throws -> [KnownSyncDevice] {
        var records: [String: SyncDeviceRecord] = [:]
        let directory = remoteRoot.appendingPathComponent(SyncPresenceFiles.directory, isDirectory: true)
        if fm.fileExists(atPath: directory.path) {
            try SyncFiles.noSymlinks(directory, below: remoteRoot)
            for url in try journalFiles(in: SyncPresenceFiles.directory) {
                try Task.checkCancellation()
                if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
                   size.intValue > SyncPresenceFiles.maximumBytes { continue }
                guard let bytes = try? SyncFiles.read(url, below: remoteRoot, cloud: cloud),
                      let record = SyncPresenceFiles.decode(bytes),
                      url.lastPathComponent == SyncPresenceFiles.fileName(for: record.deviceID) else { continue }
                records[record.deviceID] = record
            }
        }
        var devices = records.values.map { record in
            KnownSyncDevice(id: record.deviceID, deviceClass: record.deviceClass, displayName: record.displayName,
                            canProcess: record.canProcess, audioPolicy: record.audioPolicy.flatMap(SyncAudioPolicy.init(rawValue:)),
                            lastSeen: min(record.lastSeen, now), isCurrentDevice: record.deviceID == deviceID)
        }
        if records[deviceID] == nil, let device {
            devices.append(KnownSyncDevice(id: deviceID, deviceClass: device.deviceClass, displayName: device.displayName,
                                           canProcess: device.canProcess, audioPolicy: audioPolicy,
                                           lastSeen: presenceWritten.map { min($0.at, now) }, isCurrentDevice: true))
        }
        for id in journalDeviceIDs.subtracting(records.keys).subtracting([deviceID]).sorted() {
            devices.append(KnownSyncDevice(id: id))
        }
        return devices.sorted { a, b in
            let (x, y) = (a.lastSeen ?? .distantPast, b.lastSeen ?? .distantPast)
            return x == y ? a.id < b.id : x > y
        }
    }
}
