import AVFoundation
import XCTest
@testable import DaybookCore

/// The rules both apps share for a shared recording's timeline and a conversation's default title, and
/// the one buffer copy every capture path uses.
final class MultipointHelpersTests: XCTestCase {
    private let mac = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testBehaviorTheTimelineZeroIsTheLeadersMovedOntoThisClock() {
        let earlier = mac.addingTimeInterval(-90)
        // The leader said where its timeline began: that, on this clock.
        XCTAssertEqual(MultipointTimeline.zero(timelineStart: earlier, leadStartedAt: mac, clockOffset: 0.25),
                       earlier.addingTimeInterval(-0.25))
        // An older leader said only where its own recording began.
        XCTAssertEqual(MultipointTimeline.zero(timelineStart: nil, leadStartedAt: mac, clockOffset: -1), mac.addingTimeInterval(1))
        // No clock comparison: taken as it was said.
        XCTAssertEqual(MultipointTimeline.zero(timelineStart: earlier, leadStartedAt: nil, clockOffset: nil), earlier)
        XCTAssertNil(MultipointTimeline.zero(timelineStart: nil, leadStartedAt: nil, clockOffset: 3))

        let zero = MultipointTimeline.zero(timelineStart: earlier, leadStartedAt: mac, clockOffset: 0)
        XCTAssertEqual(MultipointTimeline.offset(of: mac.addingTimeInterval(5), from: zero), 95)
        XCTAssertNil(MultipointTimeline.offset(of: mac, from: nil))
    }

    func testBehaviorAConversationsDefaultTitleNamesItsStart() {
        let time = mac.formatted(date: .omitted, time: .shortened)
        XCTAssertEqual(Meeting.defaultTitle(startingAt: mac), "Conversation at \(time)")
        XCTAssertEqual(Meeting.defaultTitle("Soundcore Work", startingAt: mac), "Soundcore Work at \(time)")
    }

    func testBehaviorACopiedBufferHoldsTheSameFramesAndIsItsOwn() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        for channel in 0..<2 {
            for frame in 0..<480 { buffer.floatChannelData![channel][frame] = Float(frame + channel * 1_000) / 10_000 }
        }
        let copy = try XCTUnwrap(buffer.copied())
        XCTAssertEqual(copy.frameLength, 480)
        XCTAssertEqual(copy.format, format)
        XCTAssertEqual(copy.floatChannelData![1][479], buffer.floatChannelData![1][479])
        buffer.floatChannelData![0][0] = 1
        XCTAssertNotEqual(copy.floatChannelData![0][0], 1, "the copy doesn't follow the original")
    }
}
