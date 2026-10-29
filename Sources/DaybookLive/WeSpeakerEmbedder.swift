import CoreML
import Foundation

/// One embedding for one stretch of audio from Community-1's FBank and WeSpeaker ResNet34 models:
/// the span is repeated to fill the 10-second window and every frame is weighted, so only that
/// speaker shapes it. This mirrors FluidAudio 0.17.7's internal `OfflineEmbeddingExtractor.embedSpan`
/// (its public `embedSpans` arrives after 0.17.7), including the silence-aware FBank re-centering.
///
/// The one recipe for voice profiles on every device: the Mac's final pipeline embeds speakers with
/// it (Community1VoiceEmbedder.swift), and live captions embed voices with it on the Mac and the
/// iPhone, so all of them land in the space the install declares
/// (`fluid-community1-embedding-df2625ac79a7ac6b` for the built-in model) and compare.
public struct WeSpeakerEmbedder: @unchecked Sendable {
    public let fbank: MLModel
    public let embedding: MLModel
    private let audioShape: [NSNumber]
    private let audioCount: Int
    private let weightShape: [NSNumber]
    private let weightCount: Int

    /// Ten seconds at 16 kHz, the window the FBank model takes.
    public static let window = 160_000
    /// The two bundles it reads from a Community-1 install's model folder.
    public static let requiredFiles = ["FBank.mlmodelc/coremldata.bin", "Embedding.mlmodelc/coremldata.bin"]

    public init(fbank: MLModel, embedding: MLModel) throws {
        self.fbank = fbank
        self.embedding = embedding
        guard let audio = fbank.modelDescription.inputDescriptionsByName["audio"]?.multiArrayConstraint,
              let weights = embedding.modelDescription.inputDescriptionsByName["weights"]?.multiArrayConstraint,
              embedding.modelDescription.inputDescriptionsByName["fbank_features"] != nil,
              embedding.modelDescription.outputDescriptionsByName["embedding"] != nil else {
            throw WeSpeakerError.unexpectedModel
        }
        audioShape = Self.shape(audio, last: Self.window)
        audioCount = min(Self.window, audioShape.last?.intValue ?? Self.window)
        weightShape = Self.shape(weights, last: 589)
        weightCount = weightShape.last?.intValue ?? 589
    }

    /// Loads the two bundles from a Community-1 model folder, local files only: FBank on the CPU (as
    /// Community-1's own pipeline runs it), the embedding model on `computeUnits`.
    public static func load(from folder: URL, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) throws -> WeSpeakerEmbedder {
        func load(_ name: String, units: MLComputeUnits) throws -> MLModel {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            return try MLModel(contentsOf: folder.appendingPathComponent(name + ".mlmodelc"), configuration: configuration)
        }
        return try WeSpeakerEmbedder(fbank: load("FBank", units: .cpuOnly), embedding: load("Embedding", units: computeUnits))
    }

    /// A 256-dimensional embedding of 16 kHz mono `span` (at most 10 seconds are used).
    public func embed(_ span: [Float]) throws -> [Float] {
        guard !span.isEmpty else { return [] }
        var window = [Float]()
        window.reserveCapacity(audioCount)
        while window.count < audioCount { window.append(contentsOf: span.prefix(audioCount - window.count)) }

        let audio = try MLMultiArray(shape: audioShape, dataType: .float32)
        let audioPointer = audio.dataPointer.bindMemory(to: Float.self, capacity: audio.count)
        audioPointer.update(repeating: 0, count: audio.count)
        window.withUnsafeBufferPointer { audioPointer.update(from: $0.baseAddress!, count: min(audio.count, window.count)) }
        guard let features = try fbank.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": MLFeatureValue(multiArray: audio)]))
            .featureValue(for: "fbank_features")?.multiArrayValue else { throw WeSpeakerError.unexpectedModel }
        Self.recenterOnSignal(features, audio: window)

        let weights = try MLMultiArray(shape: weightShape, dataType: .float32)
        let weightPointer = weights.dataPointer.bindMemory(to: Float.self, capacity: weights.count)
        weightPointer.update(repeating: 0, count: weights.count)
        weightPointer.update(repeating: 1, count: min(weightCount, weights.count))
        let output = try embedding.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "fbank_features": MLFeatureValue(multiArray: features), "weights": MLFeatureValue(multiArray: weights)]))
        guard let vector = output.featureValue(for: "embedding")?.multiArrayValue else { throw WeSpeakerError.unexpectedModel }
        return Self.floats(vector)
    }

    /// A fixed input shape: the first enumerated shape, else the declared one; unknown sizes become 1
    /// and the last dimension `last`.
    private static func shape(_ constraint: MLMultiArrayConstraint, last: Int) -> [NSNumber] {
        let declared = constraint.shapeConstraint.enumeratedShapes.first ?? constraint.shape
        guard !declared.isEmpty else { return [1, NSNumber(value: last)] }
        return declared.enumerated().map { index, size in
            size.intValue > 0 ? size : NSNumber(value: index == declared.count - 1 ? last : 1)
        }
    }

    /// FBank subtracts each band's mean over all frames; frames of exact digital silence sit at the
    /// log floor and would pull that mean down. Re-centers on the frames that hold signal, as
    /// FluidAudio's `SilenceAwareFbank` does (25 ms frames every 10 ms). No-op without silent frames.
    public static func recenterOnSignal(_ features: MLMultiArray, audio: [Float]) {
        guard features.dataType == .float32, features.shape.count == 4 else { return }
        let bands = features.shape[2].intValue, frames = features.shape[3].intValue
        let bandStride = features.strides[2].intValue, frameStride = features.strides[3].intValue
        var nonZeroBefore = [Int](repeating: 0, count: audio.count + 1)
        for index in audio.indices { nonZeroBefore[index + 1] = nonZeroBefore[index] + (audio[index] != 0 ? 1 : 0) }
        let silent = (0..<frames).map { frame -> Bool in
            let start = min(frame * 160, audio.count), end = min(start + 400, audio.count)
            return nonZeroBefore[end] == nonZeroBefore[start]
        }
        let voiced = silent.indices.filter { !silent[$0] }
        guard !voiced.isEmpty, voiced.count < silent.count else { return }
        let pointer = features.dataPointer.bindMemory(to: Float.self, capacity: features.count)
        for band in 0..<bands {
            let row = pointer + band * bandStride
            let mean = voiced.reduce(Float(0)) { $0 + row[$1 * frameStride] } / Float(voiced.count)
            for frame in 0..<frames { row[frame * frameStride] -= mean }
        }
    }

    public static func floats(_ array: MLMultiArray) -> [Float] {
        let shape = array.shape.map(\.intValue)
        let contiguous = array.strides.map(\.intValue) == shape.indices.map { shape[($0 + 1)...].reduce(1, *) }
        if array.dataType == .float32, contiguous {
            let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
            return Array(UnsafeBufferPointer(start: pointer, count: array.count))
        }
        return (0..<array.count).map { array[$0].floatValue }
    }
}

public enum WeSpeakerError: LocalizedError {
    case unexpectedModel
    public var errorDescription: String? { "The voice-profile model returned invalid output. Try downloading it again." }
}
