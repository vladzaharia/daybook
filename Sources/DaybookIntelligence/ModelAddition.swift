import Darwin
import DaybookKit
import Foundation

/// Adding a model from Hugging Face by repository and revision (docs/models.md, "Manifests"). The
/// engine decides whether it can run it; the result goes into the person's manifest, labelled
/// "Added by you", and downloads like any other model.
public struct ModelAdditionRequest: Sendable {
    /// "mlx-community/gemma-4-12B-it-4bit"
    public var repository: String
    /// A commit, or a branch resolved to its current commit ("main").
    public var revision: String
    public var role: ModelRole
    public var engine: ModelEngineID
    /// What the person calls it: "Gemma 4 12B · 4-bit".
    public var variantName: String
    /// An existing family to join ("qwen2.5"), or nil for a new family named after the repository.
    public var familyID: String?
    public var familyName: String?
    /// Engine-specific settings: "subdirectory" (WhisperKit, Sortformer), "tokenizerRepository" and
    /// "tokenizerRevision" (WhisperKit), "precision" (Sortformer).
    public var options: [String: String]

    public init(repository: String, revision: String = "main", role: ModelRole, engine: ModelEngineID, variantName: String,
                familyID: String? = nil, familyName: String? = nil, options: [String: String] = [:]) {
        self.repository = repository; self.revision = revision; self.role = role; self.engine = engine
        self.variantName = variantName; self.familyID = familyID; self.familyName = familyName; self.options = options
    }
}

/// One repository at one commit, as an engine inspects it.
public struct ModelRepositorySnapshot: Sendable {
    public let repository: String
    public let commit: ModelHubCommit
    public let files: [ModelHubFile]
    let client: any ModelHubClient

    public init(repository: String, commit: ModelHubCommit, files: [ModelHubFile], client: any ModelHubClient) {
        self.repository = repository; self.commit = commit; self.files = files; self.client = client
    }

    /// Lists `repository` at `revision` (a branch or commit) through `client`.
    public static func load(_ repository: String, revision: String, client: any ModelHubClient) async throws -> ModelRepositorySnapshot {
        let commit = try await client.commit(repository: repository, reference: revision)
        let files = try await client.files(repository: repository, revision: commit.id, path: nil)
        return ModelRepositorySnapshot(repository: repository, commit: commit, files: files, client: client)
    }

    public func contains(_ path: String) -> Bool { files.contains { $0.path == path } }

    /// Files matching any of `patterns` (fnmatch, where `*` also matches "/").
    public func files(matching patterns: [String]) -> [ModelHubFile] {
        files.filter { file in patterns.contains { ModelGlob.matches($0, file.path) } }
    }

    /// A small file's content: a config or tokenizer config, never weights.
    public func data(_ path: String, maxBytes: Int = 2_000_000) async throws -> Data {
        try await client.data(repository: repository, revision: commit.id, path: path, maxBytes: maxBytes)
    }

    /// Another repository through the same client (a WhisperKit model's tokenizer).
    public func other(_ repository: String, revision: String) async throws -> ModelRepositorySnapshot {
        try await Self.load(repository, revision: revision, client: client)
    }

    /// An artifact of the files matching `include`, pinned to this commit.
    public func artifact(_ name: String, include: [String], root: String? = nil) throws -> ModelArtifact {
        let chosen = files(matching: include)
        guard !chosen.isEmpty else {
            let patterns = include.joined(separator: ", ")
            throw ModelAdditionError.invalid(["No files in \(repository) match \(patterns)."])
        }
        return ModelArtifact(name: name, repository: repository, revision: commit.id, include: include, root: root,
                             files: chosen.map(\.manifestFile).sorted { $0.path < $1.path })
    }
}

/// What an engine proposes for an added model.
public struct ModelAdditionProposal: Sendable {
    public var artifacts: [ModelArtifact]
    public var capabilities: ModelCapabilities
    public var engineOptions: [String: String]
    public var recommendedMemoryGB: Int?

    public init(artifacts: [ModelArtifact], capabilities: ModelCapabilities = .init(), engineOptions: [String: String] = [:],
                recommendedMemoryGB: Int? = nil) {
        self.artifacts = artifacts; self.capabilities = capabilities; self.engineOptions = engineOptions
        self.recommendedMemoryGB = recommendedMemoryGB
    }
}

public enum ModelAdditionError: LocalizedError, Equatable {
    /// The engine can't run it, with each reason in plain words.
    case invalid([String])
    case unknownEngine(ModelEngineID)
    case unsupportedRole(ModelRole, ModelEngineID)
    case gated(String)
    case duplicate(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let reasons): return reasons.joined(separator: " ")
        case .unknownEngine(let engine): return "This Daybook can’t run \(engine) models yet."
        case .unsupportedRole(let role, let engine): return "\(engine) models can’t be used for \(role)."
        case .gated(let repository): return "\(repository) requires accepting its terms on Hugging Face, so Daybook can’t download it."
        case .duplicate(let name): return "\(name) is already in your models."
        }
    }
}

/// fnmatch with Hugging Face's semantics: no special treatment of "/".
enum ModelGlob {
    static func matches(_ pattern: String, _ path: String) -> Bool { fnmatch(pattern, path, 0) == 0 }
}

/// Turns names into identifiers safe for manifests and folders.
enum ModelIdentifier {
    static func slug(_ text: String) -> String {
        var result = ""
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII { result.unicodeScalars.append(scalar) }
            else if scalar == "." || scalar == "-" || scalar == "_" { result.unicodeScalars.append(scalar) }
            else if !result.hasSuffix("-") { result += "-" }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        return String((trimmed.isEmpty ? "model" : trimmed).prefix(96))
    }

    /// The license as a card declares it, in Daybook's terms. Unknown terms are not treated as
    /// allowing commercial use.
    static func license(from info: ModelHubRepositoryInfo?, repository: String) -> ModelLicense {
        let card = "https://huggingface.co/\(repository)"
        let permissive: [String: String] = ["mit": "MIT License", "apache-2.0": "Apache License 2.0", "cc-by-4.0": "CC BY 4.0",
                                            "bsd-3-clause": "BSD 3-Clause License"]
        guard let id = info?.license?.lowercased() else {
            return ModelLicense(name: "License not stated", url: card, allowsCommercialUse: false)
        }
        if let name = permissive[id] {
            return ModelLicense(id: id, name: name, url: info?.licenseURL ?? card, allowsCommercialUse: true)
        }
        let name = info?.licenseName ?? id
        return ModelLicense(id: name, name: name, url: info?.licenseURL ?? card, allowsCommercialUse: false)
    }
}
