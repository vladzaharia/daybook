import Foundation

// The vocabulary of the model system (docs/models.md): roles, engines, platforms, references, and
// versions. Data only, shared by the Mac and the iPhone. Roles and engines are open sets of strings
// rather than enums, so a manifest naming one this build doesn't know still decodes; the entry
// is then shown as needing a newer Daybook instead of breaking the catalog.

/// What the pipeline needs done.
public struct ModelRole: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }

    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Speech to timed words.
    public static let transcription: ModelRole = "transcription"
    /// Who spoke when.
    public static let diarization: ModelRole = "diarization"
    /// Voice profiles that can be compared across recordings.
    public static let speakerEmbedding: ModelRole = "speakerEmbedding"
    /// Meeting notes from a transcript.
    public static let summarization: ModelRole = "summarization"
    /// Short, fixed-shape jobs: titles, meeting kind, vocabulary suggestions.
    public static let smallTasks: ModelRole = "smallTasks"
    /// A photo's caption: what it shows, in a few words (photos also get their text read and their
    /// sharpness judged by Apple Vision, whichever model writes the caption).
    public static let imageDescription: ModelRole = "imageDescription"

    /// The roles Daybook knows, in the order the interface lists them.
    public static let known: [ModelRole] = [.transcription, .diarization, .speakerEmbedding, .summarization, .smallTasks, .imageDescription]

    // Live roles (docs/models.md, "Live models"): tentative captions while recording, on the Mac and
    // the iPhone. They never make a transcript, so presets, removal fallbacks, and processing jobs
    // (which cover `known`) leave them alone. Voice profiles for live speakers use `speakerEmbedding`,
    // so live names come from the same embedding space as the Mac's profiles.
    /// Speech to words as it's heard (a streaming model).
    public static let liveTranscription: ModelRole = "liveTranscription"
    /// Who's speaking, as they speak (a streaming speaker model).
    public static let liveDiarization: ModelRole = "liveDiarization"
    /// The live roles a catalog's `liveSelection` names, in the order settings list them.
    public static let live: [ModelRole] = [.liveTranscription, .liveDiarization, .speakerEmbedding]
    /// A role only live captions use: an optional download, never something processing waits for.
    public var isLiveOnly: Bool { self == .liveTranscription || self == .liveDiarization }
}

/// An engine's stable identifier: "whisperKit", "community1", "mlxLanguage".
public struct ModelEngineID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }

    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    // Engines this build implements (DaybookIntelligence registers them).
    public static let whisperKit: ModelEngineID = "whisperKit"
    public static let community1: ModelEngineID = "community1"
    public static let sortformer: ModelEngineID = "sortformer"
    public static let mlxLanguage: ModelEngineID = "mlxLanguage"
    public static let parakeet: ModelEngineID = "parakeet"
    public static let nemotronDiarizer: ModelEngineID = "nemotronDiarizer"
    /// NVIDIA's cache-aware streaming recognizers (Nemotron 3.5 ASR Streaming) for live captions.
    public static let nemotronStreaming: ModelEngineID = "nemotronStreaming"
    // Engines planned next (docs/models.md, "How to add a model"). A manifest may already name them;
    // until an engine registers, its entries read "Needs a newer Daybook".
    public static let appleFoundationModels: ModelEngineID = "appleFoundationModels"
    /// Apple's Vision framework: text recognition, classification, sharpness, and near copies.
    public static let appleVision: ModelEngineID = "appleVision"
    public static let mlxAudio: ModelEngineID = "mlxAudio"
}

/// Where an engine runs.
public enum ModelPlatform: String, Codable, CaseIterable, Sendable {
    case macOS, iOS

    public static var current: ModelPlatform {
        #if os(iOS)
        return .iOS
        #else
        return .macOS
        #endif
    }
}

/// How a loaded model shares memory with others (the runtime's residency rule).
public enum ModelResidency: String, Codable, Sendable {
    /// Coexists with other shared models (speech and speaker models on the Neural Engine).
    case shared
    /// Needs the machine to itself: loading it releases every other model, and loading any other
    /// model releases it (MLX language models on the GPU).
    case exclusive
    /// Runs in the operating system, outside Daybook's memory (Apple Foundation Models): it
    /// releases nothing when used, and nothing needs to release it.
    case system
}

/// What an engine says about itself. Engines live in DaybookIntelligence; this description is data,
/// so the catalog can decide what a build can run without linking any engine.
public struct ModelEngineDescriptor: Codable, Hashable, Sendable {
    public var id: ModelEngineID
    public var name: String
    /// Daybook's version of this engine. Bump it when the engine gains abilities a manifest entry may
    /// require (`minimumEngineVersion`), such as a new architecture after a package upgrade.
    public var version: Int
    /// The package underneath, for provenance: "WhisperKit 0.18.0".
    public var runtime: String
    public var roles: Set<ModelRole>
    public var platforms: Set<ModelPlatform>
    public var residency: ModelResidency
    /// Why the engine can't run on this device right now, for engines that depend on the system
    /// (Apple Foundation Models: "Turn on Apple Intelligence"); nil when it can.
    public var unavailableReason: String?

    public init(id: ModelEngineID, name: String, version: Int, runtime: String, roles: Set<ModelRole>,
                platforms: Set<ModelPlatform>, residency: ModelResidency = .shared, unavailableReason: String? = nil) {
        self.id = id; self.name = name; self.version = version; self.runtime = runtime
        self.roles = roles; self.platforms = platforms; self.residency = residency
        self.unavailableReason = unavailableReason
    }

    /// "1 (WhisperKit 0.18.0)", as provenance records it.
    public var versionString: String { "\(version) (\(runtime))" }
}

/// Names one model to run: a variant (by key, or a legacy catalog ID such as "whisper-base") and,
/// once a job is queued, the exact revision it froze.
public struct ModelReference: Codable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    /// "whisper/base", or a legacy ID the catalog's migration table resolves.
    public var id: String
    /// Nil runs the newest verified installed revision of the variant.
    public var revision: String?

    public init(_ id: String, revision: String? = nil) {
        // "family/variant@revision" is accepted as one string, as the smoke test's flags write it.
        if revision == nil, let at = id.lastIndex(of: "@"), id[..<at].contains("/") {
            self.id = String(id[..<at]); self.revision = String(id[id.index(after: at)...])
        } else {
            self.id = id; self.revision = revision
        }
    }
    public init(stringLiteral value: String) { self.init(value) }
    public var description: String { revision.map { "\(id)@\($0)" } ?? id }
}

/// A dotted version ("0.1.0", "1.4"), compared numerically.
public struct ModelVersion: Comparable, Codable, Hashable, Sendable, CustomStringConvertible {
    public var components: [Int]

    public init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.map { Int($0.prefix { $0.isNumber }) }
        guard !parts.isEmpty, numbers.allSatisfy({ $0 != nil }) else { return nil }
        components = numbers.map { $0! }
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    public static func < (lhs: ModelVersion, rhs: ModelVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: ModelVersion, rhs: ModelVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
    public func hash(into hasher: inout Hasher) {
        var trimmed = components
        while trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let value = ModelVersion(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a version: \(text)"))
        }
        self = value
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    /// This build's marketing version (CFBundleShortVersionString). Nil in tests and `swift run`,
    /// where no bundle declares one: a development build satisfies every minimum.
    public static var app: ModelVersion? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(ModelVersion.init)
    }
}
