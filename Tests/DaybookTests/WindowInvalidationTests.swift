import DaybookCore
import DaybookIntelligence
@testable import DaybookKit
import DaybookTestSupport
import Foundation
import XCTest
@testable import Daybook

/// What redraws the window: a view redraws for the `@Observable` properties it reads, and nothing else. Progress
/// reaches the main actor at most ten times a second and redraws only the views that read it, only when its percent or
/// message changes, and only the row being processed reads it; a change to sync, multipoint, or the recorder doesn't
/// reach what reads the library; search and the visible list are worked out once per change of the query, the place,
/// or the library.
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
        let id = state.newMeeting(title: "Roadmap review")
        let other = state.newMeeting(title: "Standup")
        state.processingID = id
        // What the window around a progress line reads: the list, the selection, the place, the queue, and a row
        // that isn't being processed.
        let window = ObservationCount {
            _ = state.visibleMeetings; _ = state.selectedID; _ = state.place; _ = state.processingQueue
            _ = state.meetings.first { $0.id == other }.map { RowStatus(state: state, meeting: $0) }
        }
        let followed = ObservationCount { _ = state.processingProgress }
        let row = ObservationCount { _ = state.meetings.first { $0.id == id }.map { RowStatus(state: state, meeting: $0) } }
        defer { window.cancel(); followed.cancel(); row.cancel() }
        state.processingProgress = IntelligenceProgress(0.101, "Transcribing")
        state.processingProgress = IntelligenceProgress(0.102, "Transcribing")
        XCTAssertEqual(followed.count, 1, "A report that changes neither the percent nor the message redraws nothing")
        XCTAssertEqual(state.processingProgress.fraction, 0.102, "It's kept, for the next redraw and for the claim and iPhones")
        state.processingProgress = IntelligenceProgress(0.11, "Transcribing")
        state.processingProgress = IntelligenceProgress(0.11, "Identifying speakers")
        state.downloadProgress = IntelligenceProgress(0.5, "Downloading")
        XCTAssertEqual(window.count, 0, "Progress reaches only what reads it (a progress line, the row being processed); the window isn't redrawn")
        XCTAssertEqual(followed.count, 3, "A new percent or a new message reaches what draws it")
        XCTAssertEqual(row.count, 3, "The row being processed follows it")
        XCTAssertEqual(state.processingActivity.value.message, "Identifying speakers")
        state.processingID = nil
        await state.flush()
    }

    func testEveryDeliveryReachesTheAppButOnlyVisibleOnesRedraw() async throws {
        let activity = ActivityProgress(IntelligenceProgress(0, "Ready"), interval: 0.01)
        var delivered: [Bool] = []
        activity.onChange = { delivered.append($0) }
        let redraws = ObservationCount { _ = activity.value }
        defer { redraws.cancel() }
        for fraction in [0.2, 0.201, 0.205, 0.21] {
            activity.report(IntelligenceProgress(fraction, "Transcribing"))
            for _ in 0..<100 where activity.value.fraction != fraction { try await Task.sleep(for: .milliseconds(5)) }
        }
        XCTAssertEqual(delivered, [true, false, false, true], "The claim and iPhones hear every delivery; it says which were visible")
        XCTAssertEqual(redraws.count, 2, "Views redraw at 20% and 21%, not in between")
        XCTAssertFalse(ActivityProgress.isVisibleChange(from: IntelligenceProgress(0.999, "Reading"), to: IntelligenceProgress(0.9999, "Reading")))
        XCTAssertTrue(ActivityProgress.isVisibleChange(from: IntelligenceProgress(0.5, "Reading part 1"), to: IntelligenceProgress(0.5, "Reading part 2")))
    }

    func testARowFadesWhenItsWordsChangeNotAtEveryPercent() async throws {
        // A suite of its own in the temporary folder: one named in ~/Library/Preferences outlives the test.
        let state = AppState(libraryURL: makeTemporaryFolder("DaybookWindow"), defaults: makeTestDefaults("local.daybook.tests.window"))
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

    func testAReportThatNamesNoStepKeepsTheStepBefore() async throws {
        let activity = ActivityProgress(IntelligenceProgress(0, "Ready"), interval: 0.01)
        activity.report(IntelligenceProgress(0.5, "Making voice profiles", stage: .identifyingSpeakers))
        for _ in 0..<100 where activity.value.stage == nil { try await Task.sleep(for: .milliseconds(5)) }
        activity.report(IntelligenceProgress(0.6, "Reading photos"))
        for _ in 0..<100 where activity.value.message != "Reading photos" { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(activity.value.stage, .identifyingSpeakers, "reading photos goes on in the step before it")
        XCTAssertTrue(ActivityProgress.isVisibleChange(from: IntelligenceProgress(0.5, "Working", stage: .transcribing),
                                                       to: IntelligenceProgress(0.5, "Working", stage: .identifyingSpeakers)),
                      "the page names the step, so a new one redraws it")
        activity.enter(.summarizing)
        XCTAssertEqual(activity.value.stage, .summarizing)
        XCTAssertEqual(activity.value.fraction, 0.6)
        activity.set(IntelligenceProgress(0, "Starting"))
        XCTAssertNil(activity.value.stage, "a new job has no step until the engine names one")
    }

    func testTheStepIsTheOneTheEngineReportsNeverItsWords() async throws {
        let root = makeTemporaryFolder("DaybookWindow")
        let defaults = makeTestDefaults("local.daybook.tests.window")
        let state = AppState(libraryURL: root, defaults: defaults)
        await state.initialize()
        let id = state.newMeeting(title: "Roadmap review")
        state.update(id) { $0.status = .transcribing }
        state.processingID = id
        func stage() throws -> ProcessingRequest.Stage? {
            guard case .processing(let progress) = state.processingStatus(for: try XCTUnwrap(state.meetings.first { $0.id == id })) else { return nil }
            return progress.stage
        }
        func floating() -> FloatingStatusInputs.Queue.Stage? {
            FloatingStatusInputs.make(state, meeting: nil, afterStop: false, inputDevice: nil).queue.running
        }
        state.processingProgress = IntelligenceProgress(0.6, "Making voice profiles", stage: .identifyingSpeakers)
        XCTAssertEqual(try stage(), .identifyingSpeakers, "voice profiles are part of finding speakers, whatever the words")
        XCTAssertEqual(state.runningStage, .identifyingSpeakers, "and so is the claim")
        XCTAssertEqual(floating(), .identifyingSpeakers, "and Floating Notes")
        state.processingProgress = IntelligenceProgress(0.2, "Loading the speaker-aware transcription model", stage: .transcribing)
        XCTAssertEqual(try stage(), .transcribing, "a word about speakers doesn't make it finding them")
        XCTAssertEqual(floating(), .transcribing)
        // Marked summarizing, it says so at once, before the summary reports.
        state.update(id) { $0.status = .summarizing }
        state.processingActivity.enter(.summarizing)
        XCTAssertEqual(try stage(), .summarizing)
        XCTAssertEqual(floating(), .summarizing)
        state.processingID = nil
        await state.flush()
    }

    func testAViewRedrawsForWhatItReadsAndNothingElse() async throws {
        let root = makeTemporaryFolder("DaybookWindow")
        let defaults = makeTestDefaults("local.daybook.tests.window")
        let state = AppState(libraryURL: root, defaults: defaults)
        await state.initialize()
        // What the list reads through AppState: the library, the place, and the selection.
        let list = ObservationCount { _ = state.visibleMeetings; _ = state.selectedID; _ = state.place }
        let sources = ObservationCount { _ = state.sources.matchesImportedFiles }
        defer { list.cancel(); sources.cancel() }
        // Multipoint sources, like sync, call detection, the recorder, and the iPhone link, redraw the views that
        // read them.
        state.sources.matchesImportedFiles.toggle()
        state.search = "budget"
        XCTAssertEqual(list.count, 0)
        XCTAssertEqual(sources.count, 1)
        state.newMeeting(title: "A change to the library", selecting: false)
        XCTAssertGreaterThan(list.count, 0, "The library is what nearly every view reads")
        await state.flush()
    }

    func testTheVisibleListFollowsTheLibraryEvenWhenItIsAlreadyWorkedOut() async throws {
        let root = makeTemporaryFolder("DaybookWindow")
        let defaults = makeTestDefaults("local.daybook.tests.window")
        let state = AppState(libraryURL: root, defaults: defaults)
        await state.initialize()
        _ = state.visibleMeetings
        // The list is worked out already (the memo answers), and still follows the library.
        let list = ObservationCount { _ = state.visibleMeetings }
        defer { list.cancel() }
        state.newMeeting(title: "Kickoff", selecting: false)
        XCTAssertGreaterThan(list.count, 0)
        XCTAssertEqual(state.visibleMeetings.map(\.title), ["Kickoff"])
        await state.flush()
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
