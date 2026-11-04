import DaybookKit
import XCTest
@testable import Daybook

/// A calendar the tests write.
final class FakeMeetingCalendar: MeetingCalendarReading, @unchecked Sendable {
    var access: CalendarAccess
    var meetings: [MeetingEvent]
    var grants: Bool
    private(set) var asked = 0

    init(access: CalendarAccess = .allowed, meetings: [MeetingEvent] = [], grants: Bool = true) {
        self.access = access; self.meetings = meetings; self.grants = grants
    }

    func requestAccess() async -> Bool {
        asked += 1
        access = grants ? .allowed : .denied
        return grants
    }

    func events(from start: Date, to end: Date) -> [MeetingEvent] {
        access == .allowed ? meetings.filter { $0.end > start && $0.start < end } : []
    }
}

/// Use Calendar on the Mac (docs/capture.md, "Calendar"): a call named after its meeting, a meeting with other people
/// asked about as it starts, and the question whether to stop once it's over.
@MainActor
final class CalendarCallTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let zoom = MeetingCandidate(bundleID: "us.zoom.xos", appName: "Zoom", windowTitle: "Zoom Meeting", hasInputActivity: true,
                                        hasOutputActivity: true, hasMeetingWindow: true, isBrowser: false)

    private func state(_ calendar: FakeMeetingCalendar) async -> AppState {
        let root = makeTemporaryFolder("CalendarCallTests")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let state = AppState(libraryURL: root, defaults: makeTestDefaults("CalendarCallTests"))
        await state.initialize()
        state.meetingCalendar = calendar
        return state
    }

    private func meeting(_ title: String, starts minutes: Double, people: Int = 4, host: String? = nil) -> MeetingEvent {
        MeetingEvent(id: title, title: title, start: now.addingTimeInterval(minutes * 60), end: now.addingTimeInterval((minutes + 30) * 60),
                     attendees: people, callHost: host)
    }

    func testBehaviorTurningItOnAsksForTheCalendarAndARefusalLeavesItOff() async {
        let refused = FakeMeetingCalendar(access: .notAsked, grants: false)
        let state = await state(refused)
        await state.setUsesCalendar(true)
        XCTAssertFalse(state.usesCalendar, "no access, no calendar")
        XCTAssertEqual(refused.asked, 1)

        let granted = FakeMeetingCalendar(access: .notAsked)
        state.meetingCalendar = granted
        await state.setUsesCalendar(true)
        XCTAssertTrue(state.usesCalendar)
        await state.setUsesCalendar(false)
        XCTAssertFalse(state.usesCalendar)
    }

    func testBehaviorACallTakesItsMeetingsTitleOnlyWithUseCalendar() async {
        let calendar = FakeMeetingCalendar(meetings: [meeting("Weekly product sync", starts: -1, host: "acme.zoom.us"),
                                                      meeting("Lunch", starts: -5)])
        let state = await state(calendar)
        XCTAssertNil(state.meeting(for: zoom, at: now), "off until the person turns it on")
        state.usesCalendar = true
        XCTAssertEqual(state.meeting(for: zoom, at: now)?.title, "Weekly product sync", "the meeting with Zoom's link")
        calendar.access = .denied
        XCTAssertNil(state.meeting(for: zoom, at: now), "access taken away in System Settings")
    }

    func testBehaviorAMeetingStartingIsAskedAboutOnceWhileNothingElseIsGoingOn() async {
        let calendar = FakeMeetingCalendar(meetings: [meeting("Planning", starts: 0), meeting("Focus", starts: 0, people: 1)])
        let state = await state(calendar)
        state.usesCalendar = true
        XCTAssertEqual(state.meetingToAsk(at: now)?.title, "Planning", "with other people; a block of one's own isn't asked about")
        state.askedMeetings.insert("Planning")
        XCTAssertNil(state.meetingToAsk(at: now), "asked once")
        state.askedMeetings = []
        state.callPolicy = .off
        XCTAssertNil(state.meetingToAsk(at: now), "When a call starts: Off asks about nothing")
        state.callPolicy = .ask
        state.recordingID = UUID()
        XCTAssertNil(state.meetingToAsk(at: now), "nor while something's recording")
        state.recordingID = nil
    }

    func testBehaviorTheMeetingRecordedFromItsStartAsksWhetherToStopOnceOver() async {
        let planning = meeting("Planning", starts: -10)
        let state = await state(FakeMeetingCalendar(meetings: [planning]))
        state.usesCalendar = true
        let recording = UUID()
        state.recordingID = recording
        state.calendarMeeting = (recording, planning)
        XCTAssertNil(state.meetingToStop(at: now), "not before it's over")
        XCTAssertEqual(state.meetingToStop(at: planning.end)?.title, "Planning")
        state.recordingID = UUID()
        XCTAssertNil(state.meetingToStop(at: planning.end), "another recording isn't the meeting's")
        state.recordingID = nil
    }

    func testBehaviorThePromptSaysTheMeeting() {
        let sync = meeting("Weekly product sync", starts: 0)
        XCTAssertEqual(CallPromptQuestion.record(zoom, event: sync).subtitle, "Weekly product sync · 4 people")
        XCTAssertEqual(CallPromptQuestion.record(zoom, event: nil).subtitle, "Zoom Meeting")
        XCTAssertEqual(CallPromptQuestion.meetingStarts(sync).title, "Weekly product sync")
        XCTAssertEqual(CallPromptQuestion.meetingStarts(sync).subtitle, "Starting now · 4 people")
        XCTAssertEqual(CallPromptQuestion.meetingStarts(sync).announcement, "Weekly product sync is starting. Record it?")
        XCTAssertEqual(CallPromptQuestion.meetingEnded(sync).title, "Weekly product sync ended")
        XCTAssertEqual(CallPromptQuestion.meetingEnded(sync).unanswered, .keepRecording)
        XCTAssertNil(CallPromptQuestion.meetingStarts(sync).app, "a meeting shows the calendar's icon")
    }
}
