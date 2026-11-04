import DaybookKit
import XCTest

/// The calendar's meetings (docs/capture.md, "Calendar"): the one a call belongs to, the ones starting now with other
/// people, and the call service a link names.
final class CalendarMeetingsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ id: String, starts minutes: Double, lasts length: Double = 30, people: Int = 4, declined: Bool = false,
                       allDay: Bool = false, host: String? = nil) -> MeetingEvent {
        MeetingEvent(id: id, title: id, start: now.addingTimeInterval(minutes * 60), end: now.addingTimeInterval((minutes + length) * 60),
                     attendees: people, declined: declined, isAllDay: allDay, callHost: host)
    }

    func testBehaviorACallBelongsToItsAppsMeetingThenTheNearestOne() {
        let standup = event("Standup", starts: -2, host: "acme.zoom.us")
        let review = event("Design review", starts: 0, host: "meet.google.com")
        XCTAssertEqual(CalendarMeetings.current([standup, review], at: now, callHosts: ["zoom.us"])?.id, "Standup", "Zoom's link wins")
        XCTAssertEqual(CalendarMeetings.current([standup, review], at: now)?.id, "Design review", "else the one that started closest to now")
        XCTAssertEqual(CalendarMeetings.current([event("Early", starts: 8)], at: now)?.id, "Early", "a call may start up to 10 minutes early")
        XCTAssertNil(CalendarMeetings.current([event("Later", starts: 15)], at: now))
        XCTAssertNil(CalendarMeetings.current([event("Over", starts: -40)], at: now), "one that has ended")
        XCTAssertNil(CalendarMeetings.current([event("Declined", starts: 0, declined: true)], at: now))
        XCTAssertNil(CalendarMeetings.current([event("Holiday", starts: -60, lasts: 1440, allDay: true)], at: now))
    }

    func testBehaviorAMeetingWithOtherPeopleStartingNowIsAskedAboutOnce() {
        let sync = event("Weekly sync", starts: 0)
        XCTAssertEqual(CalendarMeetings.startingNow([sync], at: now, asked: []).map(\.id), ["Weekly sync"])
        XCTAssertTrue(CalendarMeetings.startingNow([sync], at: now, asked: ["Weekly sync"]).isEmpty, "once")
        XCTAssertEqual(CalendarMeetings.startingNow([event("Soon", starts: 0.4)], at: now, asked: []).count, 1, "30 seconds ahead")
        XCTAssertEqual(CalendarMeetings.startingNow([event("Late", starts: -1.5)], at: now, asked: []).count, 1, "up to two minutes late")
        XCTAssertTrue(CalendarMeetings.startingNow([event("Too late", starts: -3)], at: now, asked: []).isEmpty)
        XCTAssertTrue(CalendarMeetings.startingNow([event("Focus time", starts: 0, people: 0)], at: now, asked: []).isEmpty,
                      "a block of one's own isn't a meeting")
        XCTAssertTrue(CalendarMeetings.startingNow([event("Skipping", starts: 0, declined: true)], at: now, asked: []).isEmpty)
        XCTAssertEqual(CalendarMeetings.startingNow([event("B", starts: 0.2), event("A", starts: -1)], at: now, asked: []).map(\.id), ["A", "B"])
        XCTAssertTrue(CalendarMeetings.startingNow([event(" ", starts: 0)], at: now, asked: []).isEmpty, "nothing to call it")
        XCTAssertEqual(sync.peopleLine, "4 people")
        XCTAssertNil(event("Solo", starts: 0, people: 1).peopleLine)
    }

    func testBehaviorTheIPhoneRemindsOfTheNextMeetingsWithOtherPeople() {
        let events = [event("Later", starts: 120), event("Now", starts: 0), event("Soon", starts: 15), event("Solo", starts: 30, people: 1),
                      event("Declined", starts: 45, declined: true), event("Gone", starts: -30), event("Next", starts: 60)]
        XCTAssertEqual(CalendarMeetings.upcoming(events, after: now, limit: 2).map(\.id), ["Soon", "Next"],
                       "after now, with other people, not declined, earliest first, at most the limit")
        XCTAssertEqual(CalendarMeetings.upcoming(events, after: now, limit: 10).map(\.id), ["Soon", "Next", "Later"])
    }

    func testBehaviorTheCallServiceALinkNames() {
        XCTAssertEqual(CalendarMeetings.callHost(in: "Join: https://acme.zoom.us/j/123?pwd=x"), "acme.zoom.us")
        XCTAssertEqual(CalendarMeetings.callHost(in: "Room 4 · https://meet.google.com/abc-defg-hij"), "meet.google.com")
        XCTAssertEqual(CalendarMeetings.callHost(in: "https://example.com/agenda then https://teams.microsoft.com/l/meetup-join/1"),
                       "teams.microsoft.com", "the first link to a call service, not the first link")
        XCTAssertNil(CalendarMeetings.callHost(in: "Conference room B"))
        XCTAssertEqual(CalendarMeetings.callHosts(forApp: "us.zoom.xos"), ["zoom.us"])
        XCTAssertTrue(CalendarMeetings.callHosts(forApp: "com.google.Chrome").contains("meet.google.com"), "a browser's could be any")
    }
}
