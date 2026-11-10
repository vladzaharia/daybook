import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// A recorder's recording on the Lock Screen and in the Dynamic Island: Soundcore Work recording what
/// this iPhone started, or Listen Live with Stop Listening. Red means recording; cyan, listening. The
/// small family (the Watch's Smart Stack, CarPlay) is the state, the clock, and Stop Listening's glyph.
struct RecorderLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecorderActivityAttributes.self) { context in
            RecorderActivityContent(context: context)
                .activityBackgroundTint(nil)
                .activitySystemActionForegroundColor(PhoneStyle.Ink.record)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        RecorderDot(context: context, size: 12)
                        Text(context.state.title(isStale: context.isStale)).font(.subheadline.weight(.semibold)).lineLimit(1)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RecorderClock(context: context)
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        Text(context.attributes.recorderName).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        StopListeningButton(context: context)
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                RecorderGlyph(context: context)
            } compactTrailing: {
                CompactRecorderClock(context: context)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .frame(maxWidth: 52)
            } minimal: {
                // Daybook's waveform, as the recording's own activity shows: never a dot that passes for
                // the system's microphone indicator.
                RecorderGlyph(context: context)
            }
            .keylineTint(recorderTint(context))
        }
        .supplementalActivityFamilies([.small])
    }
}

/// The Lock Screen's presentation, or the small family's where the system asks for it.
private struct RecorderActivityContent: View {
    let context: ActivityViewContext<RecorderActivityAttributes>
    @Environment(\.activityFamily) private var family

    var body: some View {
        if family == .small {
            SmallRecorder(context: context)
        } else {
            LockScreenRecorder(context: context)
        }
    }
}

/// The Watch's Smart Stack and CarPlay: what the recorder is doing, the clock, and Stop Listening as a glyph.
private struct SmallRecorder: View {
    let context: ActivityViewContext<RecorderActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                RecorderDot(context: context, size: 8)
                Text(context.state.title(isStale: context.isStale)).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                RecorderClock(context: context)
                    .font(.headline.weight(.semibold).monospacedDigit())
            }
            StopListeningButton(context: context)
                .labelStyle(.iconOnly)
        }
    }
}

/// The compact clock: whole minutes ("12m") where iOS 27 says the island has less width than usual, else the clock.
private struct CompactRecorderClock: View {
    let context: ActivityViewContext<RecorderActivityAttributes>

    var body: some View {
        if #available(iOS 27.0, *) {
            NarrowableRecorderClock(context: context)
        } else {
            RecorderClock(context: context)
        }
    }
}

@available(iOS 27.0, *)
private struct NarrowableRecorderClock: View {
    let context: ActivityViewContext<RecorderActivityAttributes>
    @Environment(\.isDynamicIslandLimitedInWidth) private var isLimited

    var body: some View {
        RecorderClock(context: context, minutesOnly: isLimited)
    }
}

/// Red while recording, cyan while listening, grey once it's stale or ended.
private func recorderTint(_ context: ActivityViewContext<RecorderActivityAttributes>) -> Color {
    guard !context.isStale else { return .gray }
    switch context.state.phase {
    case .recording: return PhoneStyle.Ink.record
    case .listening: return PhoneStyle.neonCyan
    case .ended: return .gray
    }
}

private struct RecorderGlyph: View {
    let context: ActivityViewContext<RecorderActivityAttributes>

    var body: some View {
        Image(systemName: "waveform").foregroundStyle(recorderTint(context))
            .accessibilityLabel(context.state.title(isStale: context.isStale))
    }
}

private struct RecorderDot: View {
    let context: ActivityViewContext<RecorderActivityAttributes>
    var size: CGFloat

    var body: some View {
        Circle().fill(recorderTint(context)).frame(width: size, height: size)
            .frame(width: size * 1.6, height: size * 1.6)
            .accessibilityLabel(context.state.title(isStale: context.isStale))
    }
}

/// Counts from the recording's start; a dash when the start isn't known or it's no longer confirmed.
/// `minutesOnly` says whole minutes ("12m").
private struct RecorderClock: View {
    let context: ActivityViewContext<RecorderActivityAttributes>
    var minutesOnly = false

    var body: some View {
        if let start = context.state.startedAt, !context.isStale, context.state.phase != .ended {
            Group {
                if minutesOnly {
                    Text(.durationOffset(to: start), format: ActivityClock.minutes)
                } else {
                    Text(timerInterval: start...Date.distantFuture, countsDown: false, showsHours: true)
                        .multilineTextAlignment(.trailing)
                }
            }
            .foregroundStyle(recorderTint(context))
        } else {
            Text("–")
        }
    }
}

private struct StopListeningButton: View {
    let context: ActivityViewContext<RecorderActivityAttributes>

    var body: some View {
        if context.state.phase == .listening, !context.isStale {
            Button(intent: StopListeningIntent()) {
                Label("Stop Listening", systemImage: "stop.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PhoneStyle.ActivityButton.resume.labelColor)
                    .frame(maxWidth: .infinity)
            }
            .tint(PhoneStyle.ActivityButton.resume.fillColor)
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
        }
    }
}

private struct LockScreenRecorder: View {
    let context: ActivityViewContext<RecorderActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                RecorderDot(context: context, size: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(context.state.title(isStale: context.isStale)).font(.subheadline.weight(.semibold))
                    Text(context.attributes.recorderName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                RecorderClock(context: context)
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .frame(maxWidth: 120, alignment: .trailing)
            }
            StopListeningButton(context: context)
        }
        .padding(16)
    }
}
