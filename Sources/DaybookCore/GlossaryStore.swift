import Foundation
import Synchronization

public actor GlossaryStore {
    public nonisolated let rootURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let backupExclusion = Mutex(false)
    public init(rootURL: URL? = nil) throws {
        self.rootURL = (rootURL ?? LibraryLocation.defaultRoot).standardizedFileURL
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try LocalFiles.directory(self.rootURL)
    }
    /// Keeps `glossary.json` and its recovery copy out of backups as they're saved, as `MeetingStore` does the
    /// library's other settings (`MeetingStore.excludeSettingsFromBackup`).
    public nonisolated func excludeFromBackup(_ excluded: Bool) { backupExclusion.withLock { $0 = excluded } }
    public nonisolated var excludesFromBackup: Bool { backupExclusion.withLock { $0 } }
    public func list() throws -> [GlossaryTerm] {
        let url = rootURL.appendingPathComponent("glossary.json")
        let backup = rootURL.appendingPathComponent("glossary.recovery.json")
        guard FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: backup.path) else { return [] }
        do { return try decoder.decode([GlossaryTerm].self, from: Data(contentsOf: url)) }
        catch {
            let bytes = try Data(contentsOf: backup)
            let recovered = try decoder.decode([GlossaryTerm].self, from: bytes)
            try LocalFiles.atomicWrite(bytes, to: url, backupExcluded: excludesFromBackup)
            return recovered
        }
    }
    public func save(_ terms: [GlossaryTerm]) throws {
        let url = rootURL.appendingPathComponent("glossary.json")
        let backup = rootURL.appendingPathComponent("glossary.recovery.json")
        let bytes = try encoder.encode(terms)
        let excluded = excludesFromBackup
        if let old = try? Data(contentsOf: url), (try? decoder.decode([GlossaryTerm].self, from: old)) != nil {
            try LocalFiles.atomicWrite(old, to: backup, backupExcluded: excluded)
        } else if !FileManager.default.fileExists(atPath: backup.path) { try LocalFiles.atomicWrite(bytes, to: backup, backupExcluded: excluded) }
        try LocalFiles.atomicWrite(bytes, to: url, backupExcluded: excluded)
    }
    public func propose(_ candidates: [GlossaryTerm], for meetingID: UUID) throws {
        var terms = try list()
        for candidate in candidates {
            let text = candidate.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 160 else { continue }
            // Unapproved definitions never migrate between meetings just because a spelling matches.
            if let index = terms.firstIndex(where: {
                $0.term.caseInsensitiveCompare(text) == .orderedSame && ($0.approved || $0.sourceMeetingIDs.contains(meetingID))
            }) {
                if !terms[index].sourceMeetingIDs.contains(meetingID) {
                    terms[index].sourceMeetingIDs.append(meetingID)
                    terms[index].occurrences += 1
                }
                if !terms[index].approved {
                    terms[index].aliases = Array(Set(terms[index].aliases + candidate.aliases)).sorted()
                    if terms[index].definition.isEmpty { terms[index].definition = candidate.definition }
                }
                terms[index].updatedAt = Date()
            } else {
                var proposed = candidate
                proposed.term = text; proposed.approved = false; proposed.sourceMeetingIDs = [meetingID]
                proposed.updatedAt = Date(); terms.append(proposed)
            }
        }
        try save(terms)
    }
}
