import DaybookCore
import SwiftUI

/// The recording's clock: red while recording, frozen while paused.
struct ElapsedClock: View {
    @Environment(PhoneAppModel.self) private var model
    var size: CGFloat = 56

    var body: some View {
        let recorder = model.recorder
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let seconds = recorder.pausedAt ?? recorder.elapsedTime
            Text(TimeLabel.short(seconds))
                .font(PhoneStyle.Typeface.clock(size))
                .foregroundStyle(recorder.state == .recording ? PhoneStyle.Ink.record : PhoneStyle.Ink.title)
                .contentTransition(.numericText())
                .accessibilityLabel(recorder.isPaused ? "Paused at \(TimeLabel.short(seconds))" : "Recording, \(TimeLabel.short(seconds))")
        }
    }
}

/// Input level as a row of bars, teal like the Mac's meters.
struct LevelMeter: View {
    var value: Double
    var bars = 20

    var body: some View {
        GeometryReader { proxy in
            let gap: CGFloat = 3
            let width = max(1, (proxy.size.width - gap * CGFloat(bars - 1)) / CGFloat(bars))
            HStack(spacing: gap) {
                ForEach(0..<bars, id: \.self) { index in
                    let lit = Double(index) < value * Double(bars)
                    RoundedRectangle(cornerRadius: min(width, proxy.size.height) / 2)
                        .fill(lit ? AnyShapeStyle(PhoneStyle.accent) : AnyShapeStyle(.quaternary))
                        .frame(width: width)
                }
            }
        }
        .frame(minHeight: 8)
        .animation(.linear(duration: 0.08), value: value)
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(value * 100)) percent")
    }
}

/// The recorder's status: the red dot and clock, the level, the microphone, and a pause box when
/// something needs the person.
struct RecorderStatus: View {
    @Environment(PhoneAppModel.self) private var model
    var compact: Bool

    var body: some View {
        let recorder = model.recorder
        VStack(alignment: .leading, spacing: PhoneStyle.Space.s3) {
            if recorder.isCapturing || recorder.state == .stopping {
                HStack(alignment: .center, spacing: PhoneStyle.Space.s2) {
                    Circle().fill(recorder.state == .recording ? PhoneStyle.Ink.record : PhoneStyle.Ink.faint)
                        .frame(width: 12, height: 12)
                    ElapsedClock(size: compact ? 40 : 56)
                    Spacer(minLength: 0)
                }
                LevelMeter(value: recorder.state == .recording ? recorder.level.meterValue : 0)
                    .frame(height: 10)
                HStack(spacing: PhoneStyle.Space.s1) {
                    Image(systemName: "mic").imageScale(.small)
                    Text(recorder.isMicrophoneSilent ? "Microphone silent" : (recorder.inputRoute?.name ?? "Microphone"))
                }
                .font(.footnote)
                .foregroundStyle(recorder.isMicrophoneSilent ? PhoneStyle.Ink.warning : PhoneStyle.Ink.secondary)
                if recorder.isPaused { PauseBox() }
            } else if model.isFiling || recorder.state == .stopping {
                Text("Saving…").font(.subheadline).foregroundStyle(PhoneStyle.Ink.secondary)
            } else {
                VStack(alignment: .leading, spacing: PhoneStyle.Space.s1) {
                    Text("Ready to record").font(PhoneStyle.Typeface.title(24)).foregroundStyle(PhoneStyle.Ink.title)
                    if let message = model.cloud.message {
                        Text(message)
                            .font(.subheadline).foregroundStyle(PhoneStyle.Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A state that needs the person: one quiet filled box, at most two actions.
struct PauseBox: View {
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        let recorder = model.recorder
        VStack(alignment: .leading, spacing: PhoneStyle.Space.s2) {
            Label("Paused", systemImage: "pause.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PhoneStyle.Ink.warning)
            Text(recorder.pauseMessage ?? "The recording is paused.")
                .font(.subheadline).foregroundStyle(PhoneStyle.Ink.secondary)
            if recorder.canResume {
                Button("Resume Recording") { Task { try? await model.resumeRecording() } }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PhoneStyle.Ink.link)
            }
        }
        .padding(PhoneStyle.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PhoneStyle.Ink.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Record when idle; Bookmark and Stop while recording. At the bottom, where the thumb is.
struct RecordControls: View {
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        let recorder = model.recorder
        Group {
            if recorder.isCapturing {
                HStack(spacing: PhoneStyle.Space.s3) {
                    BookmarkButton()
                    StopButton()
                }
            } else {
                Button {
                    Task { try? await model.startRecording() }
                } label: {
                    HStack(spacing: PhoneStyle.Space.s2) {
                        Circle().fill(PhoneStyle.Ink.record).frame(width: 14, height: 14)
                        Text("Record").font(.title3.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.glass)
                .foregroundStyle(PhoneStyle.Ink.title)
                .disabled(recorder.state != .idle || model.isFiling)
                .accessibilityHint("Starts recording with the microphone")
            }
        }
        .animation(.snappy(duration: 0.25), value: recorder.isCapturing)
    }
}

struct BookmarkButton: View {
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        let count = model.recorder.bookmarkCount
        Button {
            Task { try? await model.addBookmark() }
        } label: {
            HStack(spacing: PhoneStyle.Space.s2) {
                Image(systemName: "bookmark.fill").symbolEffect(.bounce, value: count)
                Text("Bookmark")
                if count > 0 {
                    Text("\(count)").font(.caption.weight(.bold)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(PhoneStyle.bookmark.opacity(0.18), in: Capsule())
                }
            }
            .font(.headline)
            .foregroundStyle(PhoneStyle.bookmark)
            .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(.glass)
        .accessibilityLabel(count > 0 ? "Bookmark, \(count) so far" : "Bookmark")
    }
}

/// Stop: a red capsule with its own colours, so it reads as Stop in any appearance.
struct StopButton: View {
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        Button {
            Task { try? await model.stopRecording() }
        } label: {
            Label("Stop", systemImage: "stop.fill")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(PhoneStyle.Ink.recordFill, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(model.recorder.state == .stopping)
    }
}

/// One line when something needs saying (a recovered recording, a failure).
struct NoticeLine: View {
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        if let notice = model.notice {
            HStack(alignment: .top, spacing: PhoneStyle.Space.s2) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(PhoneStyle.Ink.warning)
                Text(notice).font(.footnote).foregroundStyle(PhoneStyle.Ink.secondary)
                Spacer(minLength: 0)
                Button { model.dismissNotice() } label: { Image(systemName: "xmark").font(.footnote) }
                    .foregroundStyle(PhoneStyle.Ink.meta)
                    .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, PhoneStyle.Space.s4)
            .padding(.vertical, PhoneStyle.Space.s2)
        }
    }
}

/// This recording's bookmarks, newest first (the notebook's right page).
struct BookmarkList: View {
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        let marks = model.recorder.highlights.reversed()
        if !marks.isEmpty {
            VStack(alignment: .leading, spacing: PhoneStyle.Space.s2) {
                ForEach(Array(marks)) { mark in
                    HStack(spacing: PhoneStyle.Space.s2) {
                        Image(systemName: "bookmark.fill").foregroundStyle(PhoneStyle.bookmark)
                        Text(TimeLabel.short(mark.time)).font(.subheadline).monospacedDigit().foregroundStyle(PhoneStyle.Ink.body)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
