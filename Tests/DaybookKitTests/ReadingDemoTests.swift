#if DEBUG
import DaybookCore
import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookKit

/// Both apps' demo library is one fixture: the same conversations, in every state, with audio, photos, and saved
/// captions, seeded once into a scratch library.
@MainActor
final class ReadingDemoTests: XCTestCase {
    func testBehaviorTheDemoSeedsEveryStateOnceForEitherApp() async throws {
        let root = makeTemporaryFolder("DaybookReadingDemo")
        let library = LibraryController(rootURL: root, sync: nil)
        try await library.load()
        let now = Date()
        var captions: [(UUID, Int)] = []
        let finishing = ReadingDemo.seed(library, as: .iPhone, now: now) { meetingID, _, locale, lines in
            XCTAssertEqual(locale, "en_US")
            captions.append((meetingID, lines.count))
        }
        XCTAssertNotNil(finishing)
        // The conversations are there at once, for a launch's `--select`.
        func meeting(_ title: String) throws -> Meeting { try XCTUnwrap(library.meetings.first { $0.title == title }, title) }
        XCTAssertEqual(try meeting(ReadingDemo.Title.ready).id, library.meetings.first { $0.title == ReadingDemo.Title.ready }?.id)
        await finishing?.value

        func status(_ title: String) throws -> ProcessingStatus { ProcessingStatus(try meeting(title), now: now) }
        XCTAssertEqual(try status(ReadingDemo.Title.ready), .done)
        XCTAssertEqual(try status(ReadingDemo.Title.transcribing), .recorded)
        XCTAssertEqual(try status(ReadingDemo.Title.transcriptOnly), .transcribed)
        guard case .processing(let elsewhere) = try status(ReadingDemo.Title.elsewhere) else { return XCTFail("transcribing on Studio Mac") }
        XCTAssertEqual(elsewhere.device, ReadingDemo.studio)
        guard case .requested(.device(let waiting)) = try status(ReadingDemo.Title.queued) else { return XCTFail("waiting for a Mac") }
        XCTAssertEqual(waiting.requestedBy, library.thisDevice, "an iPhone's own request")
        guard case .failed(let missing) = try status(ReadingDemo.Title.modelsMissing) else { return XCTFail("couldn't finish") }
        XCTAssertEqual(missing.kind, .modelsMissing)
        guard case .failed(let silent) = try status(ReadingDemo.Title.noSpeech) else { return XCTFail("no speech") }
        XCTAssertTrue(silent.isNoSpeech)
        guard case .failed(let memory) = try status(ReadingDemo.Title.failedSummarizing) else { return XCTFail("couldn't summarize") }
        XCTAssertEqual(memory.kind, .modelCouldNotStart)
        guard case .awaitingRecordings = try status(ReadingDemo.Title.awaiting) else { return XCTFail("waiting for Soundcore audio") }

        // Audio, photos, captions, folders, and the Trash.
        let ready = try meeting(ReadingDemo.Title.ready)
        for track in ready.tracks {
            let url = root.appendingPathComponent("Meetings/\(ready.id.uuidString)").appendingPathComponent(track.relativePath)
            let data = try Data(contentsOf: url)
            XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        }
        XCTAssertEqual(ready.visiblePhotos.count, 2)
        XCTAssertEqual(ready.tags, ["launch", "beta"])
        // Its transcript is Whisper Small's, so a Mac with Parakeet Ultra offers the better one (`--upgrade-demo mac`).
        let mac = ProcessingMac(id: "demo-mac", name: "Vlad's MacBook Pro",
                                capabilities: ProcessingCapabilities(transcribes: true, findsSpeakers: true, summarizes: true,
                                                                     models: ["transcription": "parakeet/ultra"]))
        let offer = Upgrades.offer(for: ready, status: .done, candidates: UpgradeCandidates(
            thisDevice: ProcessingCapabilities(transcribes: false, findsSpeakers: false, summarizes: false), macs: [mac]))
        XCTAssertEqual(offer?.role, .transcription)
        XCTAssertEqual(offer?.line, "Upgrade transcript on Vlad's MacBook Pro")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(
            "Meetings/\(try meeting(ReadingDemo.Title.offline).id.uuidString)/Originals/Microphone.wav").path), "audio not on this device")
        XCTAssertEqual(captions.map(\.0), [try meeting(ReadingDemo.Title.captions).id])
        XCTAssertEqual(captions.first?.1, 3)
        XCTAssertEqual(Set(library.folders.map(\.name)), ["Clients", "Archive"])
        XCTAssertEqual(library.trashedMeetingIDs().count, 1)
        XCTAssertNil(library.meetings.first { $0.title == ReadingDemo.Title.trashed })

        // Once.
        let count = library.meetings.count
        XCTAssertNil(ReadingDemo.seed(library, as: .iPhone) { _, _, _, _ in XCTFail("seeded twice") })
        XCTAssertEqual(library.meetings.count, count)
    }

    func testBehaviorTheDemoGoesOnlyIntoAnEmptyLibraryOrItsOwn() async throws {
        let library = LibraryController(rootURL: makeTemporaryFolder("DaybookReadingDemoGuard"), sync: nil)
        XCTAssertFalse(ReadingDemo.mayFill(library), "not loaded yet")
        try await library.load()
        XCTAssertTrue(ReadingDemo.mayFill(library), "empty")

        // Someone's own conversation, even one in the Trash, keeps the demo out.
        let own = library.newMeeting(title: "Planning")
        XCTAssertFalse(ReadingDemo.mayFill(library))
        let moved = try await library.moveToTrash(own)
        XCTAssertTrue(moved)
        XCTAssertTrue(library.meetings.isEmpty)
        XCTAssertFalse(ReadingDemo.mayFill(library), "the Trash isn't empty")

        // A library the demo filled on an earlier launch may be opened with it again; the seed itself writes nothing.
        let seeded = LibraryController(rootURL: makeTemporaryFolder("DaybookReadingDemoAgain"), sync: nil)
        try await seeded.load()
        await ReadingDemo.seed(seeded, as: .iPhone) { _, _, _, _ in }?.value
        XCTAssertTrue(ReadingDemo.mayFill(seeded))
    }

    func testBehaviorOnAMacTheRequestsAreTheIPhones() async throws {
        let library = LibraryController(rootURL: makeTemporaryFolder("DaybookReadingDemoMac"), sync: nil)
        try await library.load()
        await ReadingDemo.seed(library, as: .mac) { _, _, _, _ in }?.value
        let call = try XCTUnwrap(library.meetings.first { $0.title == ReadingDemo.Title.queued })
        XCTAssertEqual(call.openProcessingRequests.first?.requestedBy, ReadingDemo.phone)
    }

    func testBehaviorTheGeneratedAudioIsAPlayableWAV() throws {
        let url = makeTemporaryFolder("DaybookTone").appendingPathComponent("tone.wav")
        ReadingDemo.tone(seconds: 0.5, to: url)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 44 + 8_000 * 2)
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        XCTAssertNotNil(ReadingDemo.photo(hue: 0.5).flatMap { PhotoFormat.detect($0) })
    }
}
#endif
