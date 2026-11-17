import DaybookCore
@testable import DaybookKit
import DaybookTestSupport
import Foundation
import XCTest
@testable import Daybook

/// Merge… on the Mac, end to end with a fake inference engine: two conversations recorded an hour apart, each transcribed,
/// named, and corrected, become one, which is transcribed again through this Mac's queue: every recording again, one
/// transcript in order, the names and corrections the person gave kept, one summary for the whole. Temporary library,
/// synthetic audio; no models, no microphone.
@MainActor
final class MergeProcessingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_780_000_000)

    private func rig() async throws -> MultiSourceRig {
        let rig = try await MultiSourceRig.make(in: self)
        addTeardownBlock { await rig.tearDown() }
        return rig
    }

    func testBehaviorTheMergedConversationIsTranscribedAgainAsOneKeepingNamesAndCorrections() async throws {
        let rig = try await rig()
        let standupAudio = try rig.audio("standup.wav", frequency: 220)
        let planningAudio = try rig.audio("planning.wav", frequency: 330)
        try rig.inference.script(standupAudio, [(0, "Morning everyone"), (10, "The release is on track")])
        try rig.inference.script(planningAudio, [(0, "Welcome to the pricing review"), (10, "We draft the page next")])
        // Dana talks in both, and sounds the same in both.
        try rig.inference.voice(standupAudio, [1, 0, 0])
        try rig.inference.voice(planningAudio, [1, 0, 0])
        let standup = try await rig.macConversation("Standup", at: start, seconds: 0.5, audio: standupAudio)
        let planning = try await rig.macConversation("Planning", at: start.addingTimeInterval(3_600), seconds: 0.5, audio: planningAudio)
        for id in [standup, planning] {
            rig.state.processor.enqueue(id)
            try await rig.processed(id)
        }
        XCTAssertEqual(rig.inference.summarized.count, 2)
        // The person named Dana in each, and corrected a passage of the planning.
        for id in [standup, planning] {
            let speaker = try XCTUnwrap(rig.meeting(id)?.unifiedTranscript.first?.speakerID)
            rig.state.library.renameSpeaker(speaker, to: "Dana", in: id)
        }
        let passage = try XCTUnwrap(rig.meeting(planning)?.unifiedTranscript.first { $0.text.contains("pricing") })
        rig.state.library.correctPassage(passage.id, text: "Welcome to the prices review", in: planning)
        await rig.state.flush()
        let digests = try [standupAudio, planningAudio].map { try AudioDigest.sha256(fileURL: $0) }
        rig.state.sources.alignAudio = { _, _, _, _ in
            XCTFail("recorded an hour apart: never compared by sound")
            return nil
        }

        rig.state.window.selection = [standup, planning]
        rig.state.mergeConversations([planning, standup])
        try await waitUntil("the merged conversation's summary", timeout: 20, state: { "\(rig.inference.summarized.count) summaries" }) {
            rig.inference.summarized.count == 3
        }
        try await rig.processed(standup)

        XCTAssertNil(rig.meeting(planning))
        XCTAssertTrue(rig.state.library.trashedMeetingIDs().contains(planning), "the later one is in the Trash")
        XCTAssertEqual(rig.state.window.openID, standup, "the merged one is on the page")
        XCTAssertTrue(rig.state.window.selection.isEmpty)
        XCTAssertEqual(rig.inference.transcribed.filter { $0 == digests[0] }.count, 2, "every recording transcribed again")
        XCTAssertEqual(rig.inference.transcribed.filter { $0 == digests[1] }.count, 2)
        XCTAssertEqual(rig.inference.summarized.count, 3, "one summary for the whole")

        let merged = try XCTUnwrap(rig.meeting(standup))
        XCTAssertEqual(merged.summary?.overview, "Summary 3")
        XCTAssertEqual(merged.presentTracks.count, 2)
        for track in merged.presentTracks {
            XCTAssertEqual(merged.transcripts.filter { $0.trackID == track.id }.count, 2, "its earlier run beside the new one, to compare")
        }
        XCTAssertEqual(merged.unifiedTranscript.map(\.text),
                       ["Morning everyone", "The release is on track", "Welcome to the prices review", "We draft the page next"],
                       "one transcript, the planning after the standup, the correction kept")
        XCTAssertNil(merged.correctionTransferIssues)
        XCTAssertEqual(Set(merged.unifiedTranscript.compactMap { merged.speakerName($0.speakerID) }), ["Dana"], "Dana, one speaker, by name")
        XCTAssertEqual(Set(merged.unifiedTranscript.compactMap(\.speakerID)).count, 1)
        XCTAssertTrue(merged.revisions.contains { $0.newValue == "Merged “Planning”" })
        let copy = try XCTUnwrap(merged.tracks.first { $0.mergedFrom == planning })
        XCTAssertEqual(copy.alignment?.method, .manual, "placed right after the standup")
        XCTAssertEqual(merged.unifiedTranscript[2].start, merged.clock(of: copy.id)?.offset)
    }

    func testBehaviorTwoRecordingsOfOneConversationAreLinedUpByTheirSoundFromWhereTheClocksPutThem() async throws {
        let rig = try await rig()
        let macAudio = try rig.audio("mac.wav", frequency: 220)
        let otherAudio = try rig.audio("other-mac.wav", frequency: 330)
        try rig.inference.script(macAudio, [(0, "Morning everyone"), (10, "The release is on track")])
        try rig.inference.script(otherAudio, [(5, "Hiring comes after lunch")])
        // The same meeting, recorded on two Macs, the second started 5 s later and filed on its own.
        let first = try await rig.macConversation("Design review", at: start, seconds: 30, audio: macAudio)
        let second = try await rig.macConversation("Design review", at: start.addingTimeInterval(5), seconds: 30, audio: otherAudio)
        let priors = SoundPriors()
        rig.state.sources.alignAudio = { _, _, expected, _ in
            priors.add(expected)
            return AudioAlignment(offset: 5.5, rate: 1, confidence: 0.9)
        }

        rig.state.mergeConversations([first, second])
        try await waitUntil("the merged conversation's summary", timeout: 20) { rig.inference.summarized.count == 1 }
        try await rig.processed(first)

        let merged = try XCTUnwrap(rig.meeting(first))
        XCTAssertNil(rig.meeting(second))
        let copy = try XCTUnwrap(merged.tracks.first { $0.mergedFrom == second })
        XCTAssertEqual(priors.values.first, 5, "where the clocks put it is the sound search's prior")
        XCTAssertEqual(copy.alignment?.method, .audio, "lined up by its sound, as an added recording is")
        XCTAssertEqual(copy.alignment?.offset, 5.5)
        XCTAssertEqual(merged.unifiedTranscript.first { $0.text.contains("Hiring") }?.start ?? 0, 10.5, accuracy: 0.001)
        XCTAssertEqual(rig.inference.summarized.count, 1, "one summary for the whole")
    }
}

/// What the sound search was given as its prior, from the aligner's thread.
private final class SoundPriors: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [TimeInterval?] = []
    func add(_ value: TimeInterval?) { lock.withLock { stored.append(value) } }
    var values: [TimeInterval?] { lock.withLock { stored } }
}
