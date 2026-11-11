#if DEBUG
import DaybookCore
import DaybookIntelligence
import DaybookKit
import DaybookTestSupport
import Foundation
import XCTest
@testable import Daybook

/// One status overview, both apps (docs/interface.md, "Status overview"): ReadingDemo's library, filled as each app
/// fills it, read through each app's gatherer (the Mac's `StatusOverviewInputs.make`; what the iPhone's
/// `StatusSheetInputs.make` reads from its library, `StatusOverviewModel.queue` and `localWork`), with the same
/// devices beside it, reads with the same lines on either app: the recorder, the other Daybook, this device's own
/// work, and iCloud, each device naming itself.
@MainActor
final class StatusOverviewParityTests: XCTestCase {
    private let soundcore: RecorderFacts = {
        var recorder = RecorderFacts(id: "sc", name: "Soundcore Work", shortName: "Soundcore", symbol: "recordingtape", isDirect: true,
                                     state: .connected, isLinked: true)
        recorder.batteryLevel = 80
        return recorder
    }()

    func testBehaviorReadingDemosStatesReadAlikeGatheredOnEitherApp() async throws {
        let now = Date()

        // The Mac: its gatherer, over the demo's library with this Mac's own work on top, as `LibraryDemo` puts it.
        let state = AppState(libraryURL: makeTemporaryFolder("DaybookOverviewParityMac"), defaults: makeTestDefaults("local.daybook.tests.parity"))
        await state.initialize()
        await ReadingDemo.seed(state.library, as: .mac, now: now) { _, _, _, _ in }?.value
        let roadmap = try XCTUnwrap(state.meetings.first { $0.title == ReadingDemo.Title.transcribing })
        state.update(roadmap.id) { $0.status = .transcribing }
        state.processor.queue.runningID = roadmap.id
        state.processor.queue.activity.set(IntelligenceProgress(0.4, "Transcribing", stage: .transcribing))
        var mac = StatusOverviewInputs.make(state, meeting: nil, afterStop: false, inputDevice: nil)
        // The devices beside it: a recorder, the iPhone it's paired with, and iCloud paused (the words the gatherer
        // gives a sync problem).
        mac.recording.recorders = [soundcore]
        mac.recording.peers = [RecordingStatusInputs.Peer(id: "ph", name: "Alex’s iPhone", kind: .iPhone, isConnected: true)]
        mac.syncTone = .attention
        mac.syncLine = "Not syncing"

        // The iPhone: what its gatherer reads from the same demo, filled as the iPhone fills it, with its own work on
        // top (the processor's queue running the same conversation).
        let library = LibraryController(rootURL: makeTemporaryFolder("DaybookOverviewParityPhone"), sync: nil)
        try await library.load()
        await ReadingDemo.seed(library, as: .iPhone, now: now) { _, _, _, _ in }?.value
        let words = DeviceWords.iPhone(id: library.thisDevice.id)
        let running = try XCTUnwrap(library.meetings.first { $0.title == ReadingDemo.Title.transcribing })
        var phone = StatusOverviewInputs(words: words)
        phone.queue = StatusOverviewModel.queue(meetings: library.meetings, liveProgress: [:], words: words, now: now)
        let work = StatusOverviewModel.localWork(meetings: library.meetings, local: { _ in ProcessingStatus.LocalQueue(running: running.id, fraction: 0.4) },
                                                 pause: nil, words: words, now: now)
        phone.local = work.line
        phone.localQueue = work.entries
        phone.recording.recorders = [soundcore]
        phone.mac = .connected(name: "Studio Mac")
        phone.syncTone = .attention
        phone.syncLine = "Signed out"

        let macLines = StatusOverviewModel.lines(mac, now: now)
        let phoneLines = StatusOverviewModel.lines(phone, now: now)
        func roles(_ lines: [StatusLineWords], here: String, other: String) -> [String] {
            lines.map { $0.title == here ? "this device" : $0.title == other ? "the other Daybook" : $0.title }
        }
        XCTAssertEqual(roles(macLines, here: "This Mac", other: "Alex’s iPhone"),
                       ["Soundcore Work", "the other Daybook", "this device", "iCloud"], macLines.map(\.title).description)
        XCTAssertEqual(roles(phoneLines, here: "This iPhone", other: "Studio Mac"), roles(macLines, here: "This Mac", other: "Alex’s iPhone"),
                       phoneLines.map(\.title).description)
        // The same words for the same things.
        XCTAssertEqual(macLines.first, phoneLines.first, "a recorder reads alike")
        XCTAssertEqual(macLines.last?.tone, .attention)
        XCTAssertEqual(phoneLines.last?.tone, .attention)
        let macWork = try XCTUnwrap(macLines.first { $0.title == "This Mac" })
        let phoneWork = try XCTUnwrap(phoneLines.first { $0.title == "This iPhone" })
        XCTAssertTrue(macWork.text.hasPrefix("Transcribing · 40%"), macWork.text)
        XCTAssertTrue(phoneWork.text.hasPrefix("Transcribing · 40%"), phoneWork.text)
        XCTAssertEqual(macWork.progress, phoneWork.progress)
        // The demo's work on Studio Mac is what the iPhone says of that Mac; a Mac's home names only its iPhones.
        XCTAssertEqual(phoneLines[1].text, "Transcribing · 55%")
        state.processor.queue.runningID = nil
        await state.flush()
    }
}
#endif
