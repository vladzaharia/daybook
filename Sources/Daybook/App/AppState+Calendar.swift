import DaybookKit
import Foundation

/// Use Calendar (docs/capture.md, "Calendar"): the meeting a call belongs to names its recording and its prompt, and a
/// meeting with other people that starts with no call to announce it (one in a room) asks to be recorded, then asks
/// whether to stop once it's over. Only while When a call starts isn't Off, and only with the person's calendar access;
/// a meeting is always asked about, never recorded on its own.
extension AppState {
    /// The calendar's meeting for a call that has just started, by its call link and then its time.
    func meeting(for call: MeetingCandidate, at now: Date = Date()) -> MeetingEvent? {
        guard usesCalendar, meetingCalendar.access == .allowed else { return nil }
        return CalendarMeetings.current(meetingCalendar.events(from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(3600)),
                                        at: now, callHosts: CalendarMeetings.callHosts(forApp: call.bundleID))
    }

    /// The meeting to ask about now, if any: one with other people starting now, not asked about yet, while nothing is
    /// recording, no call is under way, and the prompt isn't asking something else.
    func meetingToAsk(at now: Date = Date()) -> MeetingEvent? {
        guard usesCalendar, callPolicy != .off, meetingCalendar.access == .allowed, recordingID == nil, !isStartingRecording,
              !monitor.isMeetingActive, CallPromptWindow.shared.question == nil else { return nil }
        return CalendarMeetings.startingNow(meetingCalendar.events(from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(3600)),
                                            at: now, asked: askedMeetings).first
    }

    /// The meeting recorded from its start, once it's over and the recording still goes on: asked about once.
    func meetingToStop(at now: Date = Date()) -> MeetingEvent? {
        guard let calendarMeeting, recordingID == calendarMeeting.recording, now >= calendarMeeting.event.end,
              CallPromptWindow.shared.question == nil else { return nil }
        return calendarMeeting.event
    }

    /// One look at the calendar: a meeting starting asks to be recorded, one recorded from its start that's over asks
    /// whether to stop.
    func checkCalendar(at now: Date = Date()) {
        if let meeting = meetingToAsk(at: now) {
            askToRecord(meeting)
        } else if let meeting = meetingToStop(at: now) {
            // Asked once: the recording is the person's from here.
            calendarMeeting = nil
            askToStop(after: meeting)
        }
    }

    /// Looks at the calendar every 30 seconds while Use Calendar is on and When a call starts isn't Off; never under
    /// XCTest, whose tests call `checkCalendar(at:)` themselves.
    func watchCalendar() {
        calendarWatch?.cancel()
        calendarWatch = nil
        guard usesCalendar, callPolicy != .off, !MacCaptioners.isRunningTests else { return }
        calendarWatch = Task { [weak self] in
            while !Task.isCancelled {
                self?.checkCalendar()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// Turning Use Calendar on asks for access first (the system asks once); without it, it stays off.
    func setUsesCalendar(_ on: Bool) async {
        guard on else { usesCalendar = false; return }
        if meetingCalendar.access != .allowed { _ = await meetingCalendar.requestAccess() }
        usesCalendar = meetingCalendar.access == .allowed
    }
}
