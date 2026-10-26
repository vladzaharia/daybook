import DaybookCore
@testable import DaybookKit
import DaybookIntelligence
import Foundation
import XCTest
@testable import Daybook

/// One unreadable photo doesn't make every sync pass read photos again (and load the photo models):
/// it waits, the others are read, and it's tried again once its wait is over.
@MainActor
final class PhotoReadingTests: XCTestCase {
    private final class Reader: MeetingInference, @unchecked Sendable {
        private let lock = NSLock()
        private var _batches: [Int] = []
        var batches: [Int] { lock.withLock { _batches } }
        let unreadable: Set<String>
        init(unreadable: Set<String>) { self.unreadable = unreadable }
        func transcribe(url: URL, model: ModelReference, glossary: [String], progress: @escaping IntelligenceProgressHandler) async throws -> RecognitionResult {
            RecognitionResult(segments: [], language: "en", duration: 0)
        }
        func diarize(url: URL, model: ModelReference, options: SpeakerAnalysisOptions, progress: @escaping IntelligenceProgressHandler) async throws -> SpeakerAnalysis {
            SpeakerAnalysis(turns: [], embeddings: [:])
        }
        func summarize(transcript: String, notes: String, template: MeetingKind, glossary: [String], model: ModelReference,
                       templateInstructions: String?, highlightEvidence: String?, progress: @escaping IntelligenceProgressHandler) async throws -> GeneratedMeetingNotes {
            GeneratedMeetingNotes(summary: MeetingSummary(overview: ""), suggestedTerms: [], rawResponse: "", warnings: [])
        }
        func describeImages(_ requests: [ImageDescriptionRequest], model: ModelReference,
                            progress: @escaping IntelligenceProgressHandler) async throws -> [ImageDescription] {
            lock.withLock { _batches.append(requests.filter { !$0.compareOnly }.count) }
            return requests.map { request in
                unreadable.contains(request.url.lastPathComponent)
                    ? ImageDescription(failure: "Unreadable") : ImageDescription(caption: "Whiteboard", recognizedText: "Plan", sharpness: 0.8)
            }
        }
    }

    func testAnUnreadablePhotoWaitsWhileTheOthersAreRead() async throws {
        let rig = try await MultiSourceRig.make()
        addTeardownBlock { await rig.tearDown() }
        let id = rig.state.newMeeting(title: "Photos")
        let bytes = try XCTUnwrap(PhotoDemo.jpeg(PhotoDemo.board(["LAUNCH PLAN"])))
        let other = try XCTUnwrap(PhotoDemo.jpeg(PhotoDemo.board(["HIRING"])))
        await rig.state.library.acquireLock()
        let good = try await rig.state.library.addPhoto(data: bytes, to: id)
        let bad = try await rig.state.library.addPhoto(data: other, to: id)
        rig.state.library.releaseLock()
        let reader = Reader(unreadable: [URL(fileURLWithPath: bad.relativePath).lastPathComponent])
        rig.state.sources.inference = reader

        rig.state.readPhotosWhenIdle(id)
        try await rig.waitUntil("the first reading") { !reader.batches.isEmpty && rig.state.readingPhotoID == nil }
        XCTAssertNotNil(rig.meeting(id)?.photo(good.id)?.analysis)
        XCTAssertNil(rig.meeting(id)?.photo(bad.id)?.analysis)
        XCTAssertEqual(rig.state.photoBackoff.failure(bad.id)?.attempts, 1)

        // Sync passes (and the page opening) ask again: nothing is read while the photo waits.
        for _ in 0..<3 { rig.state.requeueUnreadPhotos(); rig.state.readPhotosWhenIdle(id) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reader.batches, [2])

        // Once its wait is over, it's tried again on its own.
        rig.state.photoBackoff.failed(bad.id, reason: "Unreadable", at: Date(timeIntervalSinceNow: -100_000))
        rig.state.requeueUnreadPhotos()
        try await rig.waitUntil("the retry") { reader.batches.count == 2 && rig.state.readingPhotoID == nil }
        XCTAssertEqual(reader.batches, [2, 1], "Only the failed photo is read again")
    }
}
