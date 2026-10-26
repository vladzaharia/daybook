import Foundation

// Synced enums a newer Daybook may extend. A value this version doesn't know must not make a
// conversation, a request, or library settings unreadable, and an edit made here must not replace
// it with something this version understands: other devices still need the original. So a stored
// enum is wrapped in `Extensible` (or `ExtensibleOptional`), which reads an unknown raw value as
// the enum's `syncFallback` and writes the raw value back unchanged until code here sets a new
// value. Known values encode exactly as the bare enum did, so nothing already synced changes.

/// An enum stored in synced data (`Meeting`, `ProcessingRequest`, `LibraryMetadata`).
public protocol ExtensibleSyncEnum: RawRepresentable, Codable, Equatable, Sendable where RawValue == String {
    /// What this version shows for a value written by a newer one: the most neutral case.
    static var syncFallback: Self { get }
}

/// A synced enum value that keeps a raw value a newer Daybook wrote. Reading the property gives
/// the enum (`syncFallback` for an unknown value); setting it replaces the unknown value.
/// `$property` is the wrapper itself, for code that copies values between versions (merging).
@propertyWrapper
public struct Extensible<Value: ExtensibleSyncEnum>: Codable, Equatable, Sendable {
    private var value: Value
    /// The raw value a newer Daybook wrote, kept so this device writes it back unchanged.
    public private(set) var unknownRawValue: String?

    public init(wrappedValue: Value) { value = wrappedValue }

    public var wrappedValue: Value {
        get { value }
        set { value = newValue; unknownRawValue = nil }
    }

    public var projectedValue: Extensible<Value> {
        get { self }
        set { self = newValue }
    }

    /// Whether this version knows the stored value.
    public var isKnown: Bool { unknownRawValue == nil }
    /// The stored raw value, known or not.
    public var rawValue: String { unknownRawValue ?? value.rawValue }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if let known = Value(rawValue: raw) { value = known } else { value = .syncFallback; unknownRawValue = raw }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// `Extensible` for an optional value: nil stays absent from the encoding, as an optional enum's did,
/// and an unknown value reads as nil.
@propertyWrapper
public struct ExtensibleOptional<Value: ExtensibleSyncEnum>: Codable, Equatable, Sendable {
    private var value: Value?
    public private(set) var unknownRawValue: String?

    public init(wrappedValue: Value?) { value = wrappedValue }

    public var wrappedValue: Value? {
        get { value }
        set { value = newValue; unknownRawValue = nil }
    }

    public var projectedValue: ExtensibleOptional<Value> {
        get { self }
        set { self = newValue }
    }

    public var isKnown: Bool { unknownRawValue == nil }
    /// Nothing stored, known or not.
    var isAbsent: Bool { value == nil && unknownRawValue == nil }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { value = nil; return }
        let raw = try container.decode(String.self)
        if let known = Value(rawValue: raw) { value = known } else { value = nil; unknownRawValue = raw }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let raw = unknownRawValue ?? value?.rawValue { try container.encode(raw) } else { try container.encodeNil() }
    }
}

// Synthesized coding calls these for `ExtensibleOptional` properties: a missing key reads as nil, and
// nil is left out, exactly as for a plain optional.
extension KeyedDecodingContainer {
    public func decode<Value>(_ type: ExtensibleOptional<Value>.Type, forKey key: Key) throws -> ExtensibleOptional<Value> {
        try decodeIfPresent(type, forKey: key) ?? ExtensibleOptional(wrappedValue: nil)
    }
}

extension KeyedEncodingContainer {
    public mutating func encode<Value>(_ value: ExtensibleOptional<Value>, forKey key: Key) throws {
        guard !value.isAbsent else { return }
        try encodeIfPresent(Optional(value), forKey: key)
    }
}

// MARK: Fallbacks

extension MeetingKind: ExtensibleSyncEnum { public static var syncFallback: MeetingKind { .auto } }
extension LibraryPlacement: ExtensibleSyncEnum { public static var syncFallback: LibraryPlacement { .work } }
extension MeetingStatus: ExtensibleSyncEnum { public static var syncFallback: MeetingStatus { .imported } }
extension AudioSource: ExtensibleSyncEnum { public static var syncFallback: AudioSource { .imported } }
/// A request whose mode this version doesn't know is never claimed here (`ProcessingRequest.isUnderstood`).
extension ProcessingRequest.Mode: ExtensibleSyncEnum { public static var syncFallback: ProcessingRequest.Mode { .newAudio } }
extension ProcessingRequest.Stage: ExtensibleSyncEnum { public static var syncFallback: ProcessingRequest.Stage { .transcribing } }
extension ProcessingRequest.Outcome.Result: ExtensibleSyncEnum { public static var syncFallback: ProcessingRequest.Outcome.Result { .failed } }
/// A placement made a newer way is kept as it is, never measured again over it.
extension SourceAlignment.Method: ExtensibleSyncEnum { public static var syncFallback: SourceAlignment.Method { .manual } }
extension CompanionRecording.State: ExtensibleSyncEnum { public static var syncFallback: CompanionRecording.State { .stopped } }
extension SourceSuggestion.Reason: ExtensibleSyncEnum { public static var syncFallback: SourceSuggestion.Reason { .lowConfidence } }
extension TrackAlignment.Method: ExtensibleSyncEnum { public static var syncFallback: TrackAlignment.Method { .provided } }
/// Never an accepted match: an unknown status establishes no identity.
extension SpeakerMatch.Status: ExtensibleSyncEnum { public static var syncFallback: SpeakerMatch.Status { .ambiguous } }
extension FusionSourceRole: ExtensibleSyncEnum { public static var syncFallback: FusionSourceRole { .unknown } }
extension FusionSpeakerMapping.Reason: ExtensibleSyncEnum { public static var syncFallback: FusionSpeakerMapping.Reason { .sharedSpeech } }
extension PhotoCaptureDateSource: ExtensibleSyncEnum { public static var syncFallback: PhotoCaptureDateSource { .added } }
extension EchoRemovalSkipReason: ExtensibleSyncEnum { public static var syncFallback: EchoRemovalSkipReason { .disabled } }
extension EchoRemovalReport.Outcome: ExtensibleSyncEnum { public static var syncFallback: EchoRemovalReport.Outcome { .skipped } }
/// A phase from a later version is treated as still waiting, never as a release.
extension RecorderHandoffRecord.Phase: ExtensibleSyncEnum { public static var syncFallback: RecorderHandoffRecord.Phase { .requested } }
extension SyncDeviceClass: ExtensibleSyncEnum { public static var syncFallback: SyncDeviceClass { .other } }
