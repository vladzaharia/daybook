import Combine
import DaybookCore
import DaybookIntelligence
@testable import DaybookKit
import Foundation
import XCTest
@testable import Daybook

/// What redraws the window: progress reaches the main actor at most ten times a second and redraws
/// only the views that follow it; of AppState's parts, only the library and the device list redraw the
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookWindow-\(UUID().uuidString)")
        let suite = "local.daybook.tests.window.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let state = AppState(libraryURL: root, defaults: defaults)
        await state.initialize()
        var redraws = 0, followed = 0
        let counting = state.objectWillChange.sink { redraws += 1 }
        let following = state.processingActivity.objectWillChange.sink { followed += 1 }
        defer { counting.cancel(); following.cancel() }
        state.processingProgress = IntelligenceProgress(0.101, "Transcribing")
        state.processingProgress = IntelligenceProgress(0.102, "Transcribing")
        state.processingProgress = IntelligenceProgress(0.11, "Identifying speakers")
        state.downloadProgress = IntelligenceProgress(0.5, "Downloading")
        XCTAssertEqual(redraws, 0, "Progress views follow the activity (ActivityReader); the window isn't redrawn")
        XCTAssertEqual(followed, 3, "Every delivered report reaches what draws it, so a bar moves smoothly")
        XCTAssertEqual(state.processingActivity.value.message, "Identifying speakers")
    }

    func testOnlyTheLibraryAndTheDeviceListRedrawTheWindow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookWindow-\(UUID().uuidString)")
        let suite = "local.daybook.tests.window.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookWindow-\(UUID().uuidString)")
        let suite = "local.daybook.tests.window.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
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
