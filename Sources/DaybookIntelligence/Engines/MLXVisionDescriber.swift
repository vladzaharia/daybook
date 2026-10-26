import CoreImage
import DaybookCore
import DaybookKit
import Foundation
import MLX
import MLXLMCommon
import MLXVLM

/// A vision-language model through mlx-swift-lm's MLXVLM (Gemma 4 E2B and E4B, whose MLX conversions
/// carry the vision tower beside the language model): one short caption per photo. The same install
/// that writes summaries, loaded with `VLMModelFactory` instead of `LLMModelFactory`, so describing
/// photos needs no second download. Text the photo contains (from Apple Vision) goes in the prompt as
/// untrusted context.
final class MLXVisionDescriber: DescribingImages, @unchecked Sendable {
    private let lock = NSLock()
    private var container: ModelContainer?
    private let chatTemplateContext: [String: any Sendable]?
    let loadSeconds: Double

    init(container: ModelContainer, chatTemplateContext: [String: any Sendable]?, loadSeconds: Double) {
        self.container = container
        self.chatTemplateContext = chatTemplateContext
        self.loadSeconds = loadSeconds
    }

    static func load(from folder: URL, engineOptions: [String: String]) async throws -> MLXVisionDescriber {
        Memory.cacheLimit = 256 * 1_024 * 1_024
        let started = Date()
        let container = try await VLMModelFactory.shared.loadContainer(from: folder, using: MLXLocalTokenizerLoader())
        return MLXVisionDescriber(container: container, chatTemplateContext: MLXLanguageEngine.chatTemplateContext(engineOptions: engineOptions),
                                  loadSeconds: Date().timeIntervalSince(started))
    }

    func describe(_ requests: [ImageDescriptionRequest], progress: @escaping IntelligenceProgressHandler) async throws -> [ImageDescription] {
        guard let container = lock.withLock({ container }) else { throw LocalIntelligenceError.emptyResponse }
        var results: [ImageDescription] = []
        for (index, request) in requests.enumerated() {
            try Task.checkCancellation()
            guard !request.compareOnly else { results.append(ImageDescription()); continue }
            progress(.init(Double(index) / Double(max(1, requests.count)), "Describing photo \(index + 1) of \(requests.count)"))
            // Upright and at most 1,024 pixels: the processor resizes further for the vision tower.
            guard let image = VisionImageReader.thumbnail(request.url, maxPixels: 1024) else {
                throw PhotoStoreError.unsupportedImage(request.url.lastPathComponent)
            }
            let session = ChatSession(container, instructions: PhotoCaptionPrompt.instructions,
                                      generateParameters: .init(maxTokens: 64, temperature: 0, repetitionPenalty: 1.05,
                                                                repetitionContextSize: 32),
                                      additionalContext: chatTemplateContext)
            let reply = try await session.respond(to: PhotoCaptionPrompt.prompt(recognizedText: request.recognizedText),
                                                  image: .ciImage(CIImage(cgImage: image)))
            try Task.checkCancellation()
            results.append(ImageDescription(caption: PhotoReading.cleanCaption(reply)))
        }
        return results
    }

    func unload() {
        lock.withLock { container = nil }
        Memory.clearCache()
    }
}
