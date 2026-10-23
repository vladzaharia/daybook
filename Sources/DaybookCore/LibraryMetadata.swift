import Foundation

public struct LibraryFolder: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
}

/// Per-item versions avoid losing an unrelated folder or template edited on another Mac.
/// A nil value is a durable deletion marker, including for vocabulary entries.
public struct LibraryValue<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var id: String
    public var value: Value?
    public var modifiedAt: Date
    public init(id: String, value: Value?, modifiedAt: Date = Date()) {
        self.id = id; self.value = value; self.modifiedAt = modifiedAt
    }
}

public struct LibraryMetadata: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var folders: [LibraryValue<LibraryFolder>] = []
    public var templates: [LibraryValue<SummaryTemplate>] = []
    public var vocabulary: [LibraryValue<GlossaryTerm>] = []
    public init() {}

    public func merging(_ other: Self) -> Self {
        var value = self
        value.folders = Self.merge(folders, other.folders)
        value.templates = Self.merge(templates, other.templates)
        value.vocabulary = Self.merge(vocabulary, other.vocabulary)
        return value
    }

    private static func merge<T>(_ lhs: [LibraryValue<T>], _ rhs: [LibraryValue<T>]) -> [LibraryValue<T>] {
        var entries: [String: LibraryValue<T>] = [:]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for candidate in lhs + rhs {
            if let old = entries[candidate.id] {
                if old.modifiedAt > candidate.modifiedAt { continue }
                if old.modifiedAt == candidate.modifiedAt {
                    // Equal clocks resolve identically regardless of device ordering; deletion wins ties.
                    if old.value == nil { continue }
                    if candidate.value != nil {
                        let a = (try? encoder.encode(old)) ?? Data(), b = (try? encoder.encode(candidate)) ?? Data()
                        if !a.lexicographicallyPrecedes(b) { continue }
                    }
                }
            }
            entries[candidate.id] = candidate
        }
        return entries.values.sorted { $0.id < $1.id }
    }
}
