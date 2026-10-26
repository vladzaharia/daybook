import XCTest
@testable import DaybookCore

/// Random histories, replayed from fixed seeds: an eager Mac, an on-demand iPhone, and a Mac still on the version 1
/// engine edit, delete, restore, add and remove photos, and ask for and claim processing in random order, going
/// offline and back. Once everyone has synced, the current replicas hold the same library and the older one the
/// same conversations. Temporary folders and synthetic data only; a few seconds per seed.
final class LibrarySyncConvergenceTests: XCTestCase {
    private var root: URL!
    private var remote: URL { root.appendingPathComponent("Remote") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookConvergence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testRandomHistoriesConverge() async throws {
        for seed: UInt64 in [1, 7, 42, 2026] {
            try FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try await run(seed: seed, steps: 130)
        }
    }

    // MARK: The run

    private func run(seed: UInt64, steps: Int) async throws {
        var random = ConvergenceRandom(seed: seed)
        let devices = [try Replica(.mac, root: root, remote: remote), try Replica(.phone, root: root, remote: remote),
                       try Replica(.legacy, root: root, remote: remote)]
        var clock = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var counter = 0
        for _ in 0..<steps {
            clock.addTimeInterval(Double(random.next(upTo: 120)))
            counter += 1
            let device = devices[random.next(upTo: devices.count)]
            switch random.next(upTo: 100) {
            case 0..<8:
                let id = random.uuid()
                device.save(Meeting(id: id, title: "Conversation \(counter)", date: clock, updatedAt: clock))
            case 8..<23:
                device.edit(random: &random) { $0.setNotes($0.notes.isEmpty ? "P\(counter) \(device.name)" : $0.notes + "\nP\(counter) \(device.name)") }
            case 23..<29:
                device.edit(random: &random) { $0.title = "Title \(counter)" }
            case 29..<35:
                let tag = ["work", "follow-up", "idea"][random.next(upTo: 3)]
                device.edit(random: &random) { meeting in
                    var tags = Set(meeting.tags ?? [])
                    if tags.contains(tag) { tags.remove(tag) } else { tags.insert(tag) }
                    meeting.tags = tags.sorted()
                }
            case 35..<40:
                let time = Double(random.next(upTo: 600))
                device.edit(random: &random) { meeting in
                    if meeting.highlights.isEmpty || time > 300 { meeting.highlights.append(Highlight(time: time, text: "Mark \(counter)")) }
                    else { meeting.highlights.removeFirst() }
                }
            case 40..<45:
                try await device.addPhoto(random: &random, seed: counter, at: clock)
            case 45..<48:
                device.edit(random: &random) { meeting in
                    if let photo = meeting.visiblePhotos.first, device.kind != .legacy { meeting.removePhoto(photo.id, at: clock) }
                }
            case 48..<52:
                try await device.trash(random: &random)
            case 52..<55:
                try await device.restore(random: &random)
            case 55..<60:
                device.process(random: &random, at: clock)
            case 60..<66:
                device.online.toggle()
            default:
                if device.online { try await device.sync() }
            }
        }
        // Everyone back online: a few rounds until nothing changes.
        for device in devices { device.online = true }
        for _ in 0..<6 { for device in devices { try await device.sync() } }
        let settled = try await devices.asyncMap { try await $0.sync() }
        for (device, result) in zip(devices, settled) {
            XCTAssertEqual(result.published, 0, "seed \(seed): \(device.name) has nothing left to publish")
            XCTAssertFalse(result.changed, "seed \(seed): \(device.name) is settled")
        }
        let mac = devices[0], phone = devices[1], legacy = devices[2]
        XCTAssertEqual(Set(mac.meetings.keys), Set(phone.meetings.keys), "seed \(seed): the same conversations")
        XCTAssertEqual(Set(mac.meetings.keys), Set(legacy.meetings.keys), "seed \(seed): the older Mac has them too")
        for (id, meeting) in mac.meetings {
            XCTAssertEqual(phone.meetings[id], meeting, "seed \(seed): \(meeting.title) is the same on the Mac and the iPhone")
        }
    }
}

// MARK: Harness

/// One device's library: its conversations as the app holds them, its store, and its engine.
private final class Replica {
    enum Kind { case mac, phone, legacy }
    let kind: Kind
    let name: String
    let local: URL
    let store: MeetingStore
    let engine: LibrarySyncEngine?
    let legacy: LegacyLibrarySyncEngine?
    var meetings: [UUID: Meeting] = [:]
    var online = true
    let claims = ClaimObservations()
    var device: ProcessingRequest.Device { .init(id: name, name: name) }

    init(_ kind: Kind, root: URL, remote: URL) throws {
        self.kind = kind
        name = "\(kind)"
        local = root.appendingPathComponent(name)
        store = try MeetingStore(rootURL: local)
        switch kind {
        case .mac:
            engine = try LibrarySyncEngine(localRoot: local, remoteRoot: remote, deviceID: name, replica: .mac(displayName: name, canProcess: true))
            legacy = nil
        case .phone:
            engine = try LibrarySyncEngine(localRoot: local, remoteRoot: remote, deviceID: name,
                                           replica: SyncReplicaConfiguration(audioPolicy: .onDemand, device: .init(deviceClass: .phone, displayName: name, canProcess: false)))
            legacy = nil
        case .legacy:
            engine = nil
            legacy = try LegacyLibrarySyncEngine(localRoot: local, remoteRoot: remote, deviceID: name)
        }
    }

    func save(_ meeting: Meeting) {
        var meeting = meeting
        if kind == .legacy {
            // The older app has no photos: saving its copy drops them, as it did.
            meeting.photos = nil
            if var summary = meeting.summary { for index in summary.sections.indices { summary.sections[index].photoIDs = nil }; meeting.summary = summary }
        }
        meetings[meeting.id] = meeting
    }

    func edit(random: inout ConvergenceRandom, _ change: (inout Meeting) -> Void) {
        let ids = meetings.keys.sorted { $0.uuidString < $1.uuidString }
        guard !ids.isEmpty else { return }
        var meeting = meetings[ids[random.next(upTo: ids.count)]]!
        change(&meeting)
        save(meeting)
    }

    func addPhoto(random: inout ConvergenceRandom, seed: Int, at date: Date) async throws {
        guard kind != .legacy else { return }
        let ids = meetings.keys.sorted { $0.uuidString < $1.uuidString }
        guard !ids.isEmpty else { return }
        var meeting = meetings[ids[random.next(upTo: ids.count)]]!
        try await persist(meeting)
        let file = try SyntheticPhotos.write(SyntheticPhotos.data(.jpeg, seed: seed), named: "IMG_\(seed).JPG",
                                             in: local.deletingLastPathComponent().appendingPathComponent("Camera-\(name)-\(seed)"))
        let photo = try await store.storePhoto(from: file, in: meeting, id: random.uuid(), capturedAt: date, capturedAtSource: .camera)
        meeting.addPhoto(photo)
        save(meeting)
    }

    func trash(random: inout ConvergenceRandom) async throws {
        let ids = meetings.keys.sorted { $0.uuidString < $1.uuidString }
        guard !ids.isEmpty else { return }
        let id = ids[random.next(upTo: ids.count)]
        try await persist(meetings[id]!)
        _ = try await store.moveToTrash(id)
        meetings.removeValue(forKey: id)
    }

    /// Restore from the Trash as the app does: a deletion sync published comes back under a new ID.
    func restore(random: inout ConvergenceRandom) async throws {
        guard kind != .legacy else { return }
        let trash = local.appendingPathComponent("Trash")
        let ids = ((try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []).compactMap(UUID.init(uuidString:)).sorted { $0.uuidString < $1.uuidString }
        guard !ids.isEmpty else { return }
        let id = ids[random.next(upTo: ids.count)]
        if LibrarySyncEngine.recordsDeletion(of: id, localRoot: local, deviceID: name) {
            let folder = trash.appendingPathComponent(id.uuidString)
            guard let saved = try? JSONDecoder().decode(Meeting.self, from: Data(contentsOf: folder.appendingPathComponent("meeting.json"))) else { return }
            let restored = saved.keptAs(random.uuid(), field: "source:restored", title: "Restored from the Trash")
            try MeetingFolderCopy.copyFiles(from: folder, to: local.appendingPathComponent("Meetings/\(restored.id.uuidString)"))
            try await store.save(restored)
            try FileManager.default.removeItem(at: folder)
            meetings[restored.id] = restored
        } else {
            meetings[id] = try await store.restoreFromTrash(id)
        }
    }

    /// The iPhone asks for processing; a Mac claims what's open and finishes what it holds.
    func process(random: inout ConvergenceRandom, at now: Date) {
        switch kind {
        case .phone:
            edit(random: &random) { $0.upsertProcessingRequest(ProcessingRequest(meetingID: $0.id, mode: .summaryOnly, requestedBy: self.device, createdAt: now)) }
        case .mac:
            edit(random: &random) { meeting in
                for request in meeting.openProcessingRequests {
                    if request.isClaimed(by: self.device, at: now, observations: self.claims),
                       let done = request.completed(by: self.device, at: now, observations: self.claims) { meeting.upsertProcessingRequest(done) }
                    else if let claimed = request.claimed(by: self.device, at: now, observations: self.claims) { meeting.upsertProcessingRequest(claimed) }
                }
            }
        case .legacy:
            break
        }
    }

    private func persist(_ meeting: Meeting) async throws { try await store.save(meeting) }

    /// One pass, saved and acknowledged as the app does. Offline, nothing happens.
    @discardableResult
    func sync() async throws -> (published: Int, changed: Bool) {
        guard online else { return (0, false) }
        for meeting in meetings.values { try await store.save(meeting) }
        let before = meetings
        let output: [Meeting], deleted: Set<UUID>, published: Int
        if let engine {
            let result = try await engine.synchronize(meetings: Array(meetings.values))
            output = result.meetings; deleted = result.deletedMeetingIDs; published = result.publishedEvents
            try await apply(output, deleted)
            try await engine.acknowledge(result.checkpointID)
        } else if let legacy {
            let result = try await legacy.synchronize(meetings: Array(meetings.values))
            output = result.meetings; deleted = result.deletedMeetingIDs; published = result.publishedEvents
            try await apply(output, deleted)
            try await legacy.acknowledge(result.checkpointID)
        } else { return (0, false) }
        return (published, before != meetings)
    }

    private func apply(_ output: [Meeting], _ deleted: Set<UUID>) async throws {
        for id in deleted where FileManager.default.fileExists(atPath: local.appendingPathComponent("Meetings/\(id)").path) {
            _ = try await store.moveToTrash(id)
        }
        meetings = Dictionary(output.filter { !deleted.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for meeting in meetings.values { try await store.save(meeting) }
    }
}

/// SplitMix64: the same sequence for a seed on every machine.
private struct ConvergenceRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func next(upTo bound: Int) -> Int { Int(next() % UInt64(bound)) }
    mutating func uuid() -> UUID {
        let a = next(), b = next()
        var bytes = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                     UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0))
        withUnsafeMutableBytes(of: &bytes) { buffer in
            withUnsafeBytes(of: a) { buffer.baseAddress!.copyMemory(from: $0.baseAddress!, byteCount: 8) }
            withUnsafeBytes(of: b) { (buffer.baseAddress! + 8).copyMemory(from: $0.baseAddress!, byteCount: 8) }
        }
        bytes.6 = (bytes.6 & 0x0F) | 0x40; bytes.8 = (bytes.8 & 0x3F) | 0x80
        return UUID(uuid: bytes)
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var results: [T] = []
        for element in self { results.append(try await transform(element)) }
        return results
    }
}
