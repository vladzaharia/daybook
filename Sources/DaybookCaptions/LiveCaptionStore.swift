import Foundation
import os
import Synchronization

/// Where a device keeps the live captions it made: one file per recording,
/// `<library>/LiveCaptions/<conversation id>.<recording id>.json` (`<conversation id>.json` for captions saved
/// before recordings were kept apart), outside `Meetings/`, so sync and other devices never see them. The same
/// on the Mac and the iPhone: each file readable only by this user (0600, in a 0700 folder), with one rule for when
/// a transcript replaces them (`LiveCaptionCoverage`). A second recording into a conversation keeps its own captions
/// beside the first's.
///
/// Their data protection (`protection`): the iPhone writes them while it records, often locked, so they're kept as
/// its recording in progress is, until unlock (`completeUnlessOpen`): a locked iPhone can write them, a new file each
/// time, but can't read one back, so reading falls back to the copy this store wrote last, and filing them with their
/// recording (`update`) works while it's locked. The Mac's are protected until its first unlock.
///
/// Writes run on one serial queue, off the caller's actor: a recording's saves never hold up the main
/// thread, they land in the order they were made, and a snapshot older than one already written is left
/// out, so a save that was still on its way can't put back what a later one replaced. A write that fails
/// is logged and kept: the captions read as it would have left them, a later edit (`update`) builds on it, and
/// it's tried again after a while (`retryDelays`), since a recording's last save has no later one to try it
/// again. Captions are a convenience, and nothing about the recording depends on them.
public final class LiveCaptionStore: Sendable {
    public let directory: URL
    /// How long after a write that failed it's tried again, each time, until one lands or a later write of the
    /// same captions does.
    public let retryDelays: [TimeInterval]
    /// The files' data protection class.
    public let protection: FileProtectionType
    private let queue = DispatchQueue(label: "local.daybook.live-captions", qos: .utility)
    /// What this store last wrote for each recording.
    private let written = Mutex<[LiveCaptionKey: Written]>([:])
    /// Captions whose write failed, by recording, until one lands.
    private let unsaved = Mutex<[LiveCaptionKey: Unsaved]>([:])
    private static let log = Logger(subsystem: "local.daybook", category: "LiveCaptions")

    private struct Written {
        var updatedAt: Date
        /// The recording they were filed with, kept by later saves that don't know it yet.
        var trackID: UUID?
        /// What was written, until the file is read back: what reading falls back to while the file is there but
        /// can't be opened (a locked iPhone).
        var copy: LiveCaptions?
    }

    private struct Unsaved {
        var captions: LiveCaptions
        /// Tries made since, and whether one is waiting.
        var retries = 0
        var waiting = false
    }

    public init(libraryRoot: URL, retryDelays: [TimeInterval] = [2, 10, 30, 120], protection: FileProtectionType = LiveCaptionStore.defaultProtection) {
        directory = libraryRoot.appendingPathComponent("LiveCaptions", isDirectory: true)
        self.retryDelays = retryDelays
        self.protection = protection
    }

    /// Until unlock on the iPhone, which writes them while it records, locked; until the first unlock on the Mac.
    public static var defaultProtection: FileProtectionType {
        #if os(iOS)
        .completeUnlessOpen
        #else
        .completeUntilFirstUserAuthentication
        #endif
    }

    /// One recording's file.
    public func url(for key: LiveCaptionKey) -> URL {
        let name = key.captureID.map { "\(key.meetingID.uuidString).\($0.uuidString)" } ?? key.meetingID.uuidString
        return directory.appendingPathComponent("\(name).json")
    }

    /// The file of captions saved before recordings were kept apart.
    public func url(for meetingID: UUID) -> URL { url(for: LiveCaptionKey(meetingID: meetingID)) }

    /// The recording a file in the folder holds, by its name.
    public static func key(of file: URL) -> LiveCaptionKey? {
        guard file.pathExtension == "json" else { return nil }
        let parts = file.deletingPathExtension().lastPathComponent.split(separator: ".")
        guard let meetingID = parts.first.flatMap({ UUID(uuidString: String($0)) }) else { return nil }
        switch parts.count {
        case 1: return LiveCaptionKey(meetingID: meetingID)
        case 2: return UUID(uuidString: String(parts[1])).map { LiveCaptionKey(meetingID: meetingID, captureID: $0) }
        default: return nil
        }
    }

    // MARK: Reading

    /// One recording's saved captions: one small file, read now, or what a write that failed would have left there.
    /// A file that's there but can't be read now (a locked iPhone) reads as the copy this store wrote last.
    public func captions(for key: LiveCaptionKey) -> LiveCaptions? {
        if let owed = unsaved.withLock({ $0[key]?.captions }) { return owed }
        let data: Data
        do { data = try Data(contentsOf: url(for: key)) } catch {
            guard !Self.isMissing(error) else { return nil }
            return written.withLock { $0[key]?.copy }
        }
        guard let captions = try? JSONDecoder().decode(LiveCaptions.self, from: data) else { return nil }
        // Read back: the file stands for itself from now on.
        written.withLock { table in
            if let copy = table[key]?.copy, copy.updatedAt <= captions.updatedAt { table[key]?.copy = nil }
        }
        return captions
    }

    private static func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError)
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
    }

    /// Each recording's saved captions of a conversation, the oldest recording's first.
    public func captures(of meetingID: UUID) -> [LiveCaptions] {
        keys().filter { $0.meetingID == meetingID }.compactMap(captions(for:)).sorted { $0.origin < $1.origin }
    }

    /// A conversation's newest recording's captions.
    public func captions(for meetingID: UUID) -> LiveCaptions? { captures(of: meetingID).last }

    /// The recordings that have captions saved.
    public func keys() -> [LiveCaptionKey] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let saved = files.compactMap(Self.key(of:))
        let owed = unsaved.withLock { Array($0.keys) }.filter { !saved.contains($0) }
        return saved + owed
    }

    /// The conversations that have captions saved.
    public func conversations() -> [UUID] {
        var seen = Set<UUID>()
        return keys().map(\.meetingID).filter { seen.insert($0).inserted }
    }

    /// Every conversation's saved captions, each recording's, by conversation, read now: a few small files,
    /// since a transcript's arrival deletes the ones it replaces.
    public func allCaptures() -> [UUID: [LiveCaptions]] {
        Dictionary(grouping: keys().compactMap(captions(for:)), by: \.meetingID).mapValues { $0.sorted { $0.origin < $1.origin } }
    }

    // MARK: Writing

    /// Writes `captions` now, on the caller's thread: seeding a demo library, tests.
    public func save(_ captions: LiveCaptions) throws {
        try queue.sync { try write(captions) }
    }

    /// Writes `captions` off the caller's actor, after every write already asked for. Returns once
    /// they're on disk.
    public func save(_ captions: LiveCaptions) async throws {
        try await onQueue { try self.write(captions) }
    }

    /// Changes one recording's saved captions in place, after every write already asked for: `change`
    /// returns false to leave them as they are. Returns what was written, if anything.
    @discardableResult
    public func update(_ key: LiveCaptionKey, _ change: @escaping @Sendable (inout LiveCaptions) -> Bool) async throws -> LiveCaptions? {
        try await onQueue {
            guard var captions = self.captions(for: key), change(&captions) else { return nil }
            try self.write(captions, replacing: true)
            return captions
        }
    }

    /// The same, for a conversation's newest recording's captions.
    @discardableResult
    public func update(_ meetingID: UUID, _ change: @escaping @Sendable (inout LiveCaptions) -> Bool) async throws -> LiveCaptions? {
        let key = await onQueueQuietly { self.captions(for: meetingID)?.key }
        guard let key else { return nil }
        return try await update(key, change)
    }

    /// Removes a conversation's captions, every recording's.
    public func remove(_ meetingID: UUID) async {
        try? await onQueue { for key in self.keys() where key.meetingID == meetingID { self.delete(key) } }
    }

    /// Removes the captions transcripts have replaced (every line, `LiveCaptionCoverage.replacesAll`), and
    /// those of conversations moved to the Trash. `coverage`: every conversation in the library, with its
    /// recordings and transcripts. `keeping`: conversations being captioned now. `trashed`: the conversations
    /// in the Trash, on a device where a recording's conversation only joins the library once it's
    /// filed (the iPhone: one stopped a moment ago, or one a crash left for recovery), so captions of a
    /// conversation the library doesn't have yet stay; nil where a conversation exists from the moment
    /// it's recorded (the Mac), so captions of any conversation not in the library go.
    /// Reads only the captions of conversations that have a transcript, off the caller's actor.
    public func prune(_ coverage: [UUID: LiveCaptionCoverage], keeping: Set<UUID>, trashed: Set<UUID>? = nil) async {
        try? await onQueue {
            for key in self.keys() where !keeping.contains(key.meetingID) {
                guard let known = coverage[key.meetingID] else {
                    if trashed?.contains(key.meetingID) ?? true { self.delete(key) }
                    continue
                }
                guard known.hasTranscript, let captions = self.captions(for: key) else { continue }
                if known.replacesAll(captions) { self.delete(key) }
            }
        }
    }

    // MARK: When a transcript replaces them

    /// The captions to show for a conversation: its own, the lines no transcript replaces yet
    /// (`LiveCaptionCoverage`), and only with words to read.
    public static func shown(_ captions: LiveCaptions?, conversation: UUID, coverage: LiveCaptionCoverage) -> LiveCaptions? {
        guard let captions, captions.meetingID == conversation else { return nil }
        return coverage.shown(captions)
    }

    // MARK: On the queue

    private func onQueue<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: { try work() })) }
        }
    }

    private func onQueueQuietly<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: work()) } }
    }

    /// `replacing`: an edit of what's saved (filing, speakers labelled afterwards), which wins whatever
    /// its time.
    private func write(_ captions: LiveCaptions, replacing: Bool = false) throws {
        var captions = captions
        captions.parts = nil
        let key = captions.key
        let last = written.withLock { $0[key] }
        if !replacing, let last, captions.updatedAt < last.updatedAt { return }
        if captions.trackID == nil { captions.trackID = last?.trackID ?? unsaved.withLock { $0[key]?.captions.trackID } }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(captions)
            let url = url(for: key)
            do {
                try data.write(to: url, options: [.atomic, Self.writingOptions(protection)])
            } catch {
                // A volume without data protection (an external drive) keeps them as any other file.
                try data.write(to: url, options: .atomic)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // The error's domain and code only: its description names the file.
            let code = error as NSError
            Self.log.error("Couldn’t save live captions for \(key.meetingID.uuidString, privacy: .public) (\(code.domain, privacy: .public) \(code.code, privacy: .public)): \(error.localizedDescription, privacy: .private)")
            keepUnsaved(captions, replacing: replacing)
            throw error
        }
        let stamp = max(captions.updatedAt, last?.updatedAt ?? .distantPast)
        // A copy only where a locked device can't read the file back.
        let copy = protection == .completeUnlessOpen || protection == .complete ? captions : nil
        written.withLock { $0[key] = Written(updatedAt: stamp, trackID: captions.trackID, copy: copy) }
        unsaved.withLock { table in
            if let owed = table[key], replacing || owed.captions.updatedAt <= captions.updatedAt { table[key] = nil }
        }
    }

    /// Keeps captions whose write failed (the newest of them, or an edit), and tries them again after the next of
    /// `retryDelays`.
    private func keepUnsaved(_ captions: LiveCaptions, replacing: Bool) {
        let key = captions.key
        let delay = unsaved.withLock { table -> TimeInterval? in
            var entry = table[key] ?? Unsaved(captions: captions)
            if replacing || entry.captions.updatedAt <= captions.updatedAt { entry.captions = captions }
            var delay: TimeInterval?
            if !entry.waiting, entry.retries < retryDelays.count {
                delay = retryDelays[entry.retries]
                entry.waiting = true
            }
            table[key] = entry
            return delay
        }
        guard let delay else { return }
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            let owed = unsaved.withLock { table -> LiveCaptions? in
                table[key]?.waiting = false
                table[key]?.retries += 1
                return table[key]?.captions
            }
            // The newest the captions were meant to be: written over whatever is there.
            if let owed { try? write(owed, replacing: true) }
        }
    }

    private static func writingOptions(_ protection: FileProtectionType) -> Data.WritingOptions {
        switch protection {
        case .complete: return .completeFileProtection
        case .completeUnlessOpen: return .completeFileProtectionUnlessOpen
        case .completeUntilFirstUserAuthentication: return .completeFileProtectionUntilFirstUserAuthentication
        default: return .noFileProtection
        }
    }

    private func delete(_ key: LiveCaptionKey) {
        try? FileManager.default.removeItem(at: url(for: key))
        written.withLock { $0[key] = nil }
        unsaved.withLock { $0[key] = nil }
    }
}

extension LiveCaptions {
    /// Whether any caption has words to read.
    public var hasWords: Bool { segments.contains(where: \.hasWords) }

    /// The caption heard at `position` seconds into the recording they were made from, if any.
    public func segment(at position: TimeInterval) -> UUID? {
        segments.first { ($0.start...max($0.start, $0.end)).contains(position) }?.id
    }

    /// The first caption that has `query` in it, ignoring case and accents.
    public func firstMatch(_ query: String) -> LiveCaptionSegment? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return segments.first { $0.text.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}
