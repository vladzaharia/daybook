import Combine
import DaybookCore
import DaybookIntelligence
@testable import DaybookKit
import Foundation
import XCTest
@testable import Daybook

/// What redraws the window: progress reaches the main actor at most ten times a second and redraws
/// it only when the percent or message changes; search and the visible list are worked out once per
/// change of the query, the place, or the library.
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

    func testTheWindowIsRedrawnOnlyWhenThePercentOrMessageChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookWindow-\(UUID().uuidString)")
        let suite = "local.daybook.tests.window.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let state = AppState(libraryURL: root, defaults: defaults)
        await state.initialize()
        var redraws = 0
        let counting = state.objectWillChange.sink { redraws += 1 }
        defer { counting.cancel() }
        state.processingProgress = IntelligenceProgress(0.101, "Transcribing")
        state.processingProgress = IntelligenceProgress(0.102, "Transcribing")
        state.processingProgress = IntelligenceProgress(0.109, "Transcribing")
        XCTAssertEqual(redraws, 1, "The same whole percent draws nothing new")
        state.processingProgress = IntelligenceProgress(0.11, "Transcribing")
        state.processingProgress = IntelligenceProgress(0.11, "Identifying speakers")
        XCTAssertEqual(redraws, 3)
        XCTAssertEqual(state.processingActivity.value.message, "Identifying speakers")
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
