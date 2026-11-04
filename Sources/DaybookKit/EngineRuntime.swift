import Foundation

/// The libraries Daybook's engines run on, by the names their results record as provenance
/// (`ModelEngineDescriptor.runtime`, docs/models.md): the package and the version Package.swift pins.
/// `EngineRuntimeTests` checks each against Package.resolved, so moving a pin without changing it
/// here fails rather than leaving results that name the old version.
public enum EngineRuntime {
    /// FluidAudio: Parakeet, Sortformer, Community-1, and the Nemotron live and speaker models.
    public static let fluidAudio = "FluidAudio 0.18.0"
    /// mlx-swift-lm: the language models that write summaries and titles.
    public static let mlxLanguage = "mlx-swift-lm 3.32.3"
    /// argmax-oss-swift, the renamed WhisperKit repository: Whisper on the Mac.
    public static let whisperKit = "argmax-oss-swift 1.1.1"

    /// Every runtime above, by the package identity Package.resolved lists it under.
    public static let pinned: [(package: String, runtime: String)] = [
        ("fluidaudio", fluidAudio), ("mlx-swift-lm", mlxLanguage), ("argmax-oss-swift", whisperKit),
    ]
}
