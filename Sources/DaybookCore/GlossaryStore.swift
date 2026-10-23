import Foundation

public actor GlossaryStore {
    public nonisolated let rootURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    public init(rootURL: URL? = nil) throws {
        self.rootURL = (rootURL ?? LibraryLocation.defaultRoot).standardizedFileURL
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try LocalFiles.directory(self.rootURL)
    }
    public func list() throws -> [GlossaryTerm] {
        let url = rootURL.appendingPathComponent("glossary.json")
        let backup = rootURL.appendingPathComponent("glossary.recovery.json")
        guard FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: backup.path) else { return [] }
        do { return try decoder.decode([GlossaryTerm].self, from: Data(contentsOf: url)) }
        catch {
            let bytes = try Data(contentsOf: backup)
            let recovered = try decoder.decode([GlossaryTerm].self, from: bytes)
            try LocalFiles.atomicWrite(bytes, to: url)
            return recovered
        }
    }
    public func save(_ terms: [GlossaryTerm]) throws {
        let url = rootURL.appendingPathComponent("glossary.json")
        let backup = rootURL.appendingPathComponent("glossary.recovery.json")
        let bytes = try encoder.encode(terms)
        if let old = try? Data(contentsOf: url), (try? decoder.decode([GlossaryTerm].self, from: old)) != nil {
            try LocalFiles.atomicWrite(old, to: backup)
        } else if !FileManager.default.fileExists(atPath: backup.path) { try LocalFiles.atomicWrite(bytes, to: backup) }
        try LocalFiles.atomicWrite(bytes, to: url)
    }
    /// Only explicitly approved vocabulary is eligible for prompts in other meetings.
    public func approvedTerms() throws -> [GlossaryTerm] { try list().filter(\.approved) }
    public func terms(for meetingID: UUID) throws -> [GlossaryTerm] {
        try list().filter { $0.approved || $0.sourceMeetingIDs.contains(meetingID) }
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
    public func recordCorrection(from original: String, to corrected: String, in meetingID: UUID) throws {
        try propose([GlossaryTerm(term: corrected, aliases: [original])], for: meetingID)
    }
}
