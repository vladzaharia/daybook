import Foundation
import os
import Synchronization

/// Where a device keeps the live captions it made: `<library>/LiveCaptions/<conversation id>.json`,
/// outside `Meetings/`, so sync and other devices never see them. The same on the Mac and the iPhone:
/// each file readable only by this user (0600, in a 0700 folder) and protected until the device is
/// first unlocked, with one rule for when a transcript replaces them (`isReplaced`).
///
/// Writes run on one serial queue, off the caller's actor: a recording's saves never hold up the main
/// thread, they land in the order they were made, and a snapshot older than one already written is left
/// out, so a save that was still on its way can't put back what a later one replaced. A write that fails
/// is logged; captions are a convenience, and nothing about the recording depends on them.
public final class LiveCaptionStore: Sendable {
    public let directory: URL
    private let queue = DispatchQueue(label: "local.daybook.live-captions", qos: .utility)
    /// What this store last wrote for each conversation.
    private let written = Mutex<[UUID: Written]>([:])
    private static let log = Logger(subsystem: "local.daybook", category: "LiveCaptions")

    private struct Written {
        var updatedAt: Date
        /// The recording they were filed with, kept by later saves that don't know it yet.
        var trackID: UUID?
    }

    public init(libraryRoot: URL) {
        directory = libraryRoot.appendingPathComponent("LiveCaptions", isDirectory: true)
    }

    public func url(for meetingID: UUID) -> URL { directory.appendingPathComponent("\(meetingID.uuidString).json") }

    // MARK: Reading

    /// A conversation's saved captions: one small file, read now.
    public func captions(for meetingID: UUID) -> LiveCaptions? {
        guard let data = try? Data(contentsOf: url(for: meetingID)) else { return nil }
        return try? JSONDecoder().decode(LiveCaptions.self, from: data)
    }

    /// The conversations that have captions saved.
    public func conversations() -> [UUID] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { $0.pathExtension == "json" ? UUID(uuidString: $0.deletingPathExtension().lastPathComponent) : nil }
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

    /// Changes a conversation's saved captions in place, after every write already asked for: `change`
    /// returns false to leave them as they are. Returns what was written, if anything.
    @discardableResult
    public func update(_ meetingID: UUID, _ change: @escaping @Sendable (inout LiveCaptions) -> Bool) async throws -> LiveCaptions? {
        try await onQueue {
            guard var captions = self.captions(for: meetingID), change(&captions) else { return nil }
            try self.write(captions, replacing: true)
            return captions
        }
    }

    /// Removes a conversation's captions.
    public func remove(_ meetingID: UUID) async {
        try? await onQueue { self.delete(meetingID) }
    }

    /// Removes the captions a transcript has replaced (`isReplaced`), and those of conversations moved
    /// to the Trash. `conversations`: every conversation in the library, with when each of its
    /// transcripts was made. `keeping`: conversations being captioned now. `trashed`: the conversations
    /// in the Trash, on a device where a recording's conversation only joins the library once it's
    /// filed (the iPhone: one stopped a moment ago, or one a crash left for recovery), so captions of a
    /// conversation the library doesn't have yet stay; nil where a conversation exists from the moment
    /// it's recorded (the Mac), so captions of any conversation not in the library go.
    /// Reads only the captions of conversations that have a transcript, off the caller's actor.
    public func prune(_ conversations: [UUID: [Date]], keeping: Set<UUID>, trashed: Set<UUID>? = nil) async {
        try? await onQueue {
            for id in self.conversations() where !keeping.contains(id) {
                guard let made = conversations[id] else {
                    if trashed?.contains(id) ?? true { self.delete(id) }
                    continue
                }
                guard !made.isEmpty, let captions = self.captions(for: id) else { continue }
                if Self.isReplaced(captions, transcriptsMadeAt: made) { self.delete(id) }
            }
        }
    }

    // MARK: When a transcript replaces them

    /// The one rule for both apps: the official transcript replaces live captions once one is made
    /// after they began. A transcript from before them (an earlier recording of the conversation)
    /// doesn't cover what they heard.
    public static func isReplaced(_ captions: LiveCaptions, transcriptsMadeAt made: [Date]) -> Bool {
        made.contains { $0 >= captions.createdAt }
    }

    /// The captions to show for a conversation: its own, until a transcript replaces them, and only
    /// with words to read.
    public static func shown(_ captions: LiveCaptions?, conversation: UUID, transcriptsMadeAt made: [Date]) -> LiveCaptions? {
        guard let captions, captions.meetingID == conversation, !isReplaced(captions, transcriptsMadeAt: made),
              captions.hasWords else { return nil }
        return captions
    }

    // MARK: On the queue

    private func onQueue<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: { try work() })) }
        }
    }

    /// `replacing`: an edit of what's saved (filing, speakers labelled afterwards), which wins whatever
    /// its time.
    private func write(_ captions: LiveCaptions, replacing: Bool = false) throws {
        var captions = captions
        let id = captions.meetingID
        let last = written.withLock { $0[id] }
        if !replacing, let last, captions.updatedAt < last.updatedAt { return }
        if captions.trackID == nil { captions.trackID = last?.trackID }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(captions)
            let url = url(for: id)
            do {
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                // A volume without data protection (an external drive) keeps them as any other file.
                try data.write(to: url, options: .atomic)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            Self.log.error("Couldn’t save live captions for \(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
        let stamp = max(captions.updatedAt, last?.updatedAt ?? .distantPast)
        written.withLock { $0[id] = Written(updatedAt: stamp, trackID: captions.trackID) }
    }

    private func delete(_ meetingID: UUID) {
        try? FileManager.default.removeItem(at: url(for: meetingID))
        written.withLock { $0[meetingID] = nil }
    }
}

extension LiveCaptions {
    /// Whether any caption has words to read.
    public var hasWords: Bool { segments.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }

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
