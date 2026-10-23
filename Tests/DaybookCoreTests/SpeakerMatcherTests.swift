import XCTest
@testable import DaybookCore

final class SpeakerMatcherTests: XCTestCase {
    let oldTrack = UUID(), newTrack = UUID()
    func speaker(_ id: String, _ vector: [Float], track: UUID? = nil, model: String? = "space-v1") -> Speaker {
        Speaker(id: id, name: id, sourceTrackID: track ?? oldTrack, embedding: vector, embeddingModelID: model)
    }
    func testDistinctSourcesMatchOnlyWithinSuppliedMeeting() {
        let existing = speaker("Alice", [1, 0, 0])
        let incoming = speaker("new-1", [0.98, 0.05, 0], track: newTrack)
        let result = SpeakerMatcher.match(incoming: [incoming], in: Meeting(speakers: [existing]))
        XCTAssertEqual(result[0].targetSpeakerID, "Alice")
        XCTAssertEqual(result[0].status, .matched)
        XCTAssertNil(SpeakerMatcher.match(incoming: [incoming], in: Meeting())[0].targetSpeakerID)
    }
    func testSameSourceRequiresExplicitReprocessingOption() {
        let meeting = Meeting(speakers: [speaker("Alice", [1, 0])])
        let incoming = speaker("run2-cluster0", [1, 0])
        XCTAssertEqual(SpeakerMatcher.match(incoming: [incoming], in: meeting)[0].status, .noComparableCandidates)
        XCTAssertEqual(SpeakerMatcher.match(incoming: [incoming], in: meeting, allowSameSource: true)[0].targetSpeakerID, "Alice")
    }
    func testMatchingRequiresKnownSameEmbeddingSpaceAndDimensions() {
        let incoming = speaker("new", [1, 0], track: newTrack)
        for other in [speaker("different-model", [1, 0], model: "space-v2"), speaker("unknown", [1, 0], model: nil), speaker("dimension", [1, 0, 0])] {
            XCTAssertEqual(SpeakerMatcher.match(incoming: [incoming], in: Meeting(speakers: [other]))[0].status, .noComparableCandidates)
        }
        XCTAssertEqual(SpeakerMatcher.match(incoming: [speaker("new", [1, 0], track: newTrack, model: nil)], in: Meeting())[0].status, .invalidEmbedding)
    }
    func testInvalidAndLowSimilarityVectorsNeverMatch() {
        let meeting = Meeting(speakers: [speaker("Alice", [1, 0])])
        for vector: [Float] in [[.nan, 0], [.infinity, 0], [0, 0], []] {
            XCTAssertEqual(SpeakerMatcher.match(incoming: [speaker("new", vector, track: newTrack)], in: meeting)[0].status, .invalidEmbedding)
            XCTAssertNil(SpeakerMatcher.cosineSimilarity(vector, [1, 0]))
        }
        let low = SpeakerMatcher.match(incoming: [speaker("new", [0.1, 1], track: newTrack)], in: meeting)
        XCTAssertEqual(low[0].status, .belowThreshold); XCTAssertNil(low[0].targetSpeakerID)
    }
    func testAmbiguousAlternativesAndCompetingClustersStaySeparate() {
        let incoming = speaker("new", [1, 0], track: newTrack)
        let ambiguous = SpeakerMatcher.match(incoming: [incoming], in: Meeting(speakers: [speaker("Alice", [1, 0]), speaker("Alex", [0.99, 0.01])]))
        XCTAssertEqual(ambiguous[0].status, .ambiguous); XCTAssertNil(ambiguous[0].targetSpeakerID)
        let duplicate = SpeakerMatcher.match(incoming: [incoming, speaker("new2", [0.99, 0.01], track: newTrack)], in: Meeting(speakers: [speaker("Alice", [1, 0])]))
        XCTAssertTrue(duplicate.allSatisfy { $0.status == .conflictingAssignment && $0.targetSpeakerID == nil })
    }
    func testPreviouslyMatchedRepresentativesDoNotCreateFalseAmbiguity() {
        let first = speaker("Alice", [1, 0]), second = speaker("recording2-person", [1, 0], track: UUID())
        let meeting = Meeting(speakers: [first, second], speakerMatches: [SpeakerMatch(sourceSpeakerID: second.id, targetSpeakerID: first.id, status: .matched, reason: "Previously matched")])
        let matches = SpeakerMatcher.match(incoming: [speaker("recording3-person", [1, 0], track: newTrack)], in: meeting)
        XCTAssertEqual(matches[0].targetSpeakerID, "Alice")
        XCTAssertNil(matches[0].runnerUpSimilarity)
    }
    func testInvalidConfigurationCannotSilentlyLoosenMatching() {
        let result = SpeakerMatcher.match(incoming: [speaker("new", [1, 0], track: newTrack)], in: Meeting(speakers: [speaker("Alice", [1, 0])]), configuration: .init(minimumSimilarity: .nan))
        XCTAssertEqual(result[0].status, .invalidConfiguration)
        XCTAssertNil(result[0].targetSpeakerID)
    }
}
