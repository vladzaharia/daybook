import DaybookCore
import DaybookDevices
import Foundation
import XCTest
@testable import DaybookKit

/// What both apps say about a conversation's recordings in Audio (`RecordingWords`): the Mac's
/// inspector says "This Mac", the iPhone's Info "Your Mac".
@MainActor
final class RecordingWordsTests: XCTestCase {
    private let mic = RecordingTrack(source: .microphone, relativePath: "Originals/mic.wav", fileName: "mic.wav", offset: 0)

    /// Regression: the iPhone said "Placed when recorded · starts 0:00" under a conversation's only recording.
    func testAnOnlyRecordingSaysWhereItWasMadeAndNothingAboutTiming() {
        var alone = Meeting(title: "Alone", tracks: [mic])
        alone.alignmentReports = [TrackAlignment(trackID: mic.id, method: .provided)]
        XCTAssertEqual(RecordingWords.name(mic, in: alone), "Microphone")
        XCTAssertNil(RecordingWords.timing(mic, in: alone, pending: "Later"))
        XCTAssertEqual(RecordingWords.line(mic, in: alone, mac: "Your Mac", pending: "Later"), "Your Mac")
        XCTAssertEqual(RecordingWords.line(mic, in: alone, mac: "This Mac", pending: "Later"), "This Mac")

        let phone = RecordingTrack(source: .microphone, relativePath: "Originals/phone.m4a", fileName: "phone.m4a", offset: 0,
                                   device: DeviceRecordingIdentity(kind: DaybookPhoneIntegration.id, serial: "P1", recordingID: "1"))
        let fromPhone = Meeting(title: "Walk", tracks: [phone])
        XCTAssertEqual(RecordingWords.name(phone, in: fromPhone), "iPhone")
        XCTAssertEqual(RecordingWords.name(phone, in: fromPhone, phoneName: "Alex’s iPhone"), "Alex’s iPhone")
        XCTAssertNil(RecordingWords.line(phone, in: fromPhone, mac: "Your Mac", pending: "Later"), "Its name says where it was made")
    }

    func testSeveralRecordingsSayHowTheyLineUpWithoutAZeroStartConfidenceOrDrift() {
        let soundcore = RecordingTrack(source: .soundcore, relativePath: "Originals/a.wav", fileName: "REC0042.wav",
                                       device: DeviceRecordingIdentity(kind: SoundcoreWorkIntegration.id, serial: "S1", recordingID: "42"),
                                       alignment: SourceAlignment(method: .audio, offset: 12.4, rate: 1.0002, confidence: 0.93))
        let exported = RecordingTrack(source: .imported, relativePath: "Originals/b.wav", fileName: "Interview.m4a",
                                      device: DeviceRecordingIdentity(kind: OtherRecorderIntegration.id, recordingID: "file:b"),
                                      alignment: SourceAlignment(method: .transcript, offset: 0.3))
        let waiting = RecordingTrack(source: .soundcore, relativePath: "Originals/c.wav", fileName: "REC0043.wav",
                                     alignment: SourceAlignment(method: .pending))
        var several = Meeting(title: "Several", tracks: [mic, soundcore, exported, waiting])
        several.alignmentReports = [TrackAlignment(trackID: mic.id, method: .reference)]

        XCTAssertEqual(RecordingWords.line(mic, in: several, mac: "Your Mac", pending: "Later"), "Your Mac · The main recording")
        XCTAssertEqual(RecordingWords.name(soundcore, in: several), "Soundcore Work")
        XCTAssertEqual(RecordingWords.line(soundcore, in: several, mac: "Your Mac", pending: "Later"), "Lined up by sound · starts 0:12")
        XCTAssertEqual(RecordingWords.name(exported, in: several), "Interview.m4a")
        XCTAssertEqual(RecordingWords.line(exported, in: several, mac: "Your Mac", pending: "Later"), "Other Recorder · Lined up by shared phrases",
                       "A start of 0:00 isn't said")
        XCTAssertEqual(RecordingWords.line(waiting, in: several, mac: "Your Mac", pending: "Lines up when your Mac processes it"),
                       "Lines up when your Mac processes it")

        several.tracks[1].alignment = SourceAlignment(method: .unaligned)
        XCTAssertTrue(RecordingWords.isUnaligned(several.tracks[1], in: several))
        XCTAssertEqual(RecordingWords.timing(several.tracks[1], in: several, pending: "Later"), "Couldn’t line up")
    }

    func testAnEchoRemovedCopyNamesItsOriginalAndDoesntCountAsAnotherRecording() {
        let cleaned = RecordingTrack(source: .microphone, relativePath: "Originals/mic.echo.wav", fileName: "mic.echo.wav", offset: 0,
                                     derivedFrom: mic.id, processing: RecordingTrack.echoCancelledProcessing)
        let meeting = Meeting(title: "Call", tracks: [mic, cleaned])
        XCTAssertEqual(RecordingWords.name(mic, in: meeting), "Microphone, original")
        XCTAssertEqual(RecordingWords.name(cleaned, in: meeting), "Microphone, echo removed")
        XCTAssertNil(RecordingWords.timing(cleaned, in: meeting, pending: "Later"), "One recording and its copy have nothing to line up")
    }
}
