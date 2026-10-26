import CoreGraphics
import CoreText
import DaybookCore
import DaybookKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import DaybookIntelligence

/// Photos to captions, text, and placements: Apple Vision on images drawn in the test (no camera, no
/// photo library), the engine's routing over a scripted `MeetingInference`, and the summary schema
/// and its validation through a scripted language model. No weights are loaded.
final class PhotoUnderstandingTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookPhotoUnderstanding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    // MARK: Synthetic images

    /// A white "whiteboard" with black lines of text, optionally blurred by drawing it small and scaling up.
    private func whiteboard(_ lines: [String], blurred: Bool = false, shift: CGFloat = 0) -> CGImage {
        let width = 1200, height = 800
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 72, nil)
        for (index, line) in lines.enumerated() {
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1)]
            let text = CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attributes))
            context.textPosition = CGPoint(x: 80 + shift, y: CGFloat(height - 180 - index * 140))
            CTLineDraw(text, context)
        }
        let sharp = context.makeImage()!
        guard blurred else { return sharp }
        // Down to a twentieth and back up: a defocused copy too soft to read.
        let small = CGContext(data: nil, width: width / 20, height: height / 20, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        small.interpolationQuality = .high
        small.draw(sharp, in: CGRect(x: 0, y: 0, width: width / 20, height: height / 20))
        let large = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        large.interpolationQuality = .high
        large.draw(small.makeImage()!, in: CGRect(x: 0, y: 0, width: width, height: height))
        return large.makeImage()!
    }

    private func file(_ image: CGImage, _ name: String, type: UTType = .jpeg, quality: Double = 0.9) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    // MARK: Apple Vision

    private func visionReader() async throws -> any DescribingImages {
        let reader = try await AppleVisionEngine().load(ModelInstallation(receipt: ModelInstallReceipt(
            model: try XCTUnwrap(ModelCatalog.builtIn.model("apple-vision/system")), revision: ModelRevisionEntry(id: "system", artifacts: []),
            installedAt: Date()), directory: folder), role: .imageDescription, progress: { _ in })
        return try XCTUnwrap(reader as? any DescribingImages)
    }

    /// Everywhere, text recognition or not (it can't run in some virtual machines, CI's among them).
    func testAppleVisionJudgesSharpnessAndFindsNearCopies() async throws {
        let board = whiteboard(["LAUNCH PLAN", "BUDGET REVIEW"])
        let sharp = try file(board, "board.jpg")
        let copy = try file(board, "board-again.jpg", quality: 0.6)
        let blurred = try file(whiteboard(["LAUNCH PLAN", "BUDGET REVIEW"], blurred: true), "blurred.jpg")
        let other = try file(whiteboard(["HIRING", "TWO DESIGNERS", "ONE RECRUITER"], shift: 200), "other.png", type: .png)
        let describer = try await visionReader()
        let results = try await describer.describe([sharp, copy, blurred, other].map { ImageDescriptionRequest(url: $0) }, progress: { _ in })
        XCTAssertEqual(results.count, 4)
        XCTAssertGreaterThan(results[0].sharpness ?? 0, 0.3)
        XCTAssertLessThan(results[2].sharpness ?? 1, PhotoReading.minimumSharpness, "a defocused copy reads as blurred")
        XCTAssertEqual(results[1].duplicateOf, 0, "the same shot again is a near copy")
        XCTAssertNil(results[3].duplicateOf, "a different board isn't")
        XCTAssertFalse(PhotoReading.isInformative(results[1], caption: results[1].caption))
        XCTAssertFalse(PhotoReading.isInformative(results[2], caption: results[2].caption))
        if !VisionImageReader.canRecognizeText { XCTAssertNil(results[0].recognizedText, "no text where it can't be read") }
        // Compare-only requests read nothing but still count for near copies.
        let compared = try await describer.describe([ImageDescriptionRequest(url: sharp, compareOnly: true), ImageDescriptionRequest(url: copy)],
                                                    progress: { _ in })
        XCTAssertNil(compared[0].recognizedText)
        XCTAssertEqual(compared[1].duplicateOf, 0)
    }

    /// Reported as skipped, not passed, where text recognition can't run.
    func testAppleVisionReadsTheTextOnABoard() async throws {
        try XCTSkipUnless(VisionImageReader.canRecognizeText, "Text recognition can't run on this machine (some virtual machines).")
        let sharp = try file(whiteboard(["LAUNCH PLAN", "BUDGET REVIEW"]), "board.jpg")
        let other = try file(whiteboard(["HIRING", "TWO DESIGNERS", "ONE RECRUITER"], shift: 200), "other.png", type: .png)
        let results = try await visionReader().describe([sharp, other].map { ImageDescriptionRequest(url: $0) }, progress: { _ in })
        let text = results[0].recognizedText?.uppercased() ?? ""
        XCTAssertTrue(text.contains("LAUNCH PLAN"), text)
        XCTAssertTrue(text.contains("BUDGET"), text)
        XCTAssertTrue(results[1].recognizedText?.uppercased().contains("DESIGNERS") == true)
        XCTAssertTrue(PhotoReading.isInformative(results[0], caption: results[0].caption))
        XCTAssertNotNil(results[0].caption)
    }

    /// What makes a photo informative, from readings as Vision reports them (text included), so it's
    /// checked everywhere.
    func testASharpOriginalWithTextOrLabelsIsInformative() {
        let board = ImageDescription(caption: PhotoReading.visionCaption(labels: [], text: "LAUNCH PLAN\nBUDGET REVIEW"),
                                     recognizedText: "LAUNCH PLAN\nBUDGET REVIEW", labels: [], sharpness: 0.8)
        XCTAssertEqual(board.caption, "“LAUNCH PLAN”")
        XCTAssertTrue(PhotoReading.isInformative(board, caption: board.caption), "text alone is enough")
        let labelled = ImageDescription(caption: PhotoReading.visionCaption(labels: ["whiteboard"], text: "LAUNCH PLAN"),
                                        recognizedText: "LAUNCH PLAN", labels: ["whiteboard"], sharpness: 0.8)
        XCTAssertEqual(labelled.caption, "Whiteboard · “LAUNCH PLAN”")
        XCTAssertTrue(PhotoReading.isInformative(labelled, caption: labelled.caption))
        let scene = ImageDescription(caption: "Desk", recognizedText: nil, labels: ["desk"], sharpness: 0.6)
        XCTAssertTrue(PhotoReading.isInformative(scene, caption: scene.caption), "labels without text are enough")

        var blurred = board
        blurred.sharpness = PhotoReading.minimumSharpness / 2
        XCTAssertFalse(PhotoReading.isInformative(blurred, caption: blurred.caption), "readable text doesn't save a blurred photo")
        var copy = board
        copy.duplicateOf = 0
        XCTAssertFalse(PhotoReading.isInformative(copy, caption: copy.caption), "nor a near copy")
        let blank = ImageDescription(caption: nil, recognizedText: "  \n", labels: [], sharpness: 0.9)
        XCTAssertFalse(PhotoReading.isInformative(blank, caption: blank.caption), "whitespace isn't text")
    }

    func testCaptionsAreTidiedFromWhatModelsWrite() {
        XCTAssertEqual(PhotoReading.visionCaption(labels: ["whiteboard", "text"], text: "Launch plan\nBudget"), "Whiteboard · “Launch plan”")
        XCTAssertEqual(PhotoReading.visionCaption(labels: [], text: "Hi"), nil)
        XCTAssertEqual(PhotoReading.cleanCaption("Caption: \"a whiteboard listing the Q3 launch plan.\"\nMore"), "A whiteboard listing the Q3 launch plan.")
        XCTAssertEqual(PhotoReading.cleanCaption("<think>hmm</think>The photo shows a slide about hiring."), "A slide about hiring.")
        XCTAssertNil(PhotoReading.cleanCaption("   "))
    }

    func testTheRuntimeReadsPhotosWithoutInstallingAnyModels() async throws {
        let image = try file(whiteboard(["LAUNCH PLAN", "BUDGET REVIEW"]), "runtime.jpg")
        let runtime = LocalIntelligenceRuntime(modelsDirectory: folder.appendingPathComponent("Models"))
        let results = try await runtime.describeImages([ImageDescriptionRequest(url: image)], model: PhotoReading.visionModel)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].provenance?.family, "apple-vision")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Models").path), "nothing installed")
    }

    func testTheRuntimeReadsAPhotosTextThroughVision() async throws {
        try XCTSkipUnless(VisionImageReader.canRecognizeText, "Text recognition can't run on this machine (some virtual machines).")
        let image = try file(whiteboard(["LAUNCH PLAN", "BUDGET REVIEW"]), "runtime.jpg")
        let runtime = LocalIntelligenceRuntime(modelsDirectory: folder.appendingPathComponent("Models"))
        let results = try await runtime.describeImages([ImageDescriptionRequest(url: image)], model: PhotoReading.visionModel)
        XCTAssertTrue(results.first?.recognizedText?.contains("LAUNCH PLAN") == true, "\(results)")
    }

    func testTheCatalogDeclaresThePhotoRoleAndItsEngines() throws {
        let catalog = ModelCatalog.builtIn
        let vision = try XCTUnwrap(catalog.model("apple-vision/system"))
        XCTAssertTrue(vision.isSystemModel)
        XCTAssertEqual(vision.capabilities.imageInput, true)
        XCTAssertTrue(vision.availability(engines: ModelEngineRegistry.standard.descriptors).isAvailable)
        let gemma = try XCTUnwrap(catalog.model("gemma-4/e2b-4bit"))
        XCTAssertTrue(gemma.serves(.imageDescription) && gemma.serves(.summarization), "one install describes photos and writes summaries")
        XCTAssertEqual(gemma.capabilities.imageInput, true)
        XCTAssertFalse(try XCTUnwrap(catalog.model("gemma-4/12b-4bit")).serves(.imageDescription))
        XCTAssertEqual(Set(catalog.models(for: .imageDescription).map(\.key)), ["apple-vision/system", "gemma-4/e2b-4bit", "gemma-4/e4b-4bit"])
        XCTAssertEqual(ModelRecommendations.initialSelections(catalog: catalog)[.imageDescription], "apple-vision/system")
        for quality in ModelQuality.allCases {
            XCTAssertEqual(ModelRecommendations.preset(quality, tier: .standard, catalog: catalog).model(for: .imageDescription), "apple-vision/system")
        }
    }

    // MARK: The engine's photo step

    private final class Scripted: MeetingInference, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        private var _requests: [[ImageDescriptionRequest]] = []
        var calls: [String] { lock.withLock { _calls } }
        var requests: [[ImageDescriptionRequest]] { lock.withLock { _requests } }
        var vision: [ImageDescription] = []
        var captionFails = false
        var summary = MeetingSummary(overview: "Plan")
        private var _photos: [PhotoEvidence] = []
        var photos: [PhotoEvidence] { lock.withLock { _photos } }

        func transcribe(url: URL, model: ModelReference, glossary: [String], progress: @escaping IntelligenceProgressHandler) async throws -> RecognitionResult {
            RecognitionResult(segments: [], language: "en", duration: 0)
        }
        func diarize(url: URL, model: ModelReference, options: SpeakerAnalysisOptions, progress: @escaping IntelligenceProgressHandler) async throws -> SpeakerAnalysis {
            SpeakerAnalysis(turns: [], embeddings: [:])
        }
        func summarize(transcript: String, notes: String, template: MeetingKind, glossary: [String], model: ModelReference,
                       templateInstructions: String?, highlightEvidence: String?, progress: @escaping IntelligenceProgressHandler) async throws -> GeneratedMeetingNotes {
            lock.withLock { _calls.append("summarize without photos") }
            return GeneratedMeetingNotes(summary: summary, suggestedTerms: [], rawResponse: "{}", warnings: [])
        }
        func summarize(transcript: String, notes: String, template: MeetingKind, glossary: [String], model: ModelReference,
                       templateInstructions: String?, highlightEvidence: String?, photos: [PhotoEvidence],
                       progress: @escaping IntelligenceProgressHandler) async throws -> GeneratedMeetingNotes {
            lock.withLock { _calls.append("summarize \(photos.map(\.label).joined(separator: ","))"); _photos = photos }
            return GeneratedMeetingNotes(summary: summary, suggestedTerms: [], rawResponse: "{}", warnings: [])
        }
        func describeImages(_ requests: [ImageDescriptionRequest], model: ModelReference,
                            progress: @escaping IntelligenceProgressHandler) async throws -> [ImageDescription] {
            lock.withLock { _calls.append("describe \(model.id) \(requests.count)"); _requests.append(requests) }
            if model.id == PhotoReading.visionModel.id {
                return vision.map { var copy = $0; copy.provenance = ModelProvenance(family: "apple-vision", variant: "system", revision: "system",
                                                                                      engine: "appleVision", engineVersion: "1 (Vision)"); return copy }
            }
            struct Failure: LocalizedError { var errorDescription: String? { "Not enough memory" } }
            if captionFails { throw Failure() }
            return requests.map { ImageDescription(caption: "A whiteboard: \($0.recognizedText ?? "")",
                                                   provenance: ModelProvenance(family: "gemma-4", variant: "e2b-4bit", revision: "2387675",
                                                                               engine: "mlxLanguage", engineVersion: "3")) }
        }
    }

    private func configuration(photoModel: ModelReference?) -> InferenceProcessingEngine.Configuration {
        InferenceProcessingEngine.Configuration(transcriptionModel: "parakeet/ultra", summaryModel: "gemma-4/e2b-4bit", detectSpeakers: false,
                                                speakerModel: "community-1/offline", speakerOptions: SpeakerAnalysisOptions(), fingerprint: "f",
                                                speakerMatchThreshold: 0.8, speakerMatchMargin: 0.05, photoModel: photoModel)
    }

    private func photo(_ seconds: TimeInterval, analysis: PhotoAnalysis? = nil) -> MeetingPhoto {
        MeetingPhoto(relativePath: "Originals/Photos/\(UUID().uuidString).jpg", fileName: "p.jpg", sha256: "",
                     capturedAt: Date(timeIntervalSince1970: 1_800_000_000 + seconds), time: seconds, analysis: analysis)
    }

    func testVisionReadsEveryPhotoAndTheChosenModelCaptionsOnlyInformativeOnes() async throws {
        let inference = Scripted()
        inference.vision = [
            ImageDescription(caption: "Whiteboard · “Launch”", recognizedText: "Launch plan", labels: ["whiteboard"], sharpness: 0.8),
            ImageDescription(caption: "Whiteboard · “Launch”", recognizedText: "Launch plan", labels: ["whiteboard"], sharpness: 0.8, duplicateOf: 0),
            ImageDescription(caption: nil, recognizedText: nil, labels: [], sharpness: 0.05),
            ImageDescription()
        ]
        let read = photo(400, analysis: PhotoAnalysis(caption: "Old", isInformative: true,
                                                      settings: ProcessingSettings(modelID: "gemma-4/e2b-4bit")))
        let photos = [photo(10), photo(12), photo(30), read]
        var meeting = Meeting(title: "Planning")
        meeting.photos = photos
        let inputs = photos.map { PhotoProcessingInput(photo: $0, url: folder.appendingPathComponent($0.relativePath)) }
        let engine = InferenceProcessingEngine(inference: inference, configuration: configuration(photoModel: "gemma-4/e2b-4bit"))
        let output = try await engine.describePhotos(meeting, photos: inputs, progress: { _ in })

        XCTAssertEqual(inference.calls, ["describe apple-vision/system 4", "describe gemma-4/e2b-4bit 1"])
        XCTAssertEqual(inference.requests[0].map(\.compareOnly), [false, false, false, true], "a photo read before is only compared")
        XCTAssertEqual(inference.requests[1].first?.recognizedText, "Launch plan", "the caption model gets Vision's text as context")
        XCTAssertEqual(Set(output.analyses.keys), Set(photos.prefix(3).map(\.id)))
        let first = try XCTUnwrap(output.analyses[photos[0].id])
        XCTAssertEqual(first.caption, "A whiteboard: Launch plan")
        XCTAssertEqual(first.recognizedText, "Launch plan")
        XCTAssertTrue(first.isInformative)
        XCTAssertEqual(first.settings?.modelID, "gemma-4/e2b-4bit")
        XCTAssertEqual(first.settings?.parameters["textModel"], "apple-vision/system")
        XCTAssertEqual(first.settings?.model?.family, "gemma-4", "provenance names the caption model")
        let copy = try XCTUnwrap(output.analyses[photos[1].id])
        XCTAssertEqual(copy.duplicateOf, photos[0].id)
        XCTAssertFalse(copy.isInformative)
        XCTAssertEqual(copy.settings?.modelID, "apple-vision/system", "a skipped photo keeps the provenance of the engine that read it")
        var duplicate = photos[1]
        duplicate.analysis = copy
        XCTAssertFalse(InferenceProcessingEngine.needsReading(duplicate, captionModel: "gemma-4/e2b-4bit"))
        var captioned = photos[0]
        captioned.analysis = first
        XCTAssertFalse(InferenceProcessingEngine.needsReading(captioned, captionModel: "gemma-4/e2b-4bit@2387675"))
        XCTAssertTrue(InferenceProcessingEngine.needsReading(captioned, captionModel: "gemma-4/e2b-4bit@new-revision"))
        XCTAssertFalse(try XCTUnwrap(output.analyses[photos[2].id]).isInformative, "blurred")
    }

    func testACaptionModelThatCantRunLeavesVisionsCaptionsWithANotice() async throws {
        let inference = Scripted()
        inference.captionFails = true
        inference.vision = [ImageDescription(caption: "Document · “Agenda”", recognizedText: "Agenda", labels: ["document"], sharpness: 0.7)]
        var meeting = Meeting(title: "Planning")
        let only = photo(5)
        meeting.photos = [only]
        let engine = InferenceProcessingEngine(inference: inference, configuration: configuration(photoModel: "gemma-4/e4b-4bit"))
        let output = try await engine.describePhotos(meeting, photos: [PhotoProcessingInput(photo: only, url: folder)], progress: { _ in })
        XCTAssertEqual(output.analyses[only.id]?.caption, "Document · “Agenda”")
        XCTAssertEqual(output.analyses[only.id]?.settings?.modelID, "apple-vision/system")
        XCTAssertEqual(output.notices, ["Photo captions use Apple Vision: Not enough memory"])
        // With Vision chosen (or nothing), only Vision runs, and a photo it captioned isn't read again.
        let visionOnly = Scripted()
        visionOnly.vision = inference.vision
        let done = try await InferenceProcessingEngine(inference: visionOnly, configuration: configuration(photoModel: nil))
            .describePhotos(meeting, photos: [PhotoProcessingInput(photo: only, url: folder)], progress: { _ in })
        XCTAssertEqual(visionOnly.calls, ["describe apple-vision/system 1"])
        var analysed = only
        analysed.analysis = done.analyses[only.id]
        XCTAssertFalse(InferenceProcessingEngine.needsReading(analysed, captionModel: nil))
        XCTAssertTrue(InferenceProcessingEngine.needsReading(analysed, captionModel: "gemma-4/e2b-4bit"), "a new caption model reads it again")
    }

    func testOneUnreadablePhotoIsAFailureOfItsOwnAndTheOthersAreRead() async throws {
        let inference = Scripted()
        inference.vision = [ImageDescription(caption: "Slide", recognizedText: "Q3", labels: ["slide"], sharpness: 0.7),
                            ImageDescription(failure: "The file isn’t an image.")]
        var meeting = Meeting(title: "Planning")
        let photos = [photo(5), photo(9)]
        meeting.photos = photos
        let engine = InferenceProcessingEngine(inference: inference, configuration: configuration(photoModel: nil))
        let output = try await engine.describePhotos(meeting, photos: photos.map { PhotoProcessingInput(photo: $0, url: folder) }, progress: { _ in })
        XCTAssertEqual(Set(output.analyses.keys), [photos[0].id])
        XCTAssertEqual(output.failures, [photos[1].id: "The file isn’t an image."])
        XCTAssertEqual(output.notices, ["A photo couldn’t be read: The file isn’t an image."])

        // Vision unable to run at all: every photo waiting is a failure, to be tried later.
        struct Unavailable: LocalizedError { var errorDescription: String? { "Vision is unavailable" } }
        final class Broken: MeetingInference, @unchecked Sendable {
            func transcribe(url: URL, model: ModelReference, glossary: [String], progress: @escaping IntelligenceProgressHandler) async throws -> RecognitionResult { throw Unavailable() }
            func diarize(url: URL, model: ModelReference, options: SpeakerAnalysisOptions, progress: @escaping IntelligenceProgressHandler) async throws -> SpeakerAnalysis { throw Unavailable() }
            func summarize(transcript: String, notes: String, template: MeetingKind, glossary: [String], model: ModelReference,
                           templateInstructions: String?, highlightEvidence: String?, progress: @escaping IntelligenceProgressHandler) async throws -> GeneratedMeetingNotes { throw Unavailable() }
            func describeImages(_ requests: [ImageDescriptionRequest], model: ModelReference,
                                progress: @escaping IntelligenceProgressHandler) async throws -> [ImageDescription] { throw Unavailable() }
        }
        let none = try await InferenceProcessingEngine(inference: Broken(), configuration: configuration(photoModel: nil))
            .describePhotos(meeting, photos: photos.map { PhotoProcessingInput(photo: $0, url: folder) }, progress: { _ in })
        XCTAssertEqual(Set(none.failures.keys), Set(photos.map(\.id)))
        XCTAssertTrue(none.analyses.isEmpty)
    }

    func testACaptionModelThatFailedIsntTriedAgainForThosePhotosUntilItChanges() async throws {
        let inference = Scripted()
        inference.captionFails = true
        inference.vision = [ImageDescription(caption: "Document · “Agenda”", recognizedText: "Agenda", labels: ["document"], sharpness: 0.7)]
        var meeting = Meeting(title: "Planning")
        var only = photo(5)
        meeting.photos = [only]
        let model = ModelReference("gemma-4/e4b-4bit", revision: "abc")
        let output = try await InferenceProcessingEngine(inference: inference, configuration: configuration(photoModel: model))
            .describePhotos(meeting, photos: [PhotoProcessingInput(photo: only, url: folder)], progress: { _ in })
        only.analysis = output.analyses[only.id]
        XCTAssertEqual(only.analysis?.settings?.parameters["captionFailed"], "gemma-4/e4b-4bit@abc")
        XCTAssertFalse(InferenceProcessingEngine.needsReading(only, captionModel: model), "Not at every pass")
        XCTAssertTrue(InferenceProcessingEngine.needsReading(only, captionModel: ModelReference("gemma-4/e4b-4bit", revision: "newer")))
        XCTAssertTrue(InferenceProcessingEngine.needsReading(only, captionModel: "gemma-4/e2b-4bit"))
    }

    func testAppleVisionReadsTheRestOfABatchAroundAnUnreadableFile() async throws {
        let good = try file(whiteboard(["LAUNCH PLAN"]), "good.jpg")
        let broken = folder.appendingPathComponent("broken.jpg")
        try Data("not an image at all".utf8).write(to: broken)
        let reader = try await AppleVisionEngine().load(ModelInstallation(receipt: ModelInstallReceipt(
            model: try XCTUnwrap(ModelCatalog.builtIn.model("apple-vision/system")), revision: ModelRevisionEntry(id: "system", artifacts: []),
            installedAt: Date()), directory: folder), role: .imageDescription, progress: { _ in })
        let describer = try XCTUnwrap(reader as? any DescribingImages)
        let results = try await describer.describe([broken, good].map { ImageDescriptionRequest(url: $0) }, progress: { _ in })
        XCTAssertEqual(results.count, 2)
        XCTAssertNotNil(results[0].failure)
        XCTAssertNil(results[1].failure)
        XCTAssertNotNil(results[1].sharpness)
    }

    func testTheSummaryGetsTheCandidatesAndKeepsOnlyValidPlacementsWithTheTimeFallback() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let mic = RecordingTrack(source: .microphone, relativePath: "Originals/a.m4a", fileName: "a.m4a", duration: 600, offset: 0,
                                 sha256: String(repeating: "a", count: 64), startedAt: start)
        var meeting = Meeting(title: "Planning", date: start, tracks: [mic])
        meeting.unifiedTranscript = [
            TranscriptSegment(trackID: mic.id, start: 0, end: 60, text: "The launch budget needs another review of marketing spend."),
            TranscriptSegment(trackID: mic.id, start: 300, end: 360, text: "Hiring two designers and a recruiter before summer.")
        ]
        let budget = photo(30, analysis: PhotoAnalysis(caption: "Whiteboard", recognizedText: "Budget review marketing spend", isInformative: true))
        let hiring = photo(320, analysis: PhotoAnalysis(caption: "Whiteboard", recognizedText: "Hiring: designers, recruiter", isInformative: true))
        let blurry = photo(40, analysis: PhotoAnalysis(sharpness: 0.02, isInformative: false))
        meeting.photos = [budget, hiring, blurry]
        let inference = Scripted()
        inference.summary = MeetingSummary(overview: "Budget and hiring.", sections: [
            SummarySection(heading: "Budget", body: "Marketing spend needs review.", photoIDs: [budget.id, blurry.id]),
            SummarySection(heading: "Hiring", body: "Two designers and a recruiter.")
        ])
        let engine = InferenceProcessingEngine(inference: inference, configuration: configuration(photoModel: nil))
        let output = try await engine.summarize(meeting, template: nil, vocabulary: [], progress: { _ in })
        XCTAssertEqual(inference.calls.last, "summarize P1,P2", "the blurred photo isn't offered")
        XCTAssertEqual(inference.photos.map(\.id), [budget.id, hiring.id])
        XCTAssertEqual(output.summary.sections[0].photoIDs, [budget.id])
        XCTAssertEqual(output.summary.sections[1].photoIDs, [hiring.id], "placed by when it was taken")
        XCTAssertEqual(output.summary.processingSettings?.parameters["photos"], "2")
    }

    // MARK: The summary schema

    private final class ScriptedModel: SynthesisModel, @unchecked Sendable {
        let supportsStructuredOutput = true
        var reply: (String, String?) -> String
        private let lock = NSLock()
        private var _prompts: [String] = [], _schemas: [String] = []
        var prompts: [String] { lock.withLock { _prompts } }
        var schemas: [String] { lock.withLock { _schemas } }
        init(reply: @escaping (String, String?) -> String) { self.reply = reply }
        func encode(_ text: String) async -> [Int] { text.split(whereSeparator: \.isWhitespace).indices.map { $0 } }
        func decode(_ tokens: [Int]) async -> String { tokens.map { _ in "word" }.joined(separator: " ") }
        func respond(instructions: String, prompt: String, maxTokens: Int) async throws -> String {
            lock.withLock { _prompts.append(prompt) }
            return reply(prompt, nil)
        }
        func respond(instructions: String, prompt: String, schema: String, maxTokens: Int) async throws -> String {
            lock.withLock { _prompts.append(prompt); _schemas.append(schema) }
            return reply(prompt, schema)
        }
    }

    func testTheSchemaLimitsSectionPhotosToTheLabelsGivenAndParsingDropsAnyOther() async throws {
        let schema = MeetingSynthesis.summarySchema(template: .auto, photoLabels: ["P1", "P2"])
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any])
        let section = try XCTUnwrap((((object["properties"] as? [String: Any])?["sections"] as? [String: Any])?["items"]) as? [String: Any])
        XCTAssertEqual(section["required"] as? [String], ["heading", "body", "photos"])
        let photos = try XCTUnwrap((section["properties"] as? [String: Any])?["photos"] as? [String: Any])
        XCTAssertEqual((photos["items"] as? [String: Any])?["enum"] as? [String], ["P1", "P2"])
        XCTAssertFalse(MeetingSynthesis.summarySchema(template: .auto).contains("photos"), "without photos the schema is as before")

        let first = PhotoEvidence(id: UUID(), label: "P1", time: 30, caption: "Whiteboard", text: "Budget")
        let second = PhotoEvidence(id: UUID(), label: "P2", time: 320, caption: "Slide")
        let summary = #"{"kind":"general","title":"Plan","overview":"Budget and hiring.","sections":[{"heading":"Budget","body":"Review.","photos":["P1","p1","P9"]},{"heading":"Hiring","body":"Designers.","photos":[]}],"actionItems":[],"terms":[]}"#
        let model = ScriptedModel { prompt, schema in
            schema?.contains("\"sections\"") == true ? summary : #"{"actions":[]}"#
        }
        let notes = try await MeetingSynthesis.generate(model: model, modelID: "gemma-4/e2b-4bit",
                                                        transcript: "[00:30] Alex: Review the budget.\n[05:20] Sam: Hire designers.",
                                                        notes: "", template: .auto, glossary: [], photos: [first, second], progress: { _ in })
        XCTAssertEqual(notes.summary.sections[0].photoIDs, [first.id], "a repeated label counts once; an unknown one is dropped")
        XCTAssertNil(notes.summary.sections[1].photoIDs)
        let final = try XCTUnwrap(model.prompts.first { $0.contains("Write a concise summary") })
        XCTAssertTrue(final.contains("[P1]; taken at 00:30; shows: Whiteboard; text in the photo: Budget"))
        XCTAssertTrue(final.contains(#""photos":["P1"]"#))
        XCTAssertTrue(model.schemas.first?.contains(#""enum":["P1","P2"]"#) == true)

        // Without photos, the prompt says nothing about them.
        let plain = MeetingSynthesis.finalPrompt(evidence: "{}", template: .auto, glossary: [])
        XCTAssertFalse(plain.contains("photo"))
    }
}
