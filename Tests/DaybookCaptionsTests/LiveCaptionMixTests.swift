import DaybookCaptions
import XCTest

/// Every source's captions of one recording as one list: other devices' lines moved onto this
/// recording's timeline, labelled with their source, and the room heard twice shown once.
final class LiveCaptionMixTests: XCTestCase {
    private func line(_ text: String, _ start: TimeInterval, _ end: TimeInterval, source: LiveCaptionSource? = nil,
                      tentative: Bool = false) -> LiveCaptionSegment {
        LiveCaptionSegment(start: start, end: end, text: text, isTentative: tentative, source: source)
    }

    func testAnotherDevicesLinesJoinOnThisRecordingsTimeline() {
        let own = [line("Can we start?", 1, 2, source: .microphone), line("The launch is on the fourteenth.", 8, 10, source: .call)]
        // The recorder began ten seconds before this Mac: its 15 s is this recording's 5 s.
        let recorder = DeviceCaptionFeed(source: .device("soundcore"), name: "Soundcore", offset: -10, segments: [
            line("Before this Mac started recording.", 2, 6),
            line("Priya owns the checklist.", 15, 17),
        ])
        let mixed = LiveCaptionMix.adding([recorder], to: own)
        XCTAssertEqual(mixed.map(\.text), ["Can we start?", "Priya owns the checklist.", "The launch is on the fourteenth."])
        XCTAssertEqual(mixed[1].start, 5, accuracy: 0.001)
        XCTAssertEqual(mixed[1].source, .device("soundcore"))
        XCTAssertTrue(mixed[1].source?.isDevice == true)
        XCTAssertFalse(LiveCaptionSource.microphone.isDevice)
    }

    func testTheRoomHeardTwiceReadsOnce() {
        let own = [line("So the launch moves to the fourteenth, and Priya owns the checklist.", 10, 14, source: .microphone)]
        // The phone in the same room, its clock a second off and its recognizer a little different.
        let phone = DeviceCaptionFeed(source: .device("phone"), name: "iPhone", offset: 1, segments: [
            line("so the launch moves to the 14th and priya owns the check list", 9.5, 13.5),
            line("Sorry, could you repeat that?", 20, 21.5),
        ])
        let mixed = LiveCaptionMix.adding([phone], to: own)
        XCTAssertEqual(mixed.map(\.text), ["So the launch moves to the fourteenth, and Priya owns the checklist.", "Sorry, could you repeat that?"],
                       "only what this device didn't hear is added")
        // Too far apart in time to be the same words.
        let late = DeviceCaptionFeed(source: .device("phone"), name: "iPhone", offset: 30, segments: phone.segments)
        XCTAssertEqual(LiveCaptionMix.adding([late], to: own).count, 3)
    }

    func testAPhonesChangesUpdateItsLinesInPlace() {
        var feed = DeviceCaptionFeed(source: .device("phone"), name: "iPhone", offset: 0)
        let first = line("We still need", 3, 4, tentative: true)
        feed.update([first, line("Hello.", 1, 2)])
        var revised = first
        revised.text = "We still need legal to sign off."
        revised.isTentative = false
        feed.update([revised])
        XCTAssertEqual(feed.segments.map(\.text), ["Hello.", "We still need legal to sign off."])
        XCTAssertEqual(feed.segments.map(\.isTentative), [false, false])
    }

    func testTheNamesOfOtherDevicesAreKeptWithSavedCaptions() throws {
        let captions = LiveCaptions(meetingID: UUID(), localeIdentifier: "en_US", segments: [line("Hi", 0, 1, source: .device("soundcore"))],
                                    sourceNames: [LiveCaptionSource.device("soundcore").rawValue: "Soundcore"])
        let decoded = try JSONDecoder().decode(LiveCaptions.self, from: JSONEncoder().encode(captions))
        XCTAssertEqual(decoded, captions)
        // Captions saved before other devices joined decode without names.
        let older = Data(#"{"meetingID":"\#(UUID().uuidString)","localeIdentifier":"en_US","segments":[],"createdAt":0,"updatedAt":0}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(LiveCaptions.self, from: older).sourceNames)
    }

    func testAnHoursCaptionsMixQuickly() {
        let own = (0..<1_200).map { line("Line \($0) from this Mac about the plan", Double($0) * 3, Double($0) * 3 + 2.5, source: .microphone) }
        let other = DeviceCaptionFeed(source: .device("phone"), name: "iPhone", offset: 0.4,
                                      segments: (0..<1_200).map { line("Line \($0) from this Mac about the plan", Double($0) * 3, Double($0) * 3 + 2.5) })
        measure { XCTAssertEqual(LiveCaptionMix.adding([other], to: own).count, 1_200) }
    }
}
