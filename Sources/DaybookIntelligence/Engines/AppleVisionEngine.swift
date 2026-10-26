import CoreGraphics
import DaybookCore
import DaybookKit
import Foundation
import ImageIO
import Vision

/// Apple's Vision framework, part of macOS and iOS: nothing to download, always available. It serves
/// `imageDescription`: it reads the text in a photo (`VNRecognizeTextRequest`, accurate, with language
/// correction), classifies what it shows (`VNClassifyImageRequest`), measures its sharpness (the
/// variance of a Laplacian over a downscaled grey copy), and finds near copies in a batch
/// (`VNGenerateImageFeaturePrintRequest` distances). Its caption is built from the top label and the
/// first line of text. Every photo is read with it, whichever model writes the caption.
public struct AppleVisionEngine: ModelEngine {
    public init() {}

    public var descriptor: ModelEngineDescriptor {
        ModelEngineDescriptor(id: .appleVision, name: "Apple Vision", version: 1, runtime: Self.runtime,
                              roles: [.imageDescription], platforms: [.macOS, .iOS], residency: .system)
    }

    /// Vision changes with the OS, so provenance records the OS version.
    static var runtime: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let system = ModelPlatform.current == .iOS ? "iOS" : "macOS"
        return "Vision, \(system) \(version.majorVersion).\(version.minorVersion)"
    }

    public func validate(_ installation: ModelInstallation) throws {
        guard installation.receipt.artifacts.isEmpty else { throw LocalIntelligenceError.modelNotInstalled(installation.key.variantKey) }
    }

    public func proposeAddition(_ request: ModelAdditionRequest, repository: ModelRepositorySnapshot) async throws -> ModelAdditionProposal {
        throw ModelAdditionError.invalid(["Apple Vision is part of the system, so there’s nothing to add."])
    }

    public func load(_ installation: ModelInstallation, role: ModelRole,
                     progress: @escaping IntelligenceProgressHandler) async throws -> any LoadedModel {
        try validate(installation)
        return VisionImageReader()
    }
}

/// Apple Vision as `DescribingImages`.
final class VisionImageReader: DescribingImages, @unchecked Sendable {
    /// Feature-print distance under which two photos are near copies (a re-take of the same slide,
    /// the same shot re-encoded). Different scenes measure well above it.
    static let duplicateDistance: Float = 0.45
    /// Labels below this confidence aren't reported.
    static let labelConfidence: Float = 0.35

    func describe(_ requests: [ImageDescriptionRequest], progress: @escaping IntelligenceProgressHandler) async throws -> [ImageDescription] {
        var results: [ImageDescription] = []
        var prints: [VNFeaturePrintObservation?] = []
        for (index, request) in requests.enumerated() {
            try Task.checkCancellation()
            progress(.init(Double(index) / Double(max(1, requests.count)), "Reading photo \(index + 1) of \(requests.count)"))
            let read = try await Task.detached(priority: .userInitiated) { try Self.read(request.url, compareOnly: request.compareOnly) }.value
            var description = read.description
            if let print = read.print {
                for (earlier, other) in prints.enumerated() {
                    guard let other else { continue }
                    var distance: Float = .infinity
                    if (try? print.computeDistance(&distance, to: other)) != nil, distance < Self.duplicateDistance {
                        description.duplicateOf = earlier
                        break
                    }
                }
            }
            prints.append(read.print)
            results.append(description)
        }
        return results
    }

    /// Reads one image off the actor. `compareOnly` makes the feature print only.
    static func read(_ url: URL, compareOnly: Bool) throws -> (description: ImageDescription, print: VNFeaturePrintObservation?) {
        guard let image = thumbnail(url, maxPixels: 2048) else { throw PhotoStoreError.unsupportedImage(url.lastPathComponent) }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let featurePrint = VNGenerateImageFeaturePrintRequest()
        guard !compareOnly else {
            try handler.perform([featurePrint])
            return (ImageDescription(), featurePrint.results?.first)
        }
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = true
        text.automaticallyDetectsLanguage = true
        let classify = VNClassifyImageRequest()
        try handler.perform([text, classify, featurePrint])
        let lines = (text.results ?? []).compactMap { observation -> String? in
            guard let best = observation.topCandidates(1).first, best.confidence >= 0.3 else { return nil }
            let line = best.string.trimmingCharacters(in: .whitespaces)
            return line.isEmpty ? nil : line
        }
        let recognized = lines.isEmpty ? nil : lines.joined(separator: "\n")
        let labels = (classify.results ?? []).filter { $0.confidence >= labelConfidence }.sorted { $0.confidence > $1.confidence }
            .prefix(4).map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
        let description = ImageDescription(caption: PhotoReading.visionCaption(labels: Array(labels), text: recognized),
                                           recognizedText: recognized, labels: Array(labels), sharpness: sharpness(image))
        return (description, featurePrint.results?.first)
    }

    /// The image upright (its EXIF orientation applied), at most `maxPixels` on its long side.
    static func thumbnail(_ url: URL, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixels, kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// From 0 (blurred, or flat) to 1 (sharp): the variance of a 4-neighbour Laplacian over a grey copy
    /// at most 512 pixels on its long side, mapped as `v / (v + 120)`. A focused photo of text or a
    /// scene measures well above 0.3; a defocused or motion-blurred one, under 0.1.
    static func sharpness(_ image: CGImage) -> Double {
        let scale = min(1, 512 / Double(max(image.width, image.height)))
        let width = max(3, Int(Double(image.width) * scale)), height = max(3, Int(Double(image.height) * scale))
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }
        var sum = 0.0, squares = 0.0, count = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let center = Double(pixels[y * width + x])
                let value = Double(pixels[(y - 1) * width + x]) + Double(pixels[(y + 1) * width + x])
                    + Double(pixels[y * width + x - 1]) + Double(pixels[y * width + x + 1]) - 4 * center
                sum += value; squares += value * value; count += 1
            }
        }
        guard count > 0 else { return 0 }
        let mean = sum / count
        let variance = max(0, squares / count - mean * mean)
        return variance / (variance + 120)
    }
}
