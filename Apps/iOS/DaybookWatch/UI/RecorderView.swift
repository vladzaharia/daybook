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
            RecordButton(isRecording: model.recording != nil) { model.toggleRecording() }
            LevelMeter(level: model.isCapturing ? model.level : 0)
                .opacity(model.isCapturing ? 1 : 0)
            if let line = model.statusLine {
                Text(line)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(WatchMotion.resolved(WatchMotion.state, reduceMotion: reduceMotion), value: model.statusLine)
    }

    @ViewBuilder
    private var elapsed: some View {
        Group {
            if let recording = model.recording {
                Text(timerInterval: recording.startedAt...Date.distantFuture, countsDown: false)
                    .foregroundStyle(model.isCapturing ? .primary : .secondary)
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
        .accessibilityLabel(isRecording ? "Stop Recording" : "Record")
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
