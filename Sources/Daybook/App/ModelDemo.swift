import DaybookIntelligence
import DaybookKit
import Foundation

/// Debug-only model manager demos, for screenshots and checks without the network:
///
///     --model-demo <step>[,<step>…]
///       preset:<quick|balanced|detailed>   choose a preset first
///       use:<role>=<key>                   then choose a model for a role (Custom)
///       downloading:<key>                  start a download that stops partway (nothing is fetched)
///       updates:<key>                      check for updates against a scripted Hugging Face that has
///                                          a newer revision of <key>
///       add                                open Add Model on a scripted repository and check it
///       details:<key>  remove:<key>        open a model's details, or its removal confirmation
///       acknowledgements                   open Acknowledgements
///       about                              open the About Daybook panel (its credits)
///       scroll:<library|updates|family:<id>>  scroll the pane
///
/// Installs come from the library's Models folder, so pair it with synthetic installs. In release
/// builds nothing here does anything.
enum ModelDemo {
    /// The scripted repository Add Model opens on.
    static let addRepository = "mlx-community/Qwen2.5-0.5B-Instruct-4bit"

    #if DEBUG
    static let steps: [String] = LaunchOptions.value(after: "--model-demo")?.split(separator: ",").map(String.init) ?? []
    #else
    static let steps: [String] = []
    #endif

    static var isRequested: Bool { !steps.isEmpty }

    /// The value of a "name:value" step, or "" for a bare "name".
    static func value(_ name: String) -> String? {
        for step in steps {
            if step == name { return "" }
            if step.hasPrefix(name + ":") { return String(step.dropFirst(name.count + 1)) }
        }
        return nil
    }

    /// Downloads that report progress and then wait, writing nothing.
    static var fetcher: (any ModelArtifactFetcher)? {
        #if DEBUG
        return isRequested ? StalledFetcher() : nil
        #else
        return nil
        #endif
    }

    /// A scripted Hugging Face for demos; nil normally.
    static func hubClient(catalog: ModelCatalog) -> (any ModelHubClient)? {
        #if DEBUG
        return isRequested ? ScriptedHub(catalog: catalog, updated: value("updates")) : nil
        #else
        return nil
        #endif
    }
}

#if DEBUG
/// Reports 42% of each artifact, then waits until cancelled.
private struct StalledFetcher: ModelArtifactFetcher {
    func fetch(_ artifact: ModelArtifact, into directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        progress(0.42)
        try await Task.sleep(for: .seconds(24 * 3600))
        throw CancellationError()
    }
}

/// Hugging Face as the catalog describes it: every repository at the commits the catalog pins,
/// plus, for `updated`, a newer commit in which three of its files changed; and one repository
/// to add (`ModelDemo.addRepository`).
private struct ScriptedHub: ModelHubClient {
    let catalog: ModelCatalog
    let updated: String?

    private static let newCommit = "5e1f0c2d9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d"
    private static let addCommit = "c58bd6a3f2e1d0c9b8a7f6e5d4c3b2a1f0e9d8c7"

    private var updatedArtifact: ModelArtifact? {
        updated.flatMap { catalog.model($0) }?.latestRevision?.artifacts.first
    }

    func commit(repository: String, reference: String) async throws -> ModelHubCommit {
        if repository == ModelDemo.addRepository {
            return ModelHubCommit(id: Self.addCommit, date: Date(timeIntervalSince1970: 1_726_617_600), title: "Upload folder using huggingface_hub")
        }
        if let artifact = updatedArtifact, artifact.repository == repository, reference == "main" || reference == Self.newCommit {
            return ModelHubCommit(id: Self.newCommit, date: Date().addingTimeInterval(-4 * 86_400), title: "Re-export with corrected timestamps")
        }
        guard let pinned = artifacts(in: repository).first?.revision else { throw ModelHubError.notFound(repository) }
        return ModelHubCommit(id: reference == "main" ? pinned : reference)
    }

    func files(repository: String, revision: String, path: String?) async throws -> [ModelHubFile] {
        var files: [ModelHubFile]
        if repository == ModelDemo.addRepository {
            files = Self.addFiles
        } else {
            var seen = Set<String>()
            files = artifacts(in: repository).flatMap(\.files).filter { seen.insert($0.path).inserted }
                .map { ModelHubFile(path: $0.path, size: $0.size, sha256: $0.sha256, gitOID: $0.gitOID) }
            if revision == Self.newCommit, let artifact = updatedArtifact, artifact.repository == repository {
                let changed = Set(artifact.files.sorted { $0.size > $1.size }.prefix(3).map(\.path))
                files = files.map { file in
                    guard changed.contains(file.path) else { return file }
                    return ModelHubFile(path: file.path, size: file.size + 4_096, sha256: String(repeating: "e", count: 64))
                }
            }
        }
        guard let path else { return files }
        return files.filter { $0.path.hasPrefix(path + "/") }
    }

    func data(repository: String, revision: String, path: String, maxBytes: Int) async throws -> Data {
        guard repository == ModelDemo.addRepository, path == "config.json" else { throw ModelHubError.notFound(path) }
        return Data("""
        {"model_type": "qwen2", "hidden_size": 8, "num_hidden_layers": 1, "intermediate_size": 16, "num_attention_heads": 2,
         "num_key_value_heads": 1, "rms_norm_eps": 1e-6, "vocab_size": 32, "max_position_embeddings": 32768, "tie_word_embeddings": true}
        """.utf8)
    }

    func info(repository: String) async throws -> ModelHubRepositoryInfo {
        repository == ModelDemo.addRepository ? ModelHubRepositoryInfo(license: "apache-2.0") : ModelHubRepositoryInfo()
    }

    private func artifacts(in repository: String) -> [ModelArtifact] {
        catalog.models.flatMap { $0.variant.revisions.flatMap(\.artifacts) }.filter { $0.repository == repository }
    }

    private static let addFiles: [ModelHubFile] = [
        ModelHubFile(path: ".gitattributes", size: 1_570, gitOID: String(repeating: "1", count: 40)),
        ModelHubFile(path: "README.md", size: 2_847, gitOID: String(repeating: "2", count: 40)),
        ModelHubFile(path: "added_tokens.json", size: 605, gitOID: String(repeating: "3", count: 40)),
        ModelHubFile(path: "config.json", size: 836, gitOID: String(repeating: "4", count: 40)),
        ModelHubFile(path: "merges.txt", size: 1_671_853, gitOID: String(repeating: "5", count: 40)),
        ModelHubFile(path: "model.safetensors", size: 278_064_920, sha256: String(repeating: "a", count: 64)),
        ModelHubFile(path: "model.safetensors.index.json", size: 48_216, gitOID: String(repeating: "6", count: 40)),
        ModelHubFile(path: "special_tokens_map.json", size: 613, gitOID: String(repeating: "7", count: 40)),
        ModelHubFile(path: "tokenizer.json", size: 7_031_645, sha256: String(repeating: "b", count: 64)),
        ModelHubFile(path: "tokenizer_config.json", size: 7_306, gitOID: String(repeating: "8", count: 40)),
        ModelHubFile(path: "vocab.json", size: 2_776_833, gitOID: String(repeating: "9", count: 40))
    ]
}
#endif
