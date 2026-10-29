import DaybookModelStore
import FluidAudio
import Foundation

/// Holds the live models in memory while captures use them, once each: a Mac captioning You and Call
/// loads its streaming recognizer and speaker model once and gives each capture its own state.
/// Models are released `idleRelease` after the last capture using them ends (zero on an iPhone,
/// where memory is tight; a short wait on a Mac, so back-to-back recordings don't reload), and at
/// once by `releaseIdle` (memory pressure, a model removed). While loaded, their revisions are leased
/// in the store, so removal and garbage collection leave them alone.
public actor LiveModelHost {
    enum Kind: String { case transcription, diarization, embedding }

    private final class Loaded {
        let task: Task<any Sendable, Error>
        var users = 0
        var release: Task<Void, Never>?
        var lease: UUID?
        init(task: Task<any Sendable, Error>) { self.task = task }
    }

    private struct Key: Hashable { var kind: String; var install: ModelInstallKey }

    private let idleRelease: Duration
    private let store: ModelStore?
    private var loaded: [Key: Loaded] = [:]

    public init(idleRelease: Duration, store: ModelStore? = nil) {
        self.idleRelease = idleRelease
        self.store = store
    }

    /// How many models are loaded or loading, for tests and diagnostics.
    public var loadedCount: Int { loaded.count }

    // MARK: Using models

    func useTranscription(_ installation: ModelInstallation) async throws -> SharedNemotronMultilingualModels {
        let folder = installation.folder(for: "model")
        return try await use(.transcription, installation) { try await NemotronStreamingTranscriber.loadShared(from: folder) }
    }

    func useDiarization(_ installation: ModelInstallation) async throws -> LoadedDiarizer {
        let folder = installation.folder(for: "model"), options = installation.engineOptions
        return try await use(.diarization, installation) {
            let (models, config) = try await NemotronLiveDiarizer.load(folder, options: options)
            return LoadedDiarizer(models: models, config: config)
        }
    }

    func useEmbedding(_ installation: ModelInstallation) async throws -> WeSpeakerEmbedder {
        let folder = installation.folder(for: "model")
        return try await use(.embedding, installation) { try WeSpeakerEmbedder.load(from: folder) }
    }

    /// A capture stopped using a model it got from `use…`.
    func done(_ kind: Kind, _ installation: ModelInstallation) {
        let key = Key(kind: kind.rawValue, install: installation.key)
        guard let entry = loaded[key] else { return }
        entry.users -= 1
        guard entry.users <= 0 else { return }
        let delay = idleRelease
        entry.release?.cancel()
        entry.release = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.drop(key, ifUnused: true)
        }
    }

    /// Releases every model nobody is using now; models in use go when their captures end.
    public func releaseIdle() async {
        for (key, entry) in loaded where entry.users <= 0 { await drop(key, ifUnused: true) }
    }

    private func use<Value: Sendable>(_ kind: Kind, _ installation: ModelInstallation,
                                      load: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let key = Key(kind: kind.rawValue, install: installation.key)
        let entry: Loaded
        if let existing = loaded[key] {
            entry = existing
        } else {
            entry = Loaded(task: Task(priority: .utility) { try await load() })
            loaded[key] = entry
            let lease = await store?.lease([installation.key])
            if loaded[key] === entry { entry.lease = lease } else if let lease { await store?.endLease(lease) }
        }
        entry.users += 1
        entry.release?.cancel()
        entry.release = nil
        do {
            guard let value = try await entry.task.value as? Value else { throw LiveModelError.damaged(installation.receipt.name) }
            return value
        } catch {
            entry.users -= 1
            if loaded[key] === entry { await drop(key, ifUnused: false) }
            throw error
        }
    }

    private func drop(_ key: Key, ifUnused: Bool) async {
        guard let entry = loaded[key], !ifUnused || entry.users <= 0 else { return }
        loaded[key] = nil
        entry.release?.cancel()
        if let lease = entry.lease { await store?.endLease(lease) }
    }
}

/// A loaded live speaker model and the preset it was converted for.
struct LoadedDiarizer: @unchecked Sendable {
    let models: Nemotron3Models
    let config: Nemotron3Config
}
