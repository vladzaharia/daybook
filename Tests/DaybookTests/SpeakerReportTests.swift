import DaybookCore
@testable import DaybookKit
import DaybookTestSupport
import Foundation
import XCTest
@testable import Daybook

/// `Daybook --speaker-report <library>`: a dry run over a library on disk that reads it without
/// opening it and leaves every file as it was. Temporary library, synthetic embeddings.
@MainActor
final class SpeakerReportTests: XCTestCase {
    func testTheReportReadsALibraryAndWritesNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookSpeakerReport-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let library = LibraryController(rootURL: root, sync: nil)
        try await library.load()
        let me = SyntheticVoice.person(5)
        for (index, title) in ["one", "two", "three"].enumerated() {
            let id = library.newMeeting(title: title, date: Date().addingTimeInterval(Double(-index) * 86_400))
            library.update(id) { meeting in
                let track = UUID()
                meeting.transcripts = [TrackTranscript(trackID: track, segments: [
                    TranscriptSegment(trackID: track, start: 0, end: 120, text: "Words", speakerID: "\(title):me")])]
                meeting.unifiedTranscript = meeting.transcripts[0].segments
                meeting.speakers = [Speaker(id: "\(title):me", name: "Speaker 1", sourceTrackID: track,
                                            embedding: SyntheticVoice.near(me, similarity: 0.95, seed: UInt64(index + 1)),
                                            embeddingModelID: "test-space")]
                if index == 0 { meeting.renameSpeaker(id: "\(title):me", name: "Vlad") }
            }
        }
        await library.reconcileSpeakerProfiles(options: .init())
        await library.flush()

        let read = SpeakerReport.read(root)
        XCTAssertEqual(read.meetings.count, 3)
        XCTAssertEqual(read.metadata?.activeSpeakerProfiles.map(\.name), ["Vlad"])
        XCTAssertTrue(read.problems.isEmpty)

        let before = try snapshot(root)
        XCTAssertEqual(SpeakerReport.run(arguments: ["Daybook", "--speaker-report", root.path, "--threshold", "0.8"]), 0)
        XCTAssertEqual(try snapshot(root), before, "Nothing in the library changed")
        XCTAssertEqual(SpeakerReport.run(arguments: ["Daybook", "--speaker-report", root.appendingPathComponent("Missing").path]), 1)

        let report = SpeakerProfileReport.make(meetings: read.meetings, metadata: read.metadata ?? LibraryMetadata())
        XCTAssertEqual(report.counts["unknown"]?[.named], 1)
        XCTAssertEqual(report.counts["unknown"]?[.labelled], 2)
        XCTAssertEqual(report.counts["unknown"]?[.unknown] ?? 0, 0)
    }

    /// Every file under `root`, with its size and modification date.
    private func snapshot(_ root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) ?? FileManager.DirectoryEnumerator() {
            let values = try url.resourceValues(forKeys: Set(keys))
            result[url.path] = "\(values.fileSize ?? -1)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values.isDirectory ?? false)"
        }
        return result
    }
}
