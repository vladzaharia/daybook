import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The recording on the Lock Screen and in the Dynamic Island: the clock, a level dot, and
/// Bookmark and Stop (or Resume and Stop while paused). Red means recording; amber means bookmarks.
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            LockScreenRecording(context: context)
                .activityBackgroundTint(nil)
                .activitySystemActionForegroundColor(PhoneStyle.Ink.record)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        LevelDot(state: context.state, isStale: context.isStale, size: 12)
                        Text(context.state.title(isStale: context.isStale)).font(.subheadline.weight(.semibold))
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
                        if let multipoint = context.state.multipoint, !context.isStale {
                            Label(multipoint, systemImage: "macbook.and.iphone")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        ActivityCaption(state: context.state, isStale: context.isStale, lines: 1)
                        ActivityButtons(state: context.state, isStale: context.isStale)
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                LevelDot(state: context.state, isStale: context.isStale, size: 10)
            } compactTrailing: {
                ActivityClock(state: context.state, isStale: context.isStale)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(isLive(context) ? PhoneStyle.Ink.record : .white)
                    .frame(maxWidth: 52)
            } minimal: {
                LevelDot(state: context.state, isStale: context.isStale, size: 10)
            }
            .keylineTint(PhoneStyle.Ink.record)
        }
    }
}

/// Recording, and confirmed recently: the clock and dot are red only then.
private func isLive(_ context: ActivityViewContext<RecordingActivityAttributes>) -> Bool {
    context.state.phase == .recording && !context.isStale
}

/// Counts itself while recording; frozen when paused or saved; a dash once it's stale, because the
/// app hasn't confirmed the recording is still going.
struct ActivityClock: View {
    let state: RecordingActivityAttributes.ContentState
    var isStale = false

    var body: some View {
        if isStale, state.phase != .saved {
            Text("–")
        } else if state.phase == .recording {
            Text(timerInterval: state.timerStart...Date.distantFuture, countsDown: false, showsHours: true)
                .multilineTextAlignment(.trailing)
        } else {
            Text(TimeLabel.short(state.frozenElapsed ?? 0))
        }
    }
}

/// Red while recording, brighter with more input; grey when paused or not confirmed.
struct LevelDot: View {
    let state: RecordingActivityAttributes.ContentState
    var isStale = false
    var size: CGFloat

    var body: some View {
        let recording = state.phase == .recording && !isStale
        ZStack {
            if recording {
                Circle().fill(PhoneStyle.Ink.record.opacity(0.25 + 0.35 * state.level))
                    .frame(width: size * (1 + 0.6 * state.level), height: size * (1 + 0.6 * state.level))
            }
            Circle().fill(recording ? PhoneStyle.Ink.record : Color.gray).frame(width: size, height: size)
        }
        .frame(width: size * 1.6, height: size * 1.6)
        .accessibilityLabel(state.title(isStale: isStale))
    }
}

/// Bookmark and Stop, or Resume and Stop. Each label has its own ink on its fill (4.5:1 in both
/// appearances); a filled button's default white label vanished on Resume's white and Bookmark's amber.
struct ActivityButtons: View {
    let state: RecordingActivityAttributes.ContentState
    var isStale = false

    var body: some View {
        HStack(spacing: 10) {
            switch state.phase {
            case .recording where !isStale:
                Button(intent: AddBookmarkIntent()) {
                    Label(state.bookmarkCount > 0 ? "Bookmark · \(state.bookmarkCount)" : "Bookmark", systemImage: "bookmark.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PhoneStyle.ActivityButton.bookmark.labelColor)
                        .frame(maxWidth: .infinity)
                }
                .tint(PhoneStyle.ActivityButton.bookmark.fillColor)
            case .paused where !isStale:
                Button(intent: ResumeRecordingIntent()) {
                    Label("Resume", systemImage: "record.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PhoneStyle.ActivityButton.resume.labelColor)
                        .frame(maxWidth: .infinity)
                }
                .tint(PhoneStyle.ActivityButton.resume.fillColor)
            default:
                EmptyView()
            }
            if state.phase != .saved {
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
        if let caption = state.caption, state.phase == .recording, !isStale, !isLuminanceReduced {
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
}

struct LockScreenRecording: View {
    let context: ActivityViewContext<RecordingActivityAttributes>

    var body: some View {
        let state = context.state
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                LevelDot(state: state, isStale: context.isStale, size: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.title(isStale: context.isStale)).font(.subheadline.weight(.semibold))
                    // A conversation's title is private: hidden while the iPhone is locked.
                    Text(context.attributes.title).font(.caption).foregroundStyle(.secondary).lineLimit(1).privacySensitive()
                    if let multipoint = state.multipoint, state.phase != .saved, !context.isStale {
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
            ActivityCaption(state: state, isStale: context.isStale, lines: 2)
            if state.phase == .saved {
                Text("Saved to Daybook")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ActivityButtons(state: state, isStale: context.isStale)
            }
        }
        .padding(16)
    }
}

#if DEBUG
#Preview("Recording, with a caption", as: .content, using: RecordingActivityAttributes(conversationID: UUID(), title: "Design review")) {
    RecordingLiveActivity()
} contentStates: {
    RecordingActivityAttributes.ContentState(phase: .recording, timerStart: Date().addingTimeInterval(-754), level: 0.66, bookmarkCount: 2,
                                             caption: RecordingActivityAttributes.ContentState.captionLine(
                                                "So the first screen asks for the name of the team, then we skip straight to inviting people"))
    RecordingActivityAttributes.ContentState(phase: .recording, timerStart: Date().addingTimeInterval(-754), level: 0.33, bookmarkCount: 2)
}
#endif
