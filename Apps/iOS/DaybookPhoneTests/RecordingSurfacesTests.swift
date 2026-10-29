import XCTest
@testable import DaybookPhone

/// What the widgets, the Control Center control, and the Live Activity show, and until when: a
/// recording the app stops confirming (it crashed, or the system stopped it) turns into "Not
/// confirmed" on its own instead of "Recording" forever; a paused clock is frozen; titles are private
/// on the Lock Screen; the Live Activity's buttons are readable. The state and timeline logic, not pixels.
@MainActor
final class RecordingSurfacesTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func state(_ phase: SharedRecordingState.Phase, asOf: Date?) -> SharedRecordingState {
        var state = SharedRecordingState()
        state.phase = phase
        state.startedAt = now.addingTimeInterval(-723)
        state.pausedElapsed = phase == .paused ? 723 : nil
        state.title = "Design review"
        state.asOf = asOf
        state.lastRecordingTitle = "Standup"
        return state
    }

    // MARK: Widgets and the control

    func testARecordingTheAppStopsConfirmingBecomesNotConfirmed() {
        let recording = state(.recording, asOf: now)
        XCTAssertEqual(recording.display(at: now), .recording(since: now.addingTimeInterval(-723)))
        XCTAssertEqual(recording.display(at: now.addingTimeInterval(149)), .recording(since: now.addingTimeInterval(-723)))
        XCTAssertEqual(recording.display(at: now.addingTimeInterval(150)), .unconfirmed, "two confirmations missed")
        XCTAssertTrue(recording.isConfirmedActive(at: now))
        XCTAssertFalse(recording.isConfirmedActive(at: now.addingTimeInterval(151)), "the control turns off")

        // The widget's timeline changes on its own when the confirmation runs out.
        XCTAssertEqual(recording.timelineDates(from: now), [now, now.addingTimeInterval(150)])
        XCTAssertEqual(recording.timelineDates(from: now.addingTimeInterval(200)), [now.addingTimeInterval(200)])
        XCTAssertEqual(SharedRecordingState().timelineDates(from: now), [now])

        // A state an earlier build wrote while recording has no time: it isn't confirmed.
        XCTAssertEqual(state(.recording, asOf: nil).display(at: now), .unconfirmed)
        XCTAssertEqual(SharedRecordingState().display(at: now), .idle)
    }

    func testAPausedClockIsFrozenAndAPauseOutlastsACall() {
        let paused = state(.paused, asOf: now)
        XCTAssertEqual(paused.display(at: now.addingTimeInterval(3_000)), .paused(elapsed: 723), "the app may sleep through a call")
        XCTAssertEqual(paused.display(at: now.addingTimeInterval(2 * 3_600)), .unconfirmed)
        XCTAssertEqual(SharedRecordingState.inlineLine(.paused(elapsed: 723)), "Paused · 12:03")
        XCTAssertEqual(SharedRecordingState.inlineLine(.unconfirmed), "Not confirmed")
        XCTAssertEqual(SharedRecordingState.inlineLine(.idle), "Daybook ready")
        XCTAssertEqual(SharedRecordingState.headline(.paused(elapsed: 1)), "Paused")
        XCTAssertEqual(SharedRecordingState.headline(.unconfirmed), "Not confirmed")
    }

    func testBookmarksAreCountedInWords() {
        XCTAssertEqual(SharedRecordingState.bookmarks(1), "1 bookmark")
        XCTAssertEqual(SharedRecordingState.bookmarks(2), "2 bookmarks")
        XCTAssertEqual(SharedRecordingState.bookmarks(0), "0 bookmarks")
    }

    func testALaunchClearsWhatAnEarlierRunLeftRecording() throws {
        let left = state(.recording, asOf: now.addingTimeInterval(-30))
        let cleared = left.clearedAtLaunch()
        XCTAssertEqual(cleared.phase, .idle)
        XCTAssertNil(cleared.startedAt)
        XCTAssertNil(cleared.title)
        XCTAssertEqual(cleared.lastRecordingTitle, "Standup", "the last recording stays")
        let idle = SharedRecordingState()
        XCTAssertEqual(idle.clearedAtLaunch(), idle)

        // Through the app group's storage, as the app does at every launch.
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "RecordingSurfacesTests-\(UUID().uuidString)"))
        left.save(to: defaults)
        RecordingActivityController.clearLeftoversAtLaunch(defaults: defaults)
        XCTAssertEqual(SharedRecordingState.load(from: defaults).phase, .idle)
        XCTAssertEqual(SharedRecordingState.load(from: defaults).lastRecordingTitle, "Standup")
    }

    func testAStateFromAnEarlierBuildDecodes() throws {
        let earlier = #"{"phase":"recording","startedAt":800000000,"bookmarkCount":2,"lastRecordingTitle":"Standup"}"#
        let decoded = try JSONDecoder().decode(SharedRecordingState.self, from: Data(earlier.utf8))
        XCTAssertEqual(decoded.phase, .recording)
        XCTAssertNil(decoded.asOf)
        XCTAssertNil(decoded.pausedElapsed)
        XCTAssertEqual(decoded.bookmarkCount, 2)
    }

    func testTheAppConfirmsARecordingOnceAMinute() {
        let publisher = SharedStatePublisher()
        publisher.writes = false
        var recording = state(.recording, asOf: nil)
        publisher.publish(recording, now: now)
        XCTAssertEqual(publisher.published?.asOf, now)
        XCTAssertFalse(publisher.isDue(now: now.addingTimeInterval(59)))
        publisher.publish(recording, now: now.addingTimeInterval(30))
        XCTAssertEqual(publisher.published?.asOf, now, "unchanged and confirmed recently: nothing written")
        XCTAssertTrue(publisher.isDue(now: now.addingTimeInterval(60)))
        publisher.publish(recording, now: now.addingTimeInterval(60))
        XCTAssertEqual(publisher.published?.asOf, now.addingTimeInterval(60))
        recording.bookmarkCount = 1
        publisher.publish(recording, now: now.addingTimeInterval(61))
        XCTAssertEqual(publisher.published?.bookmarkCount, 1, "a change goes at once")
        publisher.publish(SharedRecordingState(), now: now.addingTimeInterval(62))
        XCTAssertFalse(publisher.isDue(now: now.addingTimeInterval(1_000)), "nothing to confirm when idle")
    }

    // MARK: The Live Activity

    func testTheLiveActivityGoesStaleWithoutTheAppAndSaysSo() {
        let recording = RecordingActivityAttributes.ContentState(phase: .recording, timerStart: now, level: 0.33, bookmarkCount: 1)
        XCTAssertEqual(recording.staleDate(from: now), now.addingTimeInterval(90))
        XCTAssertEqual(recording.title(isStale: false), "Recording")
        XCTAssertEqual(recording.title(isStale: true), "Not confirmed")
        var paused = recording
        paused.phase = .paused
        XCTAssertEqual(paused.staleDate(from: now), now.addingTimeInterval(2 * 3_600))
        XCTAssertEqual(paused.title(isStale: false), "Paused")
        var saved = recording
        saved.phase = .saved
        XCTAssertNil(saved.staleDate(from: now))
        XCTAssertEqual(saved.title(isStale: true), "Saved")
    }

    func testTheLiveActivityIsRefreshedAtLeastOnceAMinute() {
        let recording = RecordingActivityAttributes.ContentState(phase: .recording, timerStart: now, level: 0.33, bookmarkCount: 1)
        let send = { (state: RecordingActivityAttributes.ContentState, sentAt: Date, levelAt: Date, at: Date) in
            RecordingActivityController.shouldSend(state, current: recording, sentAt: sentAt, levelSentAt: levelAt, now: at)
        }
        XCTAssertFalse(send(recording, now, now, now.addingTimeInterval(30)), "nothing changed")
        XCTAssertTrue(send(recording, now, now, now.addingTimeInterval(60)), "the stale date keeps rolling")
        XCTAssertTrue(RecordingActivityController.shouldSend(recording, current: nil, sentAt: .distantPast, levelSentAt: .distantPast, now: now))
        var louder = recording
        louder.level = 0.66
        XCTAssertFalse(send(louder, now, now, now.addingTimeInterval(1)), "level-only changes wait")
        XCTAssertTrue(send(louder, now, now, now.addingTimeInterval(2)))
        var bookmarked = recording
        bookmarked.bookmarkCount = 2
        XCTAssertTrue(send(bookmarked, now, now, now.addingTimeInterval(0.1)), "a change goes at once")
    }

    func testTheCaptionLineIsShortAndEndsWithWhatWasJustSaid() {
        typealias State = RecordingActivityAttributes.ContentState
        XCTAssertEqual(State.captionLine("  So the first   screen\nasks for a name "), "So the first screen asks for a name")
        XCTAssertNil(State.captionLine(nil))
        XCTAssertNil(State.captionLine("   "))
        let long = "Then we skip straight to inviting people, which tested well in the last round, though the empty state needs another pass"
        let line = State.captionLine(long)
        XCTAssertLessThanOrEqual(line?.count ?? .max, State.captionLength)
        XCTAssertEqual(line?.first, "…", "the start goes")
        XCTAssertTrue(line?.hasSuffix("the empty state needs another pass") == true, "the newest words stay")
        XCTAssertFalse(line?.dropFirst().hasPrefix(" ") ?? true, "whole words")
        XCTAssertEqual(State.captionLine(String(repeating: "a", count: 200))?.count, State.captionLength)
    }

    func testTheActivityShowsACaptionOnlyWhileCaptionsAreOnAndShowing() {
        let say = "Let's hold the fourteenth."
        XCTAssertEqual(PhoneAppModel.activityCaption(captionsOn: true, showing: true, forThisRecording: true, paused: false, newest: say), say)
        XCTAssertNil(PhoneAppModel.activityCaption(captionsOn: false, showing: true, forThisRecording: true, paused: false, newest: say))
        XCTAssertNil(PhoneAppModel.activityCaption(captionsOn: true, showing: false, forThisRecording: true, paused: false, newest: say))
        XCTAssertNil(PhoneAppModel.activityCaption(captionsOn: true, showing: true, forThisRecording: false, paused: false, newest: say))
        XCTAssertNil(PhoneAppModel.activityCaption(captionsOn: true, showing: true, forThisRecording: true, paused: true, newest: say))
        XCTAssertNil(PhoneAppModel.activityCaption(captionsOn: true, showing: true, forThisRecording: true, paused: false, newest: nil),
                     "nothing heard yet, no line")
    }

    func testANewCaptionUpdatesTheActivityAtMostEveryFewSeconds() {
        var shown = RecordingActivityAttributes.ContentState(phase: .recording, timerStart: now, level: 0.33, bookmarkCount: 0)
        shown.caption = "So the first screen"
        var next = shown
        next.caption = "So the first screen asks for a name"
        let interval = RecordingActivityAttributes.ContentState.captionInterval
        let held = RecordingActivityController.paced(next, current: shown, captionSentAt: now, now: now.addingTimeInterval(interval - 1))
        XCTAssertEqual(held.caption, "So the first screen", "the line on screen stays until it's due")
        XCTAssertFalse(RecordingActivityController.shouldSend(held, current: shown, sentAt: now, levelSentAt: now,
                                                              now: now.addingTimeInterval(interval - 1)), "so nothing is sent")
        let due = RecordingActivityController.paced(next, current: shown, captionSentAt: now, now: now.addingTimeInterval(interval))
        XCTAssertEqual(due.caption, next.caption)
        XCTAssertTrue(RecordingActivityController.shouldSend(due, current: shown, sentAt: now, levelSentAt: now, now: now.addingTimeInterval(interval)))
        var off = shown
        off.caption = nil
        XCTAssertNil(RecordingActivityController.paced(off, current: shown, captionSentAt: now, now: now.addingTimeInterval(1)).caption,
                     "a caption going away (captions off, paused) goes at once")
        var louder = next
        louder.level = 0.66
        XCTAssertEqual(RecordingActivityController.paced(louder, current: shown, captionSentAt: now, now: now.addingTimeInterval(3)).caption,
                       shown.caption, "a level update doesn't bring a new caption early")
    }

    func testAnActivityStateFromAnEarlierBuildDecodes() throws {
        let earlier = #"{"phase":"recording","timerStart":800000000,"level":0.33,"bookmarkCount":1,"multipoint":"Also on Studio Mac"}"#
        let decoded = try JSONDecoder().decode(RecordingActivityAttributes.ContentState.self, from: Data(earlier.utf8))
        XCTAssertNil(decoded.caption)
        XCTAssertEqual(decoded.multipoint, "Also on Studio Mac")
    }

    /// WCAG 2 contrast of each Live Activity button's label on its fill, in light, dark, and both with
    /// Increase Contrast.
    func testTheLiveActivitysButtonLabelsAreReadableOnTheirFills() {
        func luminance(_ rgb: UInt32) -> Double {
            func channel(_ value: UInt32) -> Double {
                let c = Double(value & 0xFF) / 255
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(rgb >> 16) + 0.7152 * channel(rgb >> 8) + 0.0722 * channel(rgb)
        }
        func contrast(_ a: UInt32, _ b: UInt32) -> Double {
            let (x, y) = (luminance(a), luminance(b))
            return (max(x, y) + 0.05) / (min(x, y) + 0.05)
        }
        for (name, ink) in [("bookmark", PhoneStyle.ActivityButton.bookmark), ("resume", PhoneStyle.ActivityButton.resume),
                            ("stop", PhoneStyle.ActivityButton.stop)] {
            for variant in 0..<4 {
                XCTAssertGreaterThanOrEqual(contrast(ink.fill[variant], ink.label[variant]), 4.5, "\(name), appearance \(variant)")
            }
        }
        XCTAssertEqual(PhoneStyle.ActivityButton.all.count, 3)
    }
}
