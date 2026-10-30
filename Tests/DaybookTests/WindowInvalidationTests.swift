import Combine
import DaybookCore
import DaybookIntelligence
@testable import DaybookKit
import DaybookTestSupport
import Foundation
import XCTest
@testable import Daybook

/// What redraws the window: progress reaches the main actor at most ten times a second and redraws
/// only the views that follow it, and only when its percent or message changes; of AppState's parts, only the library and the device list redraw the
/// window; search and the visible list are worked out once per change of the query, the place, or the
/// library.
@MainActor
final class WindowInvalidationTests: XCTestCase {
    func testProgressFromAnyThreadIsThrottledAndTheLatestWins() async throws {
        let activity = ActivityProgress(IntelligenceProgress(0, "Ready"), interval: 0.05)
        var changes = 0, visible = 0
        activity.onChange = { if $0 { visible += 1 }; changes += 1 }
        let started = Date()
        await Task.detached {
            for step in 1...2_000 { activity.report(IntelligenceProgress(Double(step) / 4_000, "Downloading")) }
        }.value
        for _ in 0..<100 where activity.value.fraction < 0.5 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(activity.value.fraction, 0.5, accuracy: 0.0001, "The last report arrives")
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThanOrEqual(changes, Int(elapsed / 0.05) + 2, "At most one delivery per interval, not one per report")
        XCTAssertLessThanOrEqual(visible, changes)
        // Setting it directly (a job ending) is immediate and drops reports still in flight.
        activity.report(IntelligenceProgress(0.9, "Downloading"))
        activity.set(IntelligenceProgress(0, "Ready"))
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(activity.value.message, "Ready")
    }

    func testProgressRedrawsWhatFollowsItNotTheWindow() async throws {
        let root = makeTemporaryFolder("DaybookWindow")
        let defaults = makeTestDefaults("local.daybook.tests.window")
        let state = AppState(libraryURL: root, defaults: defaults)
        await state.initialize()
        var redraws = 0, followed = 0
        let counting = state.objectWillChange.sink { redraws += 1 }
        let following = state.processingActivity.objectWillChange.sink { followed += 1 }
        defer { counting.cancel(); following.cancel() }
        state.processingProgress = IntelligenceProgress(0.101, "Transcribing")
        state.processingProgress = IntelligenceProgress(0.102, "Transcribing")
        XCTAssertEqual(followed, 1, "A report that changes neither the percent nor the message redraws nothing")
        XCTAssertEqual(state.processingProgress.fraction, 0.102, "It's kept, for the next redraw and for the claim and iPhones")
        state.processingProgress = IntelligenceProgress(0.11, "Transcribing")
        state.processingProgress = IntelligenceProgress(0.11, "Identifying speakers")
        state.downloadProgress = IntelligenceProgress(0.5, "Downloading")
        XCTAssertEqual(redraws, 0, "Progress views follow the activity (ActivityReader); the window isn't redrawn")
        XCTAssertEqual(followed, 3, "A new percent or a new message reaches what draws it")
        XCTAssertEqual(state.processingActivity.value.message, "Identifying speakers")
    }

    func testEveryDeliveryReachesTheAppButOnlyVisibleOnesRedraw() async throws {
        let activity = ActivityProgress(IntelligenceProgress(0, "Ready"), interval: 0.01)
        var delivered: [Bool] = [], redraws = 0
        activity.onChange = { delivered.append($0) }
        let following = activity.objectWillChange.sink { redraws += 1 }
        defer { following.cancel() }
        for fraction in [0.2, 0.201, 0.205, 0.21] {
            activity.report(IntelligenceProgress(fraction, "Transcribing"))
            for _ in 0..<100 where activity.value.fraction != fraction { try await Task.sleep(for: .milliseconds(5)) }
        }
        XCTAssertEqual(delivered, [true, false, false, true], "The claim and iPhones hear every delivery; it says which were visible")
        XCTAssertEqual(redraws, 2, "Views redraw at 20% and 21%, not in between")
        XCTAssertFalse(ActivityProgress.isVisibleChange(from: IntelligenceProgress(0.999, "Reading"), to: IntelligenceProgress(0.9999, "Reading")))
        XCTAssertTrue(ActivityProgress.isVisibleChange(from: IntelligenceProgress(0.5, "Reading part 1"), to: IntelligenceProgress(0.5, "Reading part 2")))
    }

    func testARowFadesWhenItsWordsChangeNotAtEveryPercent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookWindow-\(UUID().uuidString)")
        let suite = "local.daybook.tests.window.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let state = AppState(libraryURL: root, defaults: defaults)
        await state.initialize()
        let id = state.newMeeting(title: "Roadmap review")
        state.update(id) { $0.status = .transcribing }
        state.processingID = id
        func row() throws -> RowStatus { RowStatus(state: state, meeting: try XCTUnwrap(state.meetings.first { $0.id == id })) }
        state.processingProgress = IntelligenceProgress(0.37, "Transcribed 340 of 923 seconds")
        let before = try row()
        state.processingProgress = IntelligenceProgress(0.38, "Transcribed 350 of 923 seconds")
        let after = try row()
        XCTAssertEqual([before.text, after.text], ["Transcribing · 37%", "Transcribing · 38%"])
        XCTAssertEqual(before.phrase, "Transcribing")
        XCTAssertEqual(after.phrase, before.phrase, "The line's animation follows its words, so a new percent doesn't fade it")
        state.update(id) { $0.status = .summarizing }
        XCTAssertEqual(try row().phrase, "Summarizing…")
        state.processingID = nil
        await state.flush()
    }

    func testOnlyTheLibraryAndTheDeviceListRedrawTheWindow() async throws {
        let root = makeTemporaryFolder("DaybookWindow")
        let defaults = makeTestDefaults("local.daybook.tests.window")
        let state = AppState(libraryURL: root, defaults: defaults)
        await state.initialize()
        var redraws = 0
        let counting = state.objectWillChange.sink { redraws += 1 }
        defer { counting.cancel() }
        // Multipoint sources, like sync, call detection, the recorder, and the iPhone link, are observed
        // by the views that show them.
        state.sources.matchesImportedFiles.toggle()
        XCTAssertEqual(redraws, 0)
        state.newMeeting(title: "A change to the library")
        XCTAssertGreaterThan(redraws, 0, "The library is what nearly every view reads through AppState")
    }

    func testSearchAndTheVisibleListAreWorkedOutOncePerChange() async throws {
        let root = makeTemporaryFolder("DaybookWindow")
        let defaults = makeTestDefaults("local.daybook.tests.window")
        let state = AppState(libraryURL: root, defaults: defaults)
        await state.initialize()
        let older = state.newMeeting(title: "Launch review", date: Date(timeIntervalSinceNow: -3_600))
        let newer = state.newMeeting(title: "Launch retro", date: Date())
        XCTAssertEqual(state.visibleMeetings.map(\.id), [newer, older])
        state.search = "launch"
        let searches = state.searchMemo.searches
        XCTAssertEqual(state.searchHits.map(\.meetingID), [newer, older], "Equal matches, newest first")
        _ = state.searchHits; _ = state.searchHits
        XCTAssertEqual(state.searchMemo.searches, searches + 1, "Drawing the list twice searches once")
        state.library.rename(older, to: "Budget review")
        XCTAssertEqual(state.searchHits.map(\.meetingID), [newer], "A library change searches again")
        XCTAssertEqual(state.visibleMeetings.map(\.id), [newer, older])
        state.place = .section(.work)
        XCTAssertEqual(state.visibleMeetings, [], "A place change filters again")
        await state.flush()
    }

    func testALargeLibraryIsSearchedOffTheMainActor() async throws {
        let memo = LibrarySearchMemo()
        memo.backgroundThreshold = 1
        var updates = 0
        memo.onUpdate = { updates += 1 }
        var meeting = Meeting(title: "Weekly sync")
        meeting.unifiedTranscript = [TranscriptSegment(trackID: UUID(), start: 0, end: 1, text: "The pricing page ships Friday")]
        let key = LibrarySearchMemo.Key(text: "pricing", tokens: [], scope: .all, revision: 1)
        XCTAssertEqual(memo.hits(for: key, in: [meeting]), [], "The previous results while it searches")
        await memo.settle()
        XCTAssertEqual(updates, 1)
        XCTAssertEqual(memo.hits(for: key, in: [meeting]).map(\.field), [.transcript])
    }
}
