import DaybookKit
import Foundation
import Hub

/// Brings an artifact's files onto this Mac. The store owns where they go and verifies them;
/// a fetcher only transfers. Tests inject one that writes synthetic files.
public protocol ModelArtifactFetcher: Sendable {
    /// Downloads `artifact.files` into `directory`, resuming whatever an earlier attempt left there,
    /// and returns the folder that holds them at their repository paths.
    func fetch(_ artifact: ModelArtifact, into directory: URL,
               progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}

/// The download mechanism Daybook has always used: swift-transformers' `HubApi.snapshot`, pinned
/// to the artifact's commit and limited to exactly the manifest's files. HubApi keeps per-file
/// metadata in the directory, so an interrupted download resumes with the files it hasn't finished;
/// since 1.2 (swift-huggingface's client), a file cut off partway starts again.
public struct HubSnapshotFetcher: ModelArtifactFetcher {
    public init() {}

    public func fetch(_ artifact: ModelArtifact, into directory: URL,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        // An empty token keeps HubApi from reading credentials from the environment or disk. No cache: by default
        // every file would also be kept in the shared Hugging Face cache (~/.cache/huggingface/hub), out of reach
        // of Settings › Models, which removes only Daybook's copy.
        let hub = HubApi(downloadBase: directory, cache: nil, hfToken: "", useOfflineMode: false)
        let folder = try await hub.snapshot(from: artifact.repository, revision: artifact.revision,
                                            matching: artifact.files.map { Self.literalGlob($0.path) }) {
            progress($0.fractionCompleted)
        }
        try Task.checkCancellation()
        return folder
    }

    /// HubApi matches with fnmatch; escape a path so it matches only itself.
    package static func literalGlob(_ path: String) -> String {
        var result = ""
        for character in path {
            if "*?[]\\".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
}
