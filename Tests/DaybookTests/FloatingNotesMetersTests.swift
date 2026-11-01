import DaybookLink
import Foundation
import XCTest
@testable import Daybook

/// Floating Notes' meters: one per source, sharing the meter area, sampled from each source's levels
/// (this Mac's monitor, a recorder's live audio, an iPhone's over the link), flat where none arrive.
@MainActor
final class FloatingNotesMetersTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookMeters-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Sharing the area

    func testBehaviorOneSourceTakesTheAreaAndMoreShareIt() {
        let full = MeterStack.full
        XCTAssertEqual(full.rowHeight(1), full.area, "one source takes it all")
        XCTAssertEqual(full.rowHeight(2), 17, "two as You and Call were")
        XCTAssertEqual(full.height(2), full.area)
        XCTAssertEqual(full.height(3), full.area, accuracy: 0.001, "three still fit the area")
        XCTAssertEqual(full.rowHeight(4), full.minimumRow, "four keep the minimum row, the area growing")
        XCTAssertLessThanOrEqual(full.height(4), full.maximumArea)
        XCTAssertLessThan(full.rowHeight(5), full.minimumRow, "past the most the area may take, rows thin")
        XCTAssertEqual(full.height(5), full.maximumArea, accuracy: 0.001)
        XCTAssertEqual(full.rowHeight(20), full.floorRow, "never thinner than the floor")

        let compact = MeterStack.compact
        XCTAssertEqual(compact.rowHeight(2), 10, "two as compact's You and Call were")
        XCTAssertEqual(compact.height(1), compact.area)
        XCTAssertLessThanOrEqual(compact.height(4), compact.maximumArea, "four fit beside the compact clock")
        XCTAssertEqual(compact.height(6), compact.maximumArea, accuracy: 0.001)
        for count in 1...6 {
            let row = compact.rowHeight(count), gap = compact.gap(count)
            XCTAssertLessThanOrEqual(compact.glyphSize(row: row, gap: gap), row + gap, "\(count) rows: glyphs don't overlap")
        }
    }

    // MARK: Sampling

    func testBehaviorEachSourceGetsItsOwnTrailAndOnlyHeardSourcesAreLive() {
        var recorder: Double? = nil
        let levels = PanelLevels()
        let readers = PanelLevels.Readers(microphone: { 0.6 }, call: { nil }, recorder: { _ in recorder }, phone: { _ in nil })
        levels.follow([.microphone, .call, .recorder("sc"), .phone("ph")])
        levels.run(true, readers: readers)
        defer { levels.run(false, readers: readers) }
        levels.sample()
        XCTAssertEqual(levels.trail(.microphone).values.last, 0.6)
        XCTAssertEqual(levels.heard, [.microphone], "a source without levels rests")
        XCTAssertTrue(levels.trail(.phone("ph")).values.allSatisfy { $0 == 0 }, "an iPhone that sends none stays flat")

        // A recorder's audio arrives, then stops: its meter falls flat.
        recorder = 0.4
        levels.sample()
        XCTAssertEqual(levels.heard, [.microphone, .recorder("sc")])
        XCTAssertEqual(levels.trail(.recorder("sc")).values.last, 0.4)
        recorder = nil
        levels.sample()
        XCTAssertEqual(levels.heard, [.microphone])
        XCTAssertEqual(levels.trail(.recorder("sc")).values.last, 0)

        // A source that leaves drops its trail; one that joins starts flat.
        let micTrail = levels.trail(.microphone)
        levels.follow([.microphone, .phone("other")])
        XCTAssertTrue(levels.trail(.microphone) === micTrail, "a source that stays keeps its trail")
        XCTAssertTrue(levels.trail(.phone("other")).values.allSatisfy { $0 == 0 })
        XCTAssertEqual(levels.heard, [.microphone])
    }

    func testBehaviorStoppingFlattensEveryMeter() {
        let levels = PanelLevels()
        let readers = PanelLevels.Readers(microphone: { 0.5 }, call: { 0.5 }, recorder: { _ in 0.5 }, phone: { _ in 0.5 })
        levels.follow([.microphone, .call])
        levels.run(true, readers: readers)
        XCTAssertTrue(levels.isRunning)
        levels.sample()
        levels.run(false, readers: readers)
        XCTAssertFalse(levels.isRunning)
        XCTAssertTrue(levels.heard.isEmpty)
        XCTAssertTrue(levels.trail(.call).values.allSatisfy { $0 == 0 })
    }

    // MARK: An iPhone's levels over the link

    func testBehaviorAnIPhonesLevelsPlayBackAReadingATick() {
        let store = PhoneLevels()
        let phone = UUID(), conversation = UUID(), t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(store.next(phone, conversation: conversation, at: t0), "nothing sent: no level")
        store.receive(LinkLevels(conversationID: conversation, values: [0.2, 0.4, 0.6]), from: phone, at: t0)
        XCTAssertEqual(store.next(phone, conversation: conversation, at: t0), 0.2)
        XCTAssertEqual(store.next(phone, conversation: conversation, at: t0), 0.4)
        XCTAssertEqual(store.next(phone, conversation: conversation, at: t0), 0.6)
        XCTAssertEqual(store.next(phone, conversation: conversation, at: t0) ?? 0, 0.48, accuracy: 0.001, "between messages it fades")
        XCTAssertNil(store.next(phone, conversation: UUID(), at: t0), "only for the recording it was sent for")
        XCTAssertNil(store.next(phone, conversation: conversation, at: t0.addingTimeInterval(PhoneLevels.lifetime)), "an iPhone that stopped sending")

        // A backlog never grows past a second's: the oldest go, so the meter keeps up.
        store.receive(LinkLevels(conversationID: conversation, values: Array(repeating: 0.1, count: 20) + [0.9]), from: phone, at: t0)
        for _ in 0..<(PhoneLevels.backlog - 1) { _ = store.next(phone, conversation: conversation, at: t0) }
        XCTAssertEqual(store.next(phone, conversation: conversation, at: t0), 0.9)
    }

    func testBehaviorTheMacMetersAnIPhoneRecordingTheSameConversation() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let state = AppState(libraryURL: root, defaults: makeTestDefaults("FloatingNotesMetersTests.phone"))
        await state.initialize()
        XCTAssertTrue(AppState.linkIdentity(sync: state.sync, defaults: makeTestDefaults("FloatingNotesMetersTests.identity"))
            .features.contains(LinkCapabilities.liveLevelsFeature), "this Mac tells iPhones it draws their levels")
        let id = UUID(), phone = UUID()
        let readers = PanelLevels.Readers.live(state)
        state.phoneLevelled(LinkLevels(conversationID: id, values: [0.5]), from: phone)
        XCTAssertNil(readers.phone(phone.uuidString), "not recording: nothing kept")

        state.recordingID = id
        state.phoneLevelled(LinkLevels(conversationID: UUID(), values: [0.7]), from: phone)
        XCTAssertNil(readers.phone(phone.uuidString), "another conversation's levels")
        state.phoneLevelled(LinkLevels(conversationID: id, values: [0.3, 0.5]), from: phone)
        XCTAssertEqual(readers.phone(phone.uuidString), 0.3)
        XCTAssertEqual(readers.phone(phone.uuidString), 0.5)
        XCTAssertNil(readers.phone(UUID().uuidString), "another iPhone sent none")
        XCTAssertNil(readers.recorder("missing"), "no such recorder: no level")
        state.recordingID = nil
    }
}
