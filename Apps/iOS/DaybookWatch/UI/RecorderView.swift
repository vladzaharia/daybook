import DaybookWatchLink
import SwiftUI

/// The watch's one screen: the elapsed time, the record button, a small level meter, and a status line only when it
/// matters.
struct RecorderView: View {
    @Environment(WatchModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 8) {
            elapsed
            if model.pausedLength != nil {
                RecordButton(isRecording: false, label: "Resume") { model.resumeRecording() }
                Button("Stop") { model.toggleRecording() }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.red)
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop Recording")
            } else {
                HStack(spacing: 8) {
                    RecordButton(isRecording: model.recording != nil, label: model.recording != nil ? "Stop Recording" : "Record") {
                        model.toggleRecording()
                    }
                    .disabled(model.isStarting)
                    .opacity(model.isStarting ? 0.5 : 1)
                    if model.recording != nil {
                        BookmarkButton(count: model.bookmarkCount, isEnabled: model.isCapturing) { model.addBookmark() }
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                if model.offersKeep {
                    Button(WatchWords.keepRecording) { model.keepRecording() }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.red)
                        .buttonStyle(.plain)
                        .transition(.opacity)
                } else {
                    LevelMeter(level: model.isCapturing ? model.level : 0)
                        .opacity(model.isCapturing ? 1 : 0)
                }
            }
            if model.recording == nil, model.pausedLength == nil, model.showsSummary {
                Text(verbatim: model.afterStopLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            } else if let line = model.statusLine {
                Text(line)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                if let detail = model.statusDetail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(WatchMotion.resolved(WatchMotion.state, reduceMotion: reduceMotion), value: model.statusLine)
        .animation(WatchMotion.resolved(WatchMotion.state, reduceMotion: reduceMotion), value: model.showsSummary)
        .animation(WatchMotion.resolved(WatchMotion.state, reduceMotion: reduceMotion), value: model.offersKeep)
        .animation(WatchMotion.resolved(WatchMotion.state, reduceMotion: reduceMotion), value: model.recording != nil)
        .sensoryFeedback(trigger: model.showsSummary) { _, shows in shows ? .success : nil }
    }

    @ViewBuilder
    private var elapsed: some View {
        Group {
            if let paused = model.pausedLength {
                // Held at the length recorded; the clock below counts only while the microphone captures.
                Text(verbatim: WatchWords.clock(paused))
                    .foregroundStyle(.secondary)
            } else if let recording = model.recording {
                Text(timerInterval: recording.startedAt...Date.distantFuture, countsDown: false)
            } else if model.showsSummary, let moment = model.afterStop {
                Label(moment.title, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.green)
            } else {
                Text(verbatim: "0:00")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .font(.system(size: 32, weight: .semibold, design: .rounded).monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

/// A large round button: a red dot to record, a red square to stop.
private struct RecordButton: View {
    var isRecording: Bool
    var label: String
    var action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(.white.opacity(0.3), lineWidth: 4)
                if isRecording {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.red)
                        .frame(width: 34, height: 34)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Circle()
                        .fill(.red)
                        .padding(9)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 84, height: 84)
            .glassEffect(in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(WatchMotion.resolved(WatchMotion.state, reduceMotion: reduceMotion), value: isRecording)
        .accessibilityLabel(label)
    }
}

/// Marks this moment: a small amber button beside Stop, with the count of marks so far.
private struct BookmarkButton: View {
    var count: Int
    var isEnabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 18, weight: .semibold))
                if count > 0 {
                    Text(verbatim: "\(count)")
                        .font(.caption2.monospacedDigit())
                }
            }
            .foregroundStyle(.orange)
            .frame(width: 48, height: 48)
            .glassEffect(in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(WatchWords.bookmarkTitle(count: count))
    }
}

/// How loud the microphone is.
private struct LevelMeter: View {
    var level: Float
    private let width: CGFloat = 64

    var body: some View {
        Capsule()
            .fill(.white.opacity(0.2))
            .frame(width: width, height: 4)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(.red)
                    .frame(width: width * CGFloat(level), height: 4)
            }
            // Following the level is the reading itself, not motion for Reduce Motion to soften.
            .animation(WatchMotion.progress, value: level)
            .accessibilityHidden(true)
    }
}
