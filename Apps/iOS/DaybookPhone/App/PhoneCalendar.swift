import DaybookKit
import EventKit
import Foundation

/// Use Calendar on the iPhone (docs/iphone.md, "Calendar"): a recording started here is named after the meeting going
/// on, and a meeting with other people sends a notification as it starts, whose tap or Record opens Daybook recording,
/// named after it. iOS doesn't let an app look at the calendar as each meeting starts, nor notice another app's call,
/// so the reminders are scheduled ahead: the next `reminderLimit` within `reminderHorizon`, again whenever Daybook
/// comes to the front or leaves it, the calendar changes, or iOS gives it a background refresh. Read on this iPhone
/// and never sent anywhere; only a meeting's title is kept, as its conversation's title.
extension PhoneAppModel {
    static let reminderHorizon: TimeInterval = 2 * 24 * 3600
    /// Well under iOS's 64 pending notifications an app may have.
    static let reminderLimit = 20

    /// With Use Calendar, the title of the meeting going on now (or starting within 10 minutes), for a recording
    /// started here.
    func meetingTitle(at now: Date = Date()) -> String? {
        guard settings.usesCalendar, environment.calendar.access == .allowed else { return nil }
        let events = environment.calendar.events(from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(3600))
        return CalendarMeetings.current(events, at: now)?.title
    }

    /// Schedules a notification for each of the next meetings with other people, in place of those scheduled before;
    /// without Use Calendar or access, takes them all away.
    func remindMeetings(at now: Date = Date()) {
        guard settings.usesCalendar, environment.calendar.access == .allowed else { notices.remind([]); return }
        let events = environment.calendar.events(from: now, to: now.addingTimeInterval(Self.reminderHorizon))
        notices.remind(CalendarMeetings.upcoming(events, after: now, limit: Self.reminderLimit).map(PhoneNotices.meetingStarts))
    }

    /// Turning Use Calendar on asks for access first (iOS asks once), then whether Daybook may post its reminders;
    /// without access, it stays off.
    func setUsesCalendar(_ on: Bool) async {
        if on, environment.calendar.access != .allowed { _ = await environment.calendar.requestAccess() }
        settings.usesCalendar = on && environment.calendar.access == .allowed
        if settings.usesCalendar { notices.askPermission() }
        remindMeetings()
    }

    /// A meeting's notification asked to record (`AppDestination.recordMeeting`): it starts once Daybook is in front,
    /// since iOS starts the microphone only there.
    func recordMeetingWhenInFront() {
        guard let title = meetingToRecord, isInFront else { return }
        meetingToRecord = nil
        Task { try? await startRecording(into: nil, title: title, multipoint: nil) }
    }

    /// Reminders follow the calendar while Daybook runs.
    func watchCalendar() {
        guard calendarChanges == nil else { return }
        calendarChanges = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.remindMeetings() }
        }
    }
}
