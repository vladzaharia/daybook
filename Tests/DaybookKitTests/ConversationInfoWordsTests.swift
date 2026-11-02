import DaybookCore
import DaybookDevices
import Foundation
import XCTest
@testable import DaybookKit

/// What the Mac's inspector and the iPhone's Info say the same way: a recording's glyph, the byline's people, and
/// a typed tag.
@MainActor
final class ConversationInfoWordsTests: XCTestCase {
    func testBehaviorARecordingsGlyphNamesTheDeviceItCameFromOnBothApps() {
        let phone = RecordingTrack(source: .microphone, relativePath: "Originals/p.m4a", fileName: "p.m4a",
                                   device: DeviceRecordingIdentity(kind: DaybookPhoneIntegration.id, serial: "P1", recordingID: "1"))
        XCTAssertEqual(RecordingWords.symbol(phone), "iphone", "an iPhone's microphone is the iPhone, not a microphone")
        let recorder = RecordingTrack(source: .soundcore, relativePath: "Originals/s.wav", fileName: "s.wav",
                                      device: DeviceRecordingIdentity(kind: SoundcoreWorkIntegration.id, serial: "S1", recordingID: "2"))
        XCTAssertEqual(RecordingWords.symbol(recorder), DeviceCatalog.kind(SoundcoreWorkIntegration.id)?.systemImage)
        XCTAssertEqual(RecordingWords.symbol(RecordingTrack(source: .microphone, relativePath: "a", fileName: "a")), "mic")
        XCTAssertEqual(RecordingWords.symbol(RecordingTrack(source: .systemAudio, relativePath: "b", fileName: "b")), "desktopcomputer")
        XCTAssertEqual(RecordingWords.symbol(RecordingTrack(source: .imported, relativePath: "c", fileName: "c")), "doc")
    }

    func testBehaviorTheBylineDoesntNameAVoiceHeardOnlyInBackgroundAudio() {
        let track = UUID()
        var meeting = Meeting(title: "Evening call",
                              unifiedTranscript: [TranscriptSegment(trackID: track, start: 0, end: 30, text: "Hello", speakerID: "alex"),
                                                  TranscriptSegment(trackID: track, start: 30, end: 40, text: "Hi", speakerID: "sam")],
                              speakers: [Speaker(id: "tv", name: "Anchor"), Speaker(id: "alex", name: "Alex"), Speaker(id: "sam", name: "Sam")])
        meeting.backgroundPassages = [TranscriptSegment(trackID: track, start: 40, end: 100, text: "Tonight's news", speakerID: "tv")]
        XCTAssertEqual(meeting.peopleLine, "Alex and Sam")

        // Unnamed people are counted, and the background voice isn't one of them.
        meeting.speakers = [Speaker(id: "tv", name: "Speaker 1"), Speaker(id: "alex", name: "Speaker 2"), Speaker(id: "sam", name: "Speaker 3")]
        XCTAssertEqual(meeting.peopleLine, "2 speakers")
    }

    func testBehaviorATagTypedWithACommaMakesTwoTagsOnBothApps() {
        XCTAssertEqual(TagInput.tags(in: "client, beta"), ["client", "beta"], "the iPhone used to make one tag, \"client  beta\"")
        XCTAssertEqual(TagInput.adding("Beta,  launch   week ,#pricing,,", to: ["beta"]), ["beta", "launch week", "pricing"],
                       "trimmed, one space between words, no leading #, no repeat whatever its case")
        XCTAssertEqual(TagInput.adding("   ", to: ["beta"]), ["beta"])
        var meeting = Meeting(title: "Sync")
        meeting.tags = ["launch"]
        XCTAssertEqual(meeting.tags(adding: "client, beta"), ["launch", "client", "beta"])
        XCTAssertEqual(meeting.tags(removing: "launch"), [])
    }
}
