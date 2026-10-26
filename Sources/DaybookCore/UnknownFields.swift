import Foundation

// Fields a newer Daybook adds to a conversation or to library settings must survive an edit made here,
// or this device would quietly remove them for every other device (docs/icloud-sync.md, "Newer
// versions"). So the stored and synced models keep the JSON keys they don't know, exactly as they came,
// and write them back after their own. Merges carry them key by key (`UnknownFields.merged`).

/// A stored or synced model that keeps the keys this version doesn't know.
public protocol PreservesUnknownFields {
    var unknownFields: UnknownFields { get set }
}

/// The JSON keys of a model that this version doesn't know, as written (`SyncJSONValue`). Empty for
/// anything this version wrote, so its encoding is exactly what it was before.
public struct UnknownFields: Equatable, Sendable {
    public private(set) var values: [String: SyncJSONValue]

    public init(_ values: [String: SyncJSONValue] = [:]) { self.values = values }

    public var isEmpty: Bool { values.isEmpty }
    public subscript(key: String) -> SyncJSONValue? { values[key] }

    /// Every key of the object `decoder` holds that isn't among `known`.
    public init(from decoder: Decoder, known: Set<String>) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        var values: [String: SyncJSONValue] = [:]
        for key in container.allKeys where !known.contains(key.stringValue) {
            values[key.stringValue] = try container.decode(SyncJSONValue.self, forKey: key)
        }
        self.values = values
    }

    /// Writes each key beside the model's own (call after encoding those).
    public func encode(to encoder: Encoder) throws {
        guard !values.isEmpty else { return }
        var container = encoder.container(keyedBy: AnyKey.self)
        for key in values.keys.sorted() { try container.encode(values[key], forKey: AnyKey(key)) }
    }

    /// Three copies' unknown fields merged key by key, as `MeetingMerge` merges what it knows: a key
    /// changed (added, edited, or removed) on one side only takes that side's value. Without a common
    /// ancestor, a key one side lacks is unset there. Two different values are a conflict, settled the
    /// same way whichever side is which (the greater encoding), and reported to `conflict` with both
    /// encodings, the smaller first. Deterministic, commutative, and idempotent.
    public static func merged(base: UnknownFields?, _ lhs: UnknownFields, _ rhs: UnknownFields,
                              conflict: (_ key: String, _ smaller: String, _ larger: String) -> Void = { _, _, _ in }) -> UnknownFields {
        if lhs == rhs { return lhs }
        var result: [String: SyncJSONValue] = [:]
        let keys = Set(lhs.values.keys).union(rhs.values.keys).union(base.map { Array($0.values.keys) } ?? [])
        for key in keys.sorted() {
            let a = lhs[key], b = rhs[key]
            let chosen: SyncJSONValue?
            if a == b {
                chosen = a
            } else if let base, a == base[key] {
                chosen = b
            } else if let base, b == base[key] {
                chosen = a
            } else if base == nil, a == nil || b == nil {
                chosen = a ?? b
            } else {
                let left = a.map(SyncJSONValue.canonical) ?? "", right = b.map(SyncJSONValue.canonical) ?? ""
                conflict(key, min(left, right), max(left, right))
                chosen = left > right ? a : b
            }
            if let chosen { result[key] = chosen }
        }
        return UnknownFields(result)
    }

    /// Any key, for reading and writing keys this version doesn't name.
    struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}

extension SyncJSONValue {
    /// The value's JSON with sorted keys, to compare values the same way on every device.
    static func canonical(_ value: SyncJSONValue) -> String { SyncEncoding.string(value) }

    /// Library settings a newer Daybook keeps under a key this version doesn't know, from two
    /// versions: when both are lists of per-item records (objects with an `id`, versioned by
    /// `modifiedAt`, like `LibraryValue`), they merge item by item as `LibraryMetadata` merges its own
    /// (the later change wins; a deletion, an item without a `value`, wins a tie). Otherwise the
    /// greater encoding wins. The same whichever side is which.
    static func mergedLibrarySetting(_ lhs: SyncJSONValue, _ rhs: SyncJSONValue) -> SyncJSONValue {
        if lhs == rhs { return lhs }
        guard case .array(let left) = lhs, case .array(let right) = rhs,
              let leftItems = items(left), let rightItems = items(right) else {
            return canonical(lhs) >= canonical(rhs) ? lhs : rhs
        }
        var entries: [String: [String: SyncJSONValue]] = [:]
        for candidate in leftItems + rightItems {
            guard case .string(let id)? = candidate["id"] else { continue }
            guard let old = entries[id] else { entries[id] = candidate; continue }
            entries[id] = laterItem(old, candidate)
        }
        return .array(entries.keys.sorted().compactMap { entries[$0].map(SyncJSONValue.object) })
    }

    private static func items(_ values: [SyncJSONValue]) -> [[String: SyncJSONValue]]? {
        var objects: [[String: SyncJSONValue]] = []
        for value in values {
            guard case .object(let object) = value, case .string? = object["id"] else { return nil }
            objects.append(object)
        }
        return objects
    }

    /// Of two versions of one item, the later; equal times prefer a deletion, then the greater encoding.
    private static func laterItem(_ a: [String: SyncJSONValue], _ b: [String: SyncJSONValue]) -> [String: SyncJSONValue] {
        func time(_ item: [String: SyncJSONValue]) -> SyncJSONValue? { item["modifiedAt"] }
        switch (time(a), time(b)) {
        case let (.number(x)?, .number(y)?) where x != y: return x > y ? a : b
        case let (.string(x)?, .string(y)?) where x != y: return x > y ? a : b
        default: break
        }
        func isDeletion(_ item: [String: SyncJSONValue]) -> Bool { item["value"] == nil || item["value"] == .null }
        if isDeletion(a) != isDeletion(b) { return isDeletion(a) ? a : b }
        return canonical(.object(a)) >= canonical(.object(b)) ? a : b
    }
}

extension Meeting: PreservesUnknownFields {}
extension RecordingTrack: PreservesUnknownFields {}
extension Highlight: PreservesUnknownFields {}
extension MeetingSummary: PreservesUnknownFields {}
extension SummarySection: PreservesUnknownFields {}
extension ActionItem: PreservesUnknownFields {}
extension MeetingPhoto: PreservesUnknownFields {}
extension LibraryFolder: PreservesUnknownFields {}
extension SummaryTemplate: PreservesUnknownFields {}
extension GlossaryTerm: PreservesUnknownFields {}
extension RecorderOwnership: PreservesUnknownFields {}
extension RecorderHandoffRecord: PreservesUnknownFields {}
extension LibraryMetadata: PreservesUnknownFields {}
