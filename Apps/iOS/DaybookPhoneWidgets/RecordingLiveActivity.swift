import ActivityKit
import AppIntents
import DaybookDesign
import SwiftUI
import WidgetKit

/// The recording on the Lock Screen and in the Dynamic Island: the clock, and Bookmark and Stop (Resume
/// and Stop once a pause can end, Stop alone during a call; none from Stop while it saves). The compact and minimal presentations are
/// Daybook's waveform, so they never pass for the system's microphone dot. Red means recording; amber
/// means bookmarks; the warning ink, a recording that stopped by itself. The small family (the Watch's
/// Smart Stack, CarPlay) is the clock and the buttons alone.
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            RecordingActivityContent(context: context)
                .activityBackgroundTint(nil)
                .activitySystemActionForegroundColor(PhoneStyle.Ink.record)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        HearingDot(state: context.state, isStale: context.isStale, size: 12)
                        Text(context.state.title(isStale: context.isStale)).font(.subheadline.weight(.semibold))
                            .foregroundStyle(titleInk(context))
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ActivityClock(state: context.state, isStale: context.isStale)
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(isLive(context) ? PhoneStyle.Ink.record : .white)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        if let multipoint = context.state.multipoint, !context.isStale, !context.state.hasEnded {
                            Label(multipoint, systemImage: "macbook.and.iphone")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        ActivityCaption(state: context.state, isStale: context.isStale, lines: 1)
                        if let line = context.state.endLine {
                            Text(line).font(.caption).foregroundStyle(.secondary)
                        } else if !context.state.hasEnded {
                            ActivityButtons(state: context.state, isStale: context.isStale)
                        }
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                RecordingGlyph(context: context)
            } compactTrailing: {
                CompactClock(state: context.state, isStale: context.isStale)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(isLive(context) ? PhoneStyle.Ink.record : .white)
                    .frame(maxWidth: 52)
            } minimal: {
                RecordingGlyph(context: context)
            }
            .keylineTint(glyphInk(context))
        }
        .supplementalActivityFamilies([.small])
    }
}

/// The Lock Screen's presentation, or the small family's where the system asks for it.
private struct RecordingActivityContent: View {
    let context: ActivityViewContext<RecordingActivityAttributes>
    @Environment(\.activityFamily) private var family

    var body: some View {
        if family == .small {
            SmallRecording(context: context)
        } else {
            LockScreenRecording(context: context)
        }
    }
}

/// The Watch's Smart Stack and CarPlay: what it's doing, the clock, and the buttons as glyphs. No conversation
/// title: a wrist or a car's screen isn't where Daybook names one.
private struct SmallRecording: View {
    let context: ActivityViewContext<RecordingActivityAttributes>

    var body: some View {
        let state = context.state
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                HearingDot(state: state, isStale: context.isStale, size: 8)
                Text(state.title(isStale: context.isStale)).font(.caption.weight(.semibold))
                    .foregroundStyle(titleInk(context))
                    .lineLimit(1)
                Spacer(minLength: 4)
                ActivityClock(state: state, isStale: context.isStale)
                    .font(.headline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(isLive(context) ? PhoneStyle.Ink.record : .primary)
            }
            if let line = state.endLine {
                Text(line).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            } else if !state.hasEnded {
                ActivityButtons(state: state, isStale: context.isStale, iconsOnly: true)
            }
        }
    }
}

/// The compact clock: whole minutes ("12m") where iOS 27 says the island has less width than usual, else the clock.
private struct CompactClock: View {
    let state: RecordingActivityAttributes.ContentState
    var isStale = false

    var body: some View {
        if #available(iOS 27.0, *) {
            NarrowableClock(state: state, isStale: isStale)
        } else {
            ActivityClock(state: state, isStale: isStale)
        }
    }
}

@available(iOS 27.0, *)
private struct NarrowableClock: View {
    let state: RecordingActivityAttributes.ContentState
    var isStale = false
    @Environment(\.isDynamicIslandLimitedInWidth) private var isLimited

    var body: some View {
        ActivityClock(state: state, isStale: isStale, minutesOnly: isLimited)
    }
}

/// Recording, and confirmed recently: the clock and glyph are red only then.
private func isLive(_ context: ActivityViewContext<RecordingActivityAttributes>) -> Bool {
    context.state.phase == .recording && !context.isStale
}

/// The glyph's ink: red while recording, the warning ink once it stopped by itself, grey otherwise.
private func glyphInk(_ context: ActivityViewContext<RecordingActivityAttributes>) -> Color {
    if context.state.phase == .stopped { return PhoneStyle.Ink.warning }
    return isLive(context) ? PhoneStyle.Ink.record : .gray
}

/// The title's ink: the warning ink once it stopped by itself, else the system's.
private func titleInk(_ context: ActivityViewContext<RecordingActivityAttributes>) -> Color {
    context.state.phase == .stopped ? PhoneStyle.Ink.warning : .primary
}

/// Daybook's waveform, for the compact and minimal presentations.
private struct RecordingGlyph: View {
    let context: ActivityViewContext<RecordingActivityAttributes>

    var body: some View {
        Image(systemName: context.state.phase == .stopped ? "exclamationmark.triangle.fill" : "waveform")
            .foregroundStyle(glyphInk(context))
            .accessibilityLabel(context.state.title(isStale: context.isStale))
    }
}

/// Counts itself while recording; frozen when paused, saving, saved, or stopped; a dash once it's stale,
/// because the app hasn't confirmed the recording is still going. `minutesOnly` says whole minutes ("12m").
struct ActivityClock: View {
    let state: RecordingActivityAttributes.ContentState
    var isStale = false
    var minutesOnly = false

    /// Whole minutes, as narrow as they go: "12m".
    static let minutes = Duration.UnitsFormatStyle(allowedUnits: [.minutes], width: .narrow, fractionalPart: .hide(rounded: .down))

    var body: some View {
        if isStale, !state.hasEnded {
            Text("–")
        } else if state.phase == .recording {
            if minutesOnly {
                Text(.durationOffset(to: state.timerStart), format: Self.minutes)
            } else {
                Text(timerInterval: state.timerStart...Date.distantFuture, countsDown: false, showsHours: true)
                    .multilineTextAlignment(.trailing)
            }
        } else if minutesOnly {
            Text(Duration.seconds(state.frozenElapsed ?? 0).formatted(Self.minutes))
        } else {
            Text(DaybookTime.short(state.frozenElapsed ?? 0))
        }
    }
}

/// Red while recording and the microphone hears something; dimmed when it has heard nothing for a few
/// seconds; grey when paused or not confirmed; the warning ink once it stopped by itself.
struct HearingDot: View {
    let state: RecordingActivityAttributes.ContentState
    var isStale = false
    var size: CGFloat

    var body: some View {
        let recording = state.phase == .recording && !isStale
        let ink = state.phase == .stopped ? PhoneStyle.Ink.warning : recording ? PhoneStyle.Ink.record : Color.gray
        Circle().fill(ink.opacity(recording && state.level == 0 ? 0.45 : 1))
            .frame(width: size, height: size)
            .frame(width: size * 1.6, height: size * 1.6)
            .accessibilityLabel(state.title(isStale: isStale))
    }
}

/// Bookmark and Stop while recording; Resume and Stop once a pause can end; Stop alone during the call
/// and when it's stale. Each label has its own ink on its fill (4.5:1 in both appearances); a filled
/// button's default white label vanished on Resume's white and Bookmark's amber. `iconsOnly` shows the
/// glyphs alone (the small family), each still named for VoiceOver.
struct ActivityButtons: View {
    let state: RecordingActivityAttributes.ContentState
    var isStale = false
    var iconsOnly = false

    var body: some View {
        if iconsOnly {
            buttons.labelStyle(.iconOnly)
        } else {
            buttons
        }
    }

    private var buttons: some View {
        HStack(spacing: iconsOnly ? 6 : 10) {
            if state.phase == .recording, !isStale {
                Button(intent: AddBookmarkIntent()) {
                    Label(state.bookmarkCount > 0 ? "Bookmark · \(state.bookmarkCount)" : "Bookmark", systemImage: "bookmark.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PhoneStyle.ActivityButton.bookmark.labelColor)
                        .frame(maxWidth: .infinity)
                }
                .tint(PhoneStyle.ActivityButton.bookmark.fillColor)
            } else if state.offersResume, !isStale {
                Button(intent: ResumeRecordingIntent()) {
                    Label("Resume", systemImage: "record.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PhoneStyle.ActivityButton.resume.labelColor)
                        .frame(maxWidth: .infinity)
                }
                .tint(PhoneStyle.ActivityButton.resume.fillColor)
            }
            if !state.hasEnded {
                Button(intent: StopRecordingIntent()) {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PhoneStyle.ActivityButton.stop.labelColor)
                        .frame(maxWidth: .infinity)
                }
                .tint(PhoneStyle.ActivityButton.stop.fillColor)
            }
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
    }
}

/// The newest live caption, while it's recording and confirmed: the end of what was said, so a
/// long line loses its start. What was said is private, hidden while the iPhone is locked, and not
/// shown at the dim Always-On brightness.
struct ActivityCaption: View {
    let state: RecordingActivityAttributes.ContentState
    var isStale = false
    var lines = 2
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        if Self.shows(state, isStale: isStale), let caption = state.caption, !isLuminanceReduced {
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(lines)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .privacySensitive()
                .accessibilityLabel("Live caption: \(caption)")
        }
    }

    static func shows(_ state: RecordingActivityAttributes.ContentState, isStale: Bool) -> Bool {
        state.caption != nil && state.phase == .recording && !isStale
    }
}

/// The Lock Screen presentation, inside its 160 pt: the header (with the multipoint line only while no
/// caption shows), the caption (one line at the larger text sizes), and the buttons, with Dynamic Type
/// capped where three rows would no longer fit.
struct LockScreenRecording: View {
    let context: ActivityViewContext<RecordingActivityAttributes>
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let state = context.state
        let captioned = ActivityCaption.shows(state, isStale: context.isStale)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                HearingDot(state: state, isStale: context.isStale, size: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.title(isStale: context.isStale)).font(.subheadline.weight(.semibold))
                        .foregroundStyle(titleInk(context))
                    // A conversation's title is private: hidden while the iPhone is locked.
                    Text(context.attributes.title).font(.caption).foregroundStyle(.secondary).lineLimit(1).privacySensitive()
                    if let multipoint = state.multipoint, !state.hasEnded, !context.isStale, !captioned {
                        Label(multipoint, systemImage: "macbook.and.iphone")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                ActivityClock(state: state, isStale: context.isStale)
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(isLive(context) ? PhoneStyle.Ink.record : .primary)
                    .frame(maxWidth: 120, alignment: .trailing)
            }
            ActivityCaption(state: state, isStale: context.isStale, lines: typeSize > .xLarge ? 1 : 2)
            if let line = state.endLine {
                Text(line).font(.caption).foregroundStyle(.secondary)
            } else if !state.hasEnded {
                ActivityButtons(state: state, isStale: context.isStale)
            }
        }
        .padding(14)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }
}

#if DEBUG
#Preview("Recording, with a caption", as: .content, using: RecordingActivityAttributes(conversationID: UUID(), title: "Design review")) {
    RecordingLiveActivity()
} contentStates: {
    RecordingActivityAttributes.ContentState(phase: .recording, timerStart: Date().addingTimeInterval(-754), level: 1, bookmarkCount: 2,
                                             multipoint: "Also on Studio Mac",
                                             caption: RecordingActivityAttributes.ContentState.captionLine(
                                                "So the first screen asks for the name of the team, then we skip straight to inviting people"))
    RecordingActivityAttributes.ContentState(phase: .recording, timerStart: Date().addingTimeInterval(-754), level: 1, bookmarkCount: 2,
                                             multipoint: "Also on Studio Mac")
    RecordingActivityAttributes.ContentState(phase: .paused, timerStart: Date().addingTimeInterval(-754), frozenElapsed: 754, level: 0,
                                             bookmarkCount: 2, canResume: false)
    RecordingActivityAttributes.ContentState(phase: .paused, timerStart: Date().addingTimeInterval(-754), frozenElapsed: 754, level: 0,
                                             bookmarkCount: 2, canResume: true)
    RecordingActivityAttributes.ContentState(phase: .saving, timerStart: Date().addingTimeInterval(-754), frozenElapsed: 754, level: 0,
                                             bookmarkCount: 2)
    RecordingActivityAttributes.ContentState(phase: .stopped, timerStart: Date().addingTimeInterval(-3_734), frozenElapsed: 3_734, level: 0,
                                             bookmarkCount: 2)
}
#endif
