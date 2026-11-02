@testable import DaybookCore
import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookKit

/// Settings › Storage's figures come from the library's files, so they're right without sync: audio wherever it is,
/// downloads told apart only where sync tracks them, everything else as conversations, and models as given.
final class LibraryStorageReportTests: XCTestCase {
    private func write(_ bytes: Int, to path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
    }

    func testBehaviorAudioIsCountedFromTheLibraryWithoutSync() throws {
        let root = makeTemporaryFolder("StorageReport")
        let meeting = UUID()
        try write(40_000, to: "Meetings/\(meeting.uuidString)/Audio/microphone.m4a", in: root)
        try write(10_000, to: "Meetings/\(meeting.uuidString)/Audio/call.wav", in: root)
        try write(2_000, to: "Meetings/\(meeting.uuidString)/meeting.json", in: root)
        try write(500, to: "Meetings/\(meeting.uuidString)/Photos/board.heic", in: root)
        // A recording in the Trash, and one still being filed, are on the device too.
        try write(5_000, to: "Trash/\(UUID().uuidString)/Audio/old.m4a", in: root)
        try write(3_000, to: "Staging/\(UUID().uuidString)/recording.caf", in: root)
        try write(1_000, to: "Sync/audio-cache.json", in: root)

        let report = LibraryStorageReport.measure(libraryRoot: root, models: 2_000_000)
        XCTAssertEqual(report.audio, 58_000, "every audio file, wherever it is")
        XCTAssertNil(report.downloadedAudio, "without sync, downloads aren't told apart")
        XCTAssertNil(report.recordedAudio)
        XCTAssertEqual(report.conversations, 3_500, "the rest the library keeps")
        XCTAssertEqual(report.models, 2_000_000)
        XCTAssertEqual(report.library, 61_500)
        XCTAssertEqual(report.total, 2_061_500)
        XCTAssertEqual(StorageWords.audioSummary(bytes: report.audio, here: "this iPhone"), "\(ByteSize.format(58_000)) of audio")
        XCTAssertNil(StorageWords.audioBreakdown(report, here: "this iPhone"))
    }

    func testBehaviorModelsKeptInTheLibraryFolderCountOnce() throws {
        // The Mac keeps its models in the library folder ("Models"), and measures them on their own.
        let root = makeTemporaryFolder("StorageReport")
        let meeting = UUID()
        try write(40_000, to: "Meetings/\(meeting.uuidString)/Audio/microphone.m4a", in: root)
        try write(2_000, to: "Meetings/\(meeting.uuidString)/meeting.json", in: root)
        try write(900_000, to: "Models/whisper/model.safetensors", in: root)
        try write(100, to: "Models/UserModels.json", in: root)
        try write(8_000, to: "Models/whisper/sample.wav", in: root)

        let report = LibraryStorageReport.measure(libraryRoot: root, models: 908_100,
                                                  excluding: [root.appendingPathComponent("Models", isDirectory: true)])
        XCTAssertEqual(report.audio, 40_000, "a model's own audio isn't a recording")
        XCTAssertEqual(report.conversations, 2_000, "the models aren't the conversations")
        XCTAssertEqual(report.models, 908_100)
        XCTAssertEqual(report.total, 950_100, "the models count once")

        let counted = LibraryStorageReport.measure(libraryRoot: root)
        XCTAssertEqual(counted.audio + counted.conversations, 950_100, "without leaving them out, they'd count again")
    }

    func testBehaviorDownloadsAreToldApartWhereSyncTracksThem() throws {
        let root = makeTemporaryFolder("StorageReport")
        let meeting = UUID()
        try write(30_000, to: "Meetings/\(meeting.uuidString)/Audio/fetched.m4a", in: root)
        try write(20_000, to: "Meetings/\(meeting.uuidString)/Audio/recorded.m4a", in: root)
        let cached = [
            CachedAudio(meetingID: meeting, trackID: UUID(), relativePath: "Audio/fetched.m4a", sha256: "a", bytes: 30_000, origin: .fetched,
                        addedAt: Date(), lastPlayedAt: nil),
            CachedAudio(meetingID: meeting, trackID: UUID(), relativePath: "Audio/recorded.m4a", sha256: "b", bytes: 20_000, origin: .recordedHere,
                        addedAt: Date(), lastPlayedAt: nil),
        ]
        let keys = LibraryStorageReport.downloadedKeys(cached)
        XCTAssertEqual(keys, [LibraryStorageReport.key(meetingID: meeting, relativePath: "Audio/fetched.m4a")])
        let report = LibraryStorageReport.measure(libraryRoot: root, downloaded: keys)
        XCTAssertEqual(report.audio, 50_000)
        XCTAssertEqual(report.downloadedAudio, 30_000)
        XCTAssertEqual(report.recordedAudio, 20_000)
        XCTAssertEqual(StorageWords.audioBreakdown(report, here: "this iPhone"),
                       "\(ByteSize.format(30_000)) downloaded · \(ByteSize.format(20_000)) recorded on this iPhone")
        XCTAssertEqual(report.with(models: 1_000).total, 51_000)
    }

    func testBehaviorTheWordsSayWhatTheAudioIs() {
        XCTAssertEqual(StorageWords.audioSummary(bytes: 0, here: "this iPhone"), "No audio on this iPhone")
        XCTAssertEqual(StorageWords.audioSummary(bytes: 1_200_000_000, here: "this Mac"), "1.2 GB of audio")
        XCTAssertNil(StorageWords.audioBreakdown(LibraryStorageReport(audio: 0, downloadedAudio: 0), here: "this iPhone"), "nothing to say")
        XCTAssertEqual(StorageWords.audioBreakdown(LibraryStorageReport(audio: 400_000, downloadedAudio: 0), here: "this iPhone"),
                       "Recorded on this iPhone")
        XCTAssertEqual(StorageWords.audioBreakdown(LibraryStorageReport(audio: 400_000, downloadedAudio: 400_000), here: "this iPhone"),
                       "Downloaded for playback")
        XCTAssertEqual(StorageWords.audioBreakdown(LibraryStorageReport(audio: 100, downloadedAudio: 200), here: "this iPhone"),
                       "Downloaded for playback", "never more downloaded than there is")
        XCTAssertEqual(StorageWords.section(device: "iPhone"), "On This iPhone")
    }

    func testBehaviorAnEmptyOrMissingLibraryMeasuresNothing() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("NoSuchLibrary-\(UUID().uuidString)")
        XCTAssertEqual(LibraryStorageReport.measure(libraryRoot: missing, downloaded: []), LibraryStorageReport(downloadedAudio: 0))
        XCTAssertEqual(LibraryStorageReport.measure(libraryRoot: makeTemporaryFolder("StorageReport")).total, 0)
    }
}
