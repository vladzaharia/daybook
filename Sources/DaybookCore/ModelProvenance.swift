import Foundation

/// The exact model that produced a transcript, a speaker run, or a summary (docs/models.md,
/// "Selection, updates, and provenance"). It is stored with the result and synced with the library,
/// so a result stays explainable after the model is updated, removed, or was only ever on another
/// device. Shared by the Mac and the iPhone; the catalog that names models lives in DaybookKit.
public struct ModelProvenance: Codable, Hashable, Sendable {
    /// The model as people know it: "whisper", "qwen2.5".
    public var family: String
    /// The build chosen within it: "base", "7b-4bit".
    public var variant: String
    /// The immutable set of files: the primary repository commit, for downloaded models.
    public var revision: String
    /// The engine that ran it: "whisperKit", "mlxLanguage".
    public var engine: String
    /// The engine's version and the runtime underneath it: "1 (WhisperKit 0.18.0)".
    public var engineVersion: String
    /// The model's name when the result was made, so it reads well even where the catalog doesn't know it.
    public var name: String?
    /// Where its files came from: "argmaxinc/whisperkit-coreml".
    public var repository: String?

    public init(family: String, variant: String, revision: String, engine: String, engineVersion: String,
                name: String? = nil, repository: String? = nil) {
        self.family = family; self.variant = variant; self.revision = revision; self.engine = engine
        self.engineVersion = engineVersion; self.name = name; self.repository = repository
    }

    /// "whisper/base": what a selection names and what new results store as their `modelID`.
    public var variantKey: String { "\(family)/\(variant)" }

    private enum CodingKeys: String, CodingKey { case family, variant, revision, engine, engineVersion, name, repository }

    /// Tolerant, so a newer Daybook's provenance (or a damaged field) never makes a meeting unreadable.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        family = try values.decode(String.self, forKey: .family)
        variant = try values.decode(String.self, forKey: .variant)
        revision = (try? values.decodeIfPresent(String.self, forKey: .revision)) ?? ""
        engine = (try? values.decodeIfPresent(String.self, forKey: .engine)) ?? ""
        engineVersion = (try? values.decodeIfPresent(String.self, forKey: .engineVersion)) ?? ""
        name = try? values.decodeIfPresent(String.self, forKey: .name)
        repository = try? values.decodeIfPresent(String.self, forKey: .repository)
    }
}
