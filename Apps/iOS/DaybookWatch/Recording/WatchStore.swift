import AVFoundation
import DaybookWatchLink
import Foundation

/// Where the watch keeps its recordings: `Application Support/Recordings/<id>/`, each with its segments
/// (`WatchSegment.fileName`) and its journal (`WatchRecordingJournal.fileName`). A recording stays until the iPhone
/// says it's in its library (`WatchReceipt.imported`), so the originals outlive any transfer that fails.
struct WatchStore: Sendable {
    let root: URL

    /// Space a recording must leave free: below it, nothing starts, and a recording in progress ends.
    static let reserve: UInt64 = 50_000_000

    static var standard: WatchStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return WatchStore(root: support.appendingPathComponent("Recordings", isDirectory: true))
    }

    func folder(for id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    func url(of segment: WatchSegment) -> URL { folder(for: segment.recordingID).appendingPathComponent(segment.fileName) }

    func url(of index: Int, in recordingID: String) -> URL {
        url(of: WatchSegment(recordingID: recordingID, index: index, startOffset: 0, duration: 0,
                             recording: WatchRecordingInfo(id: recordingID, startedAt: Date())))
    }

    /// A new recording's folder.
    func create(_ journal: WatchRecordingJournal) throws {
        try FileManager.default.createDirectory(at: folder(for: journal.recording.id), withIntermediateDirectories: true)
        try save(journal)
    }

    func save(_ journal: WatchRecordingJournal) throws {
        let data = try JSONEncoder().encode(journal)
        try data.write(to: folder(for: journal.recording.id).appendingPathComponent(WatchRecordingJournal.fileName), options: .atomic)
    }

    /// Every recording's journal, oldest first. A folder whose journal doesn't read is left alone (never deleted).
    func journals() -> [WatchRecordingJournal] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(WatchRecordingJournal.fileName)) else { return nil }
            return try? JSONDecoder().decode(WatchRecordingJournal.self, from: data)
        }
        .sorted { $0.recording.startedAt < $1.recording.startedAt }
    }

    /// The recordings at launch: one left unfinished (the app was ended while it recorded) is closed and saved, its last
    /// segment kept if it reads and deleted if it doesn't. Returns every recording, oldest first, and which were closed now.
    func recoverAll() -> (journals: [WatchRecordingJournal], recovered: [String]) {
        var recovered: [String] = []
        let journals = journals().map { journal -> WatchRecordingJournal in
            guard !journal.recording.isFinished else { return journal }
            var journal = journal
            var duration: TimeInterval?
            var bytes: UInt64 = 0
            if let open = journal.open {
                let url = url(of: open.index, in: journal.recording.id)
                duration = Self.readableDuration(of: url)
                if (duration ?? 0) > 0 {
                    bytes = Self.size(of: url)
                } else {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            journal.recover(openDuration: duration, openByteCount: bytes)
            try? save(journal)
            recovered.append(journal.recording.id)
            return journal
        }
        return (journals, recovered)
    }

    /// Deletes a recording and its segments: only once the iPhone has it in its library.
    func delete(_ id: String) {
        try? FileManager.default.removeItem(at: folder(for: id))
    }

    /// Seconds of audio in a segment file, or nil when it doesn't read (an M4A the app was ended while writing has no
    /// index yet).
    static func readableDuration(of url: URL) -> TimeInterval? {
        guard FileManager.default.fileExists(atPath: url.path),
              let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    static func size(of url: URL) -> UInt64 {
        UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    /// Free and total space on the watch, for its state and the reserve.
    static func space() -> (free: UInt64?, total: UInt64?) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: support.deletingLastPathComponent().path) else {
            return (nil, nil)
        }
        return ((attributes[.systemFreeSize] as? NSNumber)?.uint64Value, (attributes[.systemSize] as? NSNumber)?.uint64Value)
    }

    static var hasRoom: Bool { (space().free ?? .max) > reserve }
}
