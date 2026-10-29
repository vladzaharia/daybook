// swift-tools-version: 6.2
import PackageDescription

// Layers, bottom up (docs/architecture.md):
//   DaybookCore          models, storage, sync journal, fusion, alignment (macOS + iOS)
//   DaybookDevices       recorders: the device framework, Soundcore over Bluetooth, folders; live captions of
//                        a recorder's live audio through DaybookCaptions (macOS + iOS)
//   DaybookKit           the library both apps share: edits, search, sync, processing status and requests,
//                        recorder handoff (macOS + iOS)
//   DaybookModelStore    the model store: verified downloads and installs of catalog models (macOS + iOS)
//   DaybookLive          live speech on this device: streaming transcription, speaker detection, and
//                        live identification against voice profiles, behind DaybookCaptions' captioner
//                        protocol; and the voice-profile recipe the Mac's final pipeline shares (macOS + iOS)
//   DaybookIntelligence  local models: the Mac's ProcessingEngine (macOS for now; no AppKit)
//   DaybookLink          the Mac <-> iPhone local-network channel: pairing, control, status (macOS + iOS)
//   DaybookCaptions      tentative on-device live captions for any audio source (Speech framework; macOS + iOS)
//   DaybookDesign        the design both apps share: tokens, the rolling meter, the clock, caption strip,
//                        status lines and chips, and the recorder's controls (SwiftUI only; macOS + iOS)
//   Daybook              the Mac app
let package = Package(
    name: "Daybook",
    platforms: [.macOS(.v15), .iOS(.v26)],
    products: [
        .executable(name: "Daybook", targets: ["Daybook"]),
        .library(name: "DaybookCore", targets: ["DaybookCore"]),
        .library(name: "DaybookDevices", targets: ["DaybookDevices"]),
        .library(name: "DaybookKit", targets: ["DaybookKit"]),
        .library(name: "DaybookModelStore", targets: ["DaybookModelStore"]),
        .library(name: "DaybookLive", targets: ["DaybookLive"]),
        .library(name: "DaybookIntelligence", targets: ["DaybookIntelligence"]),
        .library(name: "DaybookLink", targets: ["DaybookLink"]),
        .library(name: "DaybookCaptions", targets: ["DaybookCaptions"]),
        .library(name: "DaybookDesign", targets: ["DaybookDesign"])
    ],
    dependencies: [
        // argmax-oss-swift is the renamed WhisperKit repository; it vendors its own Hub and tokenizer code.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1"),
        // Default traits: FoundationModelsIntegration only gates products Daybook doesn't link (MLXFoundationModels,
        // MLXHuggingFace), and turning it off makes SwiftPM refuse to update a checkout of 2.x, which declared no traits.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.32.3"),
        // mlx-swift-lm asks for 0.32.x; pinned here so the MLX runtime never moves on its own.
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: []),
        // Hub: the model store's downloads. Tokenizers: MLX's tokenizer and chat templates (MLXTokenizerAdapter).
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.3.5")
    ],
    targets: [
        .target(name: "DaybookCore"),
        .target(name: "DaybookLink"),
        // Foundation, AVFoundation, and Speech only, so the device framework can use it too.
        .target(name: "DaybookCaptions"),
        // SwiftUI only, no models: either app's views can use it without the other's code.
        .target(name: "DaybookDesign"),
        .target(name: "DaybookDevices", dependencies: ["DaybookCore", "DaybookCaptions"]),
        // DaybookLink for the recorder handoff's fast path (RecorderHandoff.swift). Resources/ModelCatalog
        // is the built-in model manifest (docs/models.md), shared so the iPhone can name the models behind
        // a result and list their licenses.
        .target(name: "DaybookKit", dependencies: ["DaybookCore", "DaybookDevices", "DaybookLink"],
                resources: [.copy("Resources/ModelCatalog")]),
        // Downloads, verification, and installs (docs/models.md, "Storage"); the iPhone links it for its
        // live models without the Mac's engines. Hub: swift-transformers' downloader.
        .target(name: "DaybookModelStore", dependencies: [
            "DaybookCore",
            "DaybookKit",
            .product(name: "Hub", package: "swift-transformers")
        ]),
        // Live captions from local models (docs/model-runtime.md, "Live"): FluidAudio only, no MLX or
        // WhisperKit, so the iPhone links it without the Mac's processing stack.
        .target(name: "DaybookLive", dependencies: [
            "DaybookCore",
            "DaybookKit",
            "DaybookCaptions",
            "DaybookModelStore",
            .product(name: "FluidAudio", package: "FluidAudio")
        ]),
        .target(name: "DaybookIntelligence", dependencies: [
            "DaybookCore",
            "DaybookKit",
            "DaybookModelStore",
            "DaybookLive",
            .product(name: "WhisperKit", package: "argmax-oss-swift"),
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            // Gemma 4's vision tower, for photo captions (docs/models.md, "Photos").
            .product(name: "MLXVLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLXGuidedGeneration", package: "mlx-swift-lm"),
            .product(name: "FluidAudio", package: "FluidAudio"),
            .product(name: "Hub", package: "swift-transformers"),
            .product(name: "Tokenizers", package: "swift-transformers")
        ]),
        .executableTarget(name: "Daybook", dependencies: [
            "DaybookCore",
            "DaybookDevices",
            "DaybookKit",
            "DaybookModelStore",
            "DaybookLive",
            "DaybookIntelligence",
            "DaybookLink",
            "DaybookCaptions",
            "DaybookDesign"
        ]),
        // What every test bundle shares (Tests/DaybookTestSupport): waiting for something to happen, and
        // UserDefaults suites that are removed when a test ends.
        .target(name: "DaybookTestSupport", path: "Tests/DaybookTestSupport"),
        .testTarget(name: "DaybookCoreTests", dependencies: ["DaybookCore", "DaybookTestSupport"]),
        // Device tests decode transferred audio with DaybookIntelligence's reader (macOS).
        .testTarget(name: "DaybookDevicesTests", dependencies: ["DaybookDevices", "DaybookCore", "DaybookIntelligence", "DaybookCaptions",
                                                               "DaybookTestSupport"]),
        .testTarget(name: "DaybookKitTests", dependencies: ["DaybookKit", "DaybookCore", "DaybookDevices", "DaybookLink", "DaybookTestSupport"]),
        .testTarget(name: "DaybookIntelligenceTests", dependencies: [
            "DaybookIntelligence",
            "DaybookModelStore",
            "DaybookKit",
            "DaybookCore",
            "DaybookTestSupport",
            .product(name: "FluidAudio", package: "FluidAudio")
        ]),
        .testTarget(name: "DaybookTests", dependencies: [
            "Daybook",
            "DaybookCore",
            "DaybookDevices",
            "DaybookKit",
            "DaybookModelStore",
            "DaybookLive",
            "DaybookIntelligence",
            "DaybookLink",
            "DaybookCaptions",
            "DaybookDesign",
            "DaybookTestSupport"
        ], resources: [.copy("Fixtures")]), // Fixtures/Shipped: files written by shipped versions.
        .testTarget(name: "DaybookLinkTests", dependencies: ["DaybookLink", "DaybookTestSupport"]),
        .testTarget(name: "DaybookCaptionsTests", dependencies: ["DaybookCaptions", "DaybookTestSupport"]),
        .testTarget(name: "DaybookLiveTests", dependencies: ["DaybookLive", "DaybookCaptions", "DaybookKit", "DaybookCore",
                                                             "DaybookModelStore", "DaybookTestSupport"])
    ],
    swiftLanguageModes: [.v5]
)
