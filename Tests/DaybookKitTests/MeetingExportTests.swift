import DaybookCore
import DaybookDevices
import XCTest
@testable import DaybookKit

/// The Markdown export names recordings by where they came from, never by the names their files
/// arrived with, which can say more than the person meant to share.
final class MeetingExportTests: XCTestCase {
    func testUnalignedSourcesAndTheirBookmarksAreNamedByWhereTheyCameFrom() throws {
        let interview = RecordingTrack(source: .imported, relativePath: "Originals/a.m4a", fileName: "Dana — salary talk.m4a")
        let memo = RecordingTrack(source: .imported, relativePath: "Originals/b.m4a", fileName: "Voice memo 0412.m4a")
        let phone = RecordingTrack(source: .microphone, relativePath: "Originals/c.m4a", fileName: "Recording-7F3A.m4a",
                                   device: DeviceRecordingIdentity(kind: DaybookPhoneIntegration.id, serial: "phone", recordingID: "7F3A"))
        let soundcore = RecordingTrack(source: .soundcore, relativePath: "Originals/d.wav", fileName: "Soundcore-1780000000-ab12cd34.wav")
        let tracks = [interview, memo, phone, soundcore]
        let meeting = Meeting(title: "Planning", tracks: tracks,
                              transcripts: tracks.map { TrackTranscript(trackID: $0.id, segments: [TranscriptSegment(trackID: $0.id, start: 1, end: 2, text: "Hello")]) },
                              alignmentReports: tracks.map { TrackAlignment(trackID: $0.id, method: .unaligned, explanation: "No shared speech.") },
                              highlights: [Highlight(trackID: interview.id, time: 1, text: "Ask about the offer")])

        let markdown = MeetingExport.markdown(meeting)

        let headings = markdown.split(separator: "\n").filter { $0.hasPrefix("## Unaligned source: ") }
        XCTAssertEqual(headings, ["## Unaligned source: Imported recording 1", "## Unaligned source: Imported recording 2",
                                  "## Unaligned source: iPhone", "## Unaligned source: Soundcore Work"])
        XCTAssertTrue(markdown.contains("], Imported recording 1, unaligned source-local timeline"), markdown)
        for track in tracks {
            XCTAssertFalse(markdown.contains(track.fileName), "\(track.fileName) in\n\(markdown)")
            XCTAssertFalse(markdown.contains((track.fileName as NSString).deletingPathExtension), markdown)
        }
    }

    /// The files both apps hand the share sheet are named after the conversation, a recording of several after which
    /// it is, and wait in a folder of their own that clearing takes away without touching anything else.
    @MainActor
    func testBehaviorSharedFilesAreNamedAfterTheConversationAndClearedAfterwards() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let microphone = RecordingTrack(source: .microphone, relativePath: "Originals/m.m4a", fileName: "Recording-7F3A.m4a")
        let soundcore = RecordingTrack(source: .soundcore, relativePath: "Originals/s.wav", fileName: "Soundcore-1780000000.wav")
        let one = Meeting(title: "Weekly sync: Q4/plan", tracks: [microphone])
        let two = Meeting(title: "Weekly sync", tracks: [microphone, soundcore])

        XCTAssertEqual(ExportFiles.audioName(one, track: microphone, fileExtension: "m4a"), "Weekly sync- Q4-plan.m4a")
        XCTAssertEqual(ExportFiles.audioName(two, track: soundcore, fileExtension: "wav"), "Weekly sync (Soundcore Work).wav")
        XCTAssertEqual(ExportFiles.audioName(one, track: microphone, fileExtension: ""), "Weekly sync- Q4-plan.m4a", "a file without one is m4a")

        let original = directory.appendingPathComponent("original.wav")
        try Data("audio".utf8).write(to: original)
        let audio = try ExportFiles.audio(original, meeting: two, track: soundcore, in: directory)
        XCTAssertEqual(audio.lastPathComponent, "Weekly sync (Soundcore Work).wav")
        let json = try ExportFiles.json(two, in: directory)
        XCTAssertEqual(json.lastPathComponent, "Weekly sync.json")
        XCTAssertEqual(try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: json)).id, two.id, "the full data reads back")
        let markdown = try ExportFiles.markdown(two, in: directory)
        XCTAssertEqual(markdown.lastPathComponent, "Weekly sync.md")

        ExportFiles.clear([audio, original], in: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: json.path), "the conversation's export folder goes whole")
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path), "a file outside the exports is never touched")
    }

    func testBehaviorFullDataIsEveryFieldWithItsKeysInOrder() throws {
        let meeting = Meeting(title: "Planning")
        let text = try XCTUnwrap(String(data: try MeetingExport.json(meeting), encoding: .utf8))
        XCTAssertTrue(text.contains("\n  \""), "pretty-printed, as the Mac's export saves it")
        XCTAssertEqual(try JSONDecoder().decode(Meeting.self, from: MeetingExport.json(meeting)), meeting)
    }

    func testADerivedRecordingSaysHowItWasMade() {
        let microphone = RecordingTrack(source: .microphone, relativePath: "Originals/m.caf", fileName: "microphone.caf")
        let cleaned = RecordingTrack(source: .microphone, relativePath: "Originals/e.caf", fileName: "microphone-echo-cancelled.caf",
                                     derivedFrom: microphone.id, processing: RecordingTrack.echoCancelledProcessing)
        let meeting = Meeting(tracks: [microphone, cleaned])
        XCTAssertEqual(MeetingExport.sourceName(of: microphone, in: meeting), "Microphone")
        XCTAssertEqual(MeetingExport.sourceName(of: cleaned, in: meeting), "Microphone, echo removed")
    }
}
