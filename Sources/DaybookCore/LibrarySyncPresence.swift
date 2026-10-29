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
    /// A random ID for this installation. Two devices writing the same record with different ones share a device
    /// ID (one was cloned from the other), and one of them takes a new identity (`sharesIdentity`).
    var installation: String?
    var activity: SyncDeviceActivity?
    /// What this device's Daybook can do that others may need to know before relying on it: `sealed-1`, it reads
    /// and writes encrypted libraries. Additive: older versions write none.
    var features: [String]?
    /// In an encrypted library: whether this device holds the current key, and which key that is.
    var key: SyncDeviceKeyState?
    /// In an encrypted library, the name and activity (anything about conversations), sealed (`SealedPresence`, a
    /// DBSEAL presence object, base64); `displayName` is then empty and `activity` absent.
    var sealed: String?
    /// The compaction proposal this device has acknowledged (LibrarySyncCompaction.swift), by ID. Additive.
    var compaction: String?
    /// When this device ID first wrote its presence (kept from its earlier record). A reinstalled device takes a new ID,
    /// so an earlier ID of the same name and class last seen before this one began is the same device
    /// (`KnownSyncDevice.supersededBy`). Additive: earlier versions write none.
    var firstSeen: Date?

    init(deviceID: String, deviceClass: SyncDeviceClass, displayName: String, canProcess: Bool, audioPolicy: String?, lastSeen: Date,
         installation: String? = nil, activity: SyncDeviceActivity? = nil) {
        self.deviceID = deviceID; self.deviceClass = deviceClass; self.displayName = displayName; self.canProcess = canProcess
        self.audioPolicy = audioPolicy; self.lastSeen = lastSeen; self.installation = installation; self.activity = activity
    }

    private enum CodingKeys: String, CodingKey {
        case format, schemaVersion, deviceID, deviceClass, displayName, canProcess, audioPolicy, lastSeen, installation, activity
        case features, key, sealed, compaction, firstSeen
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        format = try values.decode(String.self, forKey: .format)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        deviceID = try values.decode(String.self, forKey: .deviceID)
        deviceClass = try values.decode(SyncDeviceClass.self, forKey: .deviceClass)
        displayName = try values.decode(String.self, forKey: .displayName)
        canProcess = try values.decode(Bool.self, forKey: .canProcess)
        audioPolicy = try values.decodeIfPresent(String.self, forKey: .audioPolicy)
        lastSeen = try values.decode(Date.self, forKey: .lastSeen)
        installation = try? values.decodeIfPresent(String.self, forKey: .installation)
        // Activity a newer Daybook wrote differently is left out, never a reason to skip the device.
        activity = (try? values.decodeIfPresent(SyncDeviceActivity.self, forKey: .activity)) ?? nil
        features = (try? values.decodeIfPresent([String].self, forKey: .features)) ?? nil
        key = (try? values.decodeIfPresent(SyncDeviceKeyState.self, forKey: .key)) ?? nil
        sealed = (try? values.decodeIfPresent(String.self, forKey: .sealed)) ?? nil
        compaction = (try? values.decodeIfPresent(String.self, forKey: .compaction)) ?? nil
        firstSeen = (try? values.decodeIfPresent(Date.self, forKey: .firstSeen)) ?? nil
    }

    /// The same device, saying the same thing: everything but when it was written.
    func sameIdentity(as other: SyncDeviceRecord) -> Bool {
        var copy = self, compared = other
        copy.lastSeen = other.lastSeen
        copy.activity?.expiresAt = .distantFuture; compared.activity?.expiresAt = .distantFuture
        return copy == compared
    }
}

/// The part of an encrypted library's presence record that's sealed.
struct SealedPresence: Codable, Equatable {
    var displayName: String
    var activity: SyncDeviceActivity?
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
    /// How recently another installation must have written this device's record to count as a second device.
    static let sharedIdentityWindow: TimeInterval = 60 * 60

    /// Changes how this replica describes itself (for example when a Mac finishes downloading models).
    /// The next pass rewrites the presence record; nil stops writing it.
    public func updateDevice(_ identity: SyncDeviceIdentity?) { device = identity }

    /// Writes this replica's presence record now, regardless of the refresh interval.
    public func publishPresence() throws { try writePresence(now: Date(), force: true) }

    /// Rewrites the presence record if it's older than the refresh interval: the controller's timer keeps it fresh
    /// while passes wait (recording, processing).
    public func refreshPresence() throws { try writePresence(now: Date(), force: false) }

    /// What this device is doing now (nil: nothing to say), written into its presence record at once and renewed
    /// with it. Its expiry is set at each write, a few refresh intervals ahead.
    public func publishActivity(_ activity: SyncDeviceActivity?) throws {
        self.activity = activity
        try writePresence(now: Date(), force: true)
    }

    func writePresence(now: Date, force: Bool) throws {
        guard let device else { return }
        var stamped = activity
        stamped?.expiresAt = now.addingTimeInterval(presenceRefreshInterval * 2.5)
        var record = SyncDeviceRecord(deviceID: deviceID, deviceClass: device.deviceClass, displayName: device.displayName,
                                      canProcess: device.canProcess, audioPolicy: audioPolicy.rawValue, lastSeen: now, installation: installation,
                                      activity: stamped)
        record.features = [Self.sealingFeature, Self.compactionFeature]
        record.compaction = state.compactionAck
        // Whether the library is encrypted isn't known yet (the manifest isn't downloaded): say nothing private.
        let known = checkManifestForPresence()
        if let sealing { record.key = SyncDeviceKeyState(state: .ready, id: sealing.current.idHex) }
        else if let waitingForKey { record.key = SyncDeviceKeyState(state: .waiting, id: waitingForKey); record.displayName = ""; record.activity = nil }
        else if !known { record.displayName = ""; record.activity = nil }
        let directory = remoteRoot.appendingPathComponent(SyncPresenceFiles.directory, isDirectory: true)
        let url = directory.appendingPathComponent(SyncPresenceFiles.fileName(for: deviceID))
        let existing = SyncFiles.itemState(url) == .local ? (try? SyncFiles.read(url, below: remoteRoot, cloud: cloud)).flatMap(SyncPresenceFiles.decode) : nil
        // When this device ID began: kept from its record, or now for a record that never said.
        if presenceFirstSeen == nil, existing != nil || SyncFiles.itemState(url) == .absent {
            presenceFirstSeen = existing.flatMap { $0.deviceID == deviceID ? $0.firstSeen : nil } ?? now
        }
        record.firstSeen = presenceFirstSeen
        // Another installation wrote this device's record recently: two devices share this device ID. The one with
        // the greater installation ID yields (and stops writing the record); the other keeps the ID.
        if let installation, let existing, let other = existing.installation, other != installation,
           abs(now.timeIntervalSince(existing.lastSeen)) < Self.sharedIdentityWindow {
            if installation > other { sharesIdentity = true; return }
            // The other device yields; rewrite the record now, so it reads as this one again.
            presenceWritten = nil
        }
        if !force, let last = presenceWritten, last.record.sameIdentity(as: record),
           now.timeIntervalSince(last.at) < presenceRefreshInterval { return }
        try SyncFiles.noSymlinks(directory, below: remoteRoot)
        try LocalFiles.directory(directory)
        // In an encrypted library the name and activity travel sealed.
        var written = record
        if let sealing {
            let inner = try SyncEncoding.data(SealedPresence(displayName: record.displayName, activity: record.activity))
            written.sealed = SealedObject.seal(inner, kind: .presence, key: sealing.current).bytes.base64EncodedString()
            written.displayName = ""; written.activity = nil
        }
        let bytes = try SyncPresenceFiles.encode(written)
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
            var name: String? = record.displayName, activity = record.activity
            // An encrypted library's presence: the name and activity are sealed, readable with the library's key.
            if record.sealed != nil {
                let inner = unsealedPresence(record)
                name = inner?.displayName; activity = inner?.activity
            }
            var known = KnownSyncDevice(id: record.deviceID, deviceClass: record.deviceClass, displayName: name.flatMap { $0.isEmpty ? nil : $0 },
                                        canProcess: record.canProcess, audioPolicy: record.audioPolicy.flatMap(SyncAudioPolicy.init(rawValue:)),
                                        lastSeen: min(record.lastSeen, now), isCurrentDevice: record.deviceID == deviceID, activity: activity)
            known.features = record.features ?? []
            known.keyState = record.key
            known.firstSeen = record.firstSeen.map { min($0, now) }
            return known
        }
        if records[deviceID] == nil, let device {
            var known = KnownSyncDevice(id: deviceID, deviceClass: device.deviceClass, displayName: device.displayName,
                                        canProcess: device.canProcess, audioPolicy: audioPolicy,
                                        lastSeen: presenceWritten.map { min($0.at, now) }, isCurrentDevice: true, activity: activity)
            known.features = [Self.sealingFeature, Self.compactionFeature]
            known.keyState = sealing.map { SyncDeviceKeyState(state: .ready, id: $0.current.idHex) }
                ?? waitingForKey.map { SyncDeviceKeyState(state: .waiting, id: $0) }
            known.firstSeen = presenceFirstSeen.map { min($0, now) }
            devices.append(known)
        }
        for id in journalDeviceIDs.subtracting(records.keys).subtracting([deviceID]).sorted() {
            devices.append(KnownSyncDevice(id: id))
        }
        KnownSyncDevice.noteSuperseded(&devices)
        return devices.sorted { a, b in
            let (x, y) = (a.lastSeen ?? .distantPast, b.lastSeen ?? .distantPast)
            return x == y ? a.id < b.id : x > y
        }
    }
}

extension LibrarySyncEngine {
    /// The sealed part of a presence record, opened with a key held here. Nil without one, or if it doesn't open.
    func unsealedPresence(_ record: SyncDeviceRecord) -> SealedPresence? {
        guard let sealed = record.sealed, let bytes = Data(base64Encoded: sealed), let sealing,
              let opened = try? SealedObject.open(bytes, kind: .presence, libraryID: sealing.libraryID, keyring: sealing.keyring) else { return nil }
        return try? JSONDecoder.presence.decode(SealedPresence.self, from: opened.plaintext)
    }
}

extension JSONDecoder {
    /// Dates as `SyncEncoding` writes them (the default strategy).
    static let presence = JSONDecoder()
}
