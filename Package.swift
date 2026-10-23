// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Daybook",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Daybook", targets: ["Daybook"]),
        .library(name: "DaybookCore", targets: ["DaybookCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "0.18.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "2.29.3"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: []),
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.1.6")
    ],
    targets: [
        .target(name: "DaybookCore"),
        .executableTarget(name: "Daybook", dependencies: [
            "DaybookCore",
            .product(name: "WhisperKit", package: "WhisperKit"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "FluidAudio", package: "FluidAudio"),
            .product(name: "Hub", package: "swift-transformers"),
            .product(name: "Tokenizers", package: "swift-transformers")
        ]),
        .testTarget(name: "DaybookCoreTests", dependencies: ["DaybookCore"]),
        .testTarget(name: "DaybookTests", dependencies: ["Daybook", "DaybookCore"])
    ],
    swiftLanguageModes: [.v5]
)
