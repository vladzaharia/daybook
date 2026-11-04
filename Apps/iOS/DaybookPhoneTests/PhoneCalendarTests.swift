import DaybookKit
import XCTest
@testable import DaybookPhone

/// A calendar the tests write.
final class FakeMeetingCalendar: MeetingCalendarReading, @unchecked Sendable {
    var access: CalendarAccess
    var meetings: [MeetingEvent]
    var grants: Bool

    init(access: CalendarAccess = .allowed, meetings: [MeetingEvent] = [], grants: Bool = true) {
        self.access = access; self.meetings = meetings; self.grants = grants
    }

    func requestAccess() async -> Bool {
        access = grants ? .allowed : .denied
        return grants
    }

    func events(from start: Date, to end: Date) -> [MeetingEvent] {
        access == .allowed ? meetings.filter { $0.end > start && $0.start < end } : []
    }
}

/// Use Calendar on the iPhone (docs/iphone.md, "Calendar"): a recording started here takes its meeting's name, and the
/// next meetings with other people are reminded of as they start, whose notification records. A stand-in calendar
/// and notifications; nothing reaches EventKit or the notification center.
@MainActor
final class PhoneCalendarTests: XCTestCase {
    private func makeModel(_ calendar: FakeMeetingCalendar, rig: RecorderRig? = nil) throws -> PhoneAppModel {
        let rig = rig ?? RecorderRig()
        var environment = try PhoneAppEnvironment.test(self)
        environment.calendar = calendar
        let library = PhoneLibrary(rootURL: try temporaryDirectory("library"), installation: "INSTALL-1")
        return PhoneAppModel(recorder: rig.recorder, library: library, posture: DevicePosture(),
                             options: DebugLaunch(arguments: [], environment: ["XCTestConfigurationFilePath": "1"]),
                             environment: environment)
    }

    private func meeting(_ title: String, in minutes: Double, people: Int = 4) -> MeetingEvent {
        let start = Date().addingTimeInterval(minutes * 60)
        return MeetingEvent(id: title, title: title, start: start, end: start.addingTimeInterval(30 * 60), attendees: people)
    }

    func testBehaviorARecordingStartedHereTakesItsMeetingsNameOnlyWithUseCalendar() async throws {
        let rig = RecorderRig()
        let model = try makeModel(FakeMeetingCalendar(meetings: [meeting("Design review", in: -2)]), rig: rig)
        try await model.startRecording()
        XCTAssertNotEqual(model.recorder.title, "Design review", "off until the person turns it on")
        rig.pump(2)
        try await model.stopRecording()

        model.settings.usesCalendar = true
        try await model.startRecording()
        XCTAssertEqual(model.recorder.title, "Design review")
        rig.pump(2)
        try await model.stopRecording()
    }

    func testBehaviorTurningItOnAsksThenRemindsOfTheNextMeetingsWithOtherPeople() async throws {
        let calendar = FakeMeetingCalendar(access: .notAsked, meetings: [meeting("Planning", in: 90), meeting("Standup", in: 20),
                                                                         meeting("Focus", in: 30, people: 1)])
        let model = try makeModel(calendar)
        var reminded: [PhoneNotices.Notice]?
        var askedToPost = 0
        model.notices = PhoneNotices(post: { _ in }, remove: { _ in }, askPermission: { askedToPost += 1 }, remind: { reminded = $0 })

        model.remindMeetings()
        XCTAssertEqual(reminded?.count, 0, "off: every reminder taken away")

        await model.setUsesCalendar(true)
        XCTAssertTrue(model.settings.usesCalendar)
        XCTAssertEqual(askedToPost, 1, "and asks whether Daybook may post")
        XCTAssertEqual(reminded?.map(\.title), ["Standup", "Planning"], "with other people, earliest first")
        let standup = try XCTUnwrap(reminded?.first)
        XCTAssertEqual(standup.body, "Starting now · 4 people. Tap to record.")
        XCTAssertEqual(standup.destination, .recordMeeting("Standup"))
        XCTAssertEqual(standup.category, PhoneNotices.meetingCategory.identifier)
        XCTAssertEqual(standup.at, calendar.meetings[1].start, "as it starts")

        await model.setUsesCalendar(false)
        XCTAssertEqual(reminded?.count, 0)
    }

    func testBehaviorARefusalLeavesItOffWithNoReminders() async throws {
        let model = try makeModel(FakeMeetingCalendar(access: .notAsked, meetings: [meeting("Standup", in: 20)], grants: false))
        var reminded: [PhoneNotices.Notice]?
        model.notices = PhoneNotices(post: { _ in }, remove: { _ in }, askPermission: {}, remind: { reminded = $0 })
        await model.setUsesCalendar(true)
        XCTAssertFalse(model.settings.usesCalendar)
        XCTAssertEqual(reminded?.count, 0)
    }

    func testBehaviorAMeetingsNotificationCarriesItsTitleToTheRecording() {
        XCTAssertEqual(AppDestination(userInfo: AppDestination.recordMeeting("Weekly product sync").userInfo), .recordMeeting("Weekly product sync"))
        XCTAssertNil(AppDestination(userInfo: ["daybook.place": "record-meeting"]), "no title, nothing to record")
        XCTAssertEqual(PhoneNotices.meetingStartsText(meeting("Solo", in: 0, people: 0)).body, "Starting now. Tap to record.")
        XCTAssertEqual(PhoneNotices.meetingCategory.actions.map(\.title), ["Record"])
    }
}
