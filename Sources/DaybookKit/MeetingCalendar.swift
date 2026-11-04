import EventKit
import Foundation

// Meetings from the calendars on this device (docs/capture.md, "Calendar"): the event a call belongs to names its
// recording, and a meeting with other people asks to be recorded when it starts, so an in-person one no call
// announces is caught too. Read through EventKit on this device and never sent anywhere; only an event's title is
// kept, as a conversation's title, as a typed one would be.

/// A calendar event, as much of it as naming a recording and asking at a meeting's start need.
public struct MeetingEvent: Equatable, Sendable, Identifiable {
    /// The event and when this occurrence starts: a repeating meeting's occurrences share EventKit's identifier.
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    /// The people invited, the person among them; 0 for an event of one's own.
    public var attendees: Int
    /// The person said they won't go.
    public var declined: Bool
    public var isAllDay: Bool
    /// Where its call is, from its URL, location, or notes ("zoom.us", "meet.google.com"), when it says.
    public var callHost: String?

    public init(id: String, title: String, start: Date, end: Date, attendees: Int = 0, declined: Bool = false, isAllDay: Bool = false,
                callHost: String? = nil) {
        self.id = id; self.title = title; self.start = start; self.end = end; self.attendees = attendees
        self.declined = declined; self.isAllDay = isAllDay; self.callHost = callHost
    }

    /// "4 people", for the prompt; nothing for an event of one's own.
    public var peopleLine: String? { attendees >= 2 ? "\(attendees) people" : nil }
}

public enum CalendarMeetings {
    /// How early a call may start and still be its meeting's, and how late a meeting may start and still be asked about.
    public static let earlyCall: TimeInterval = 10 * 60
    public static let lateStart: TimeInterval = 2 * 60
    public static let earlyStart: TimeInterval = 30

    /// The meeting a call that's under way now belongs to: one going on (or starting within 10 minutes), the person
    /// hasn't declined, not all day. One whose call link is the call's app's comes first, then the one that started
    /// closest to now.
    public static func current(_ events: [MeetingEvent], at now: Date, callHosts: [String] = []) -> MeetingEvent? {
        let going = events.filter { !$0.isAllDay && !$0.declined && $0.start.addingTimeInterval(-earlyCall) <= now && now < $0.end }
        let hosts = callHosts.map { $0.lowercased() }
        func matches(_ event: MeetingEvent) -> Bool {
            guard let host = event.callHost?.lowercased() else { return false }
            return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
        }
        return going.min { first, second in
            let a = matches(first), b = matches(second)
            if a != b { return a }
            return abs(first.start.timeIntervalSince(now)) < abs(second.start.timeIntervalSince(now))
        }
    }

    /// Meetings with other people starting now (from 30 seconds ahead to two minutes late) that haven't been asked
    /// about: the person hasn't declined them, and they aren't all day. Earliest first.
    public static func startingNow(_ events: [MeetingEvent], at now: Date, asked: Set<String>) -> [MeetingEvent] {
        events.filter { event in
            !event.isAllDay && !event.declined && event.attendees >= 2 && !asked.contains(event.id)
                && event.start <= now.addingTimeInterval(earlyStart) && now.timeIntervalSince(event.start) <= lateStart && now < event.end
        }
        .sorted { $0.start < $1.start }
    }

    /// The call service a text names: the host of the first link to one ("https://acme.zoom.us/j/123" is "acme.zoom.us").
    public static func callHost(in text: String) -> String? {
        let services = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "gotomeeting.com", "goto.com",
                        "chime.aws", "whereby.com", "meet.jit.si", "facetime.apple.com", "discord.gg", "discord.com"]
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        for match in detector?.matches(in: text, range: range) ?? [] {
            guard let host = match.url?.host?.lowercased() else { continue }
            if services.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return host }
        }
        return nil
    }

    /// The services a detected call's app is on, for matching it to its event.
    public static func callHosts(forApp bundleID: String) -> [String] {
        switch bundleID.lowercased() {
        case "us.zoom.xos": ["zoom.us"]
        case "com.microsoft.teams2", "com.microsoft.teams": ["teams.microsoft.com", "teams.live.com"]
        case "com.cisco.webexmeetingsapp", "com.webex.meetingmanager": ["webex.com"]
        case "com.logmein.gotomeeting": ["gotomeeting.com", "goto.com"]
        case "com.amazon.amazon-chime": ["chime.aws"]
        case "com.apple.facetime": ["facetime.apple.com"]
        case "com.hnc.discord": ["discord.gg", "discord.com"]
        // A browser can be on any of them; its window's title says which, not its app.
        default: ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "webex.com", "whereby.com", "meet.jit.si"]
        }
    }
}

/// What Daybook may do with the calendars here.
public enum CalendarAccess: Equatable, Sendable {
    case allowed, notAsked, denied
}

/// Reads the calendars on this device. Tests stand in their own.
public protocol MeetingCalendarReading: Sendable {
    var access: CalendarAccess { get }
    /// Asks for full access to events (the system asks once); whether it was given.
    func requestAccess() async -> Bool
    /// Events overlapping `start` to `end`, from every calendar here; none without access.
    func events(from start: Date, to end: Date) -> [MeetingEvent]
}

/// The calendars here, through EventKit.
public final class EventKitMeetingCalendar: MeetingCalendarReading, @unchecked Sendable {
    private let store = EKEventStore()

    public init() {}

    public var access: CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .allowed
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    public func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    public func events(from start: Date, to end: Date) -> [MeetingEvent] {
        guard access == .allowed else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map(MeetingEvent.init)
    }
}

extension MeetingEvent {
    init(_ event: EKEvent) {
        let attendees = event.attendees ?? []
        let text = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }.joined(separator: " ")
        self.init(id: "\(event.calendarItemIdentifier)|\(Int(event.startDate.timeIntervalSince1970))",
                  title: event.title ?? "", start: event.startDate, end: event.endDate, attendees: attendees.count,
                  declined: attendees.first(where: \.isCurrentUser)?.participantStatus == .declined,
                  isAllDay: event.isAllDay, callHost: CalendarMeetings.callHost(in: text))
    }
}

/// No calendar: what a device or test without access reads.
public struct NoMeetingCalendar: MeetingCalendarReading {
    public init() {}
    public var access: CalendarAccess { .denied }
    public func requestAccess() async -> Bool { false }
    public func events(from start: Date, to end: Date) -> [MeetingEvent] { [] }
}
