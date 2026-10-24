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
                        LevelDot(state: context.state, size: 12)
                        Text(phaseTitle(context.state)).font(.subheadline.weight(.semibold))
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ActivityClock(state: context.state)
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(context.state.phase == .recording ? PhoneStyle.Ink.record : .white)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        if let multipoint = context.state.multipoint {
                            Label(multipoint, systemImage: "macbook.and.iphone")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        ActivityButtons(state: context.state)
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                LevelDot(state: context.state, size: 10)
            } compactTrailing: {
                ActivityClock(state: context.state)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(context.state.phase == .recording ? PhoneStyle.Ink.record : .white)
                    .frame(maxWidth: 52)
            } minimal: {
                LevelDot(state: context.state, size: 10)
            }
            .keylineTint(PhoneStyle.Ink.record)
        }
    }
}

private func phaseTitle(_ state: RecordingActivityAttributes.ContentState) -> String {
    switch state.phase {
    case .recording: return "Recording"
    case .paused: return "Paused"
    case .saved: return "Saved"
    }
}

/// Counts itself while recording; frozen when paused or saved.
struct ActivityClock: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        if state.phase == .recording {
            Text(timerInterval: state.timerStart...Date.distantFuture, countsDown: false, showsHours: true)
                .multilineTextAlignment(.trailing)
        } else {
            Text(TimeLabel.short(state.frozenElapsed ?? 0))
        }
    }
}

/// Red while recording, brighter with more input; grey when paused.
struct LevelDot: View {
    let state: RecordingActivityAttributes.ContentState
    var size: CGFloat

    var body: some View {
        let recording = state.phase == .recording
        ZStack {
            if recording {
                Circle().fill(PhoneStyle.Ink.record.opacity(0.25 + 0.35 * state.level))
                    .frame(width: size * (1 + 0.6 * state.level), height: size * (1 + 0.6 * state.level))
            }
            Circle().fill(recording ? PhoneStyle.Ink.record : Color.gray).frame(width: size, height: size)
        }
        .frame(width: size * 1.6, height: size * 1.6)
        .accessibilityLabel(recording ? "Recording" : phaseTitle(state))
    }
}

struct ActivityButtons: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 10) {
            switch state.phase {
            case .recording:
                Button(intent: AddBookmarkIntent()) {
                    Label(state.bookmarkCount > 0 ? "Bookmark · \(state.bookmarkCount)" : "Bookmark", systemImage: "bookmark.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .tint(PhoneStyle.bookmark)
                .foregroundStyle(PhoneStyle.bookmark)
            case .paused:
                Button(intent: ResumeRecordingIntent()) {
                    Label("Resume", systemImage: "record.circle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .tint(.white)
            case .saved:
                EmptyView()
            }
            if state.phase != .saved {
                Button(intent: StopRecordingIntent()) {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .tint(PhoneStyle.Ink.recordFill)
                .foregroundStyle(.white)
            }
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
    }
}

struct LockScreenRecording: View {
    let context: ActivityViewContext<RecordingActivityAttributes>

    var body: some View {
        let state = context.state
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                LevelDot(state: state, size: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(phaseTitle(state)).font(.subheadline.weight(.semibold))
                    Text(context.attributes.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let multipoint = state.multipoint, state.phase != .saved {
                        Label(multipoint, systemImage: "macbook.and.iphone")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                ActivityClock(state: state)
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(state.phase == .recording ? PhoneStyle.Ink.record : .primary)
                    .frame(maxWidth: 120, alignment: .trailing)
            }
            if state.phase == .saved {
                Text("Saved to Daybook")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ActivityButtons(state: state)
            }
        }
        .padding(16)
    }
}
