import DaybookCaptions
import DaybookCore
import DaybookLink
import SwiftUI

// The pieces the recording surfaces are built from. Each reads the app model itself, so a posture
// change only rearranges them; nothing about the recording restarts.

/// The elapsed time: red while recording, ink while paused (frozen at the pause).
struct RecordingClockText: View {
    @Environment(PhoneAppModel.self) private var model
    var size: CGFloat
    var weight: Font.Weight = .medium

    var body: some View {
        let recorder = model.recorder
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let seconds = recorder.pausedAt ?? recorder.elapsedTime
            Text(TimeLabel.short(seconds))
                .font(.system(size: size, weight: weight).monospacedDigit())
                .foregroundStyle(recorder.state == .recording ? PhoneStyle.Ink.record : PhoneStyle.Ink.title)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .accessibilityLabel(recorder.isPaused ? "Paused at \(TimeLabel.short(seconds))" : "Recording, \(TimeLabel.short(seconds))")
        }
    }
}

/// The last few seconds of input as mirrored teal bars, newest on the right. Flat while paused.
struct RollingMeter: View {
    @Environment(PhoneAppModel.self) private var model
    var height: CGFloat = RecordingStyle.Meter.pocketHeight

    var body: some View {
        let values = model.levels.values
        let live = model.recorder.state == .recording
        Canvas { context, size in
            let step = RecordingStyle.Meter.barWidth + RecordingStyle.Meter.gap
            let count = max(1, Int(size.width / step))
            let shown = values.suffix(count)
            let start = size.width - CGFloat(shown.count) * step
            for (index, value) in shown.enumerated() {
                let shaped = pow(value, 1.6)
                let bar = max(RecordingStyle.Meter.barWidth, CGFloat(shaped) * size.height)
                let rect = CGRect(x: start + CGFloat(index) * step, y: (size.height - bar) / 2, width: RecordingStyle.Meter.barWidth, height: bar)
                // Older bars fade a little, so the eye goes to now.
                let age = Double(index) / Double(max(1, shown.count - 1))
                let color = live ? PhoneStyle.accent.opacity(0.35 + 0.65 * age) : Color(uiColor: .tertiaryLabel).opacity(0.5)
                context.fill(Path(roundedRect: rect, cornerRadius: RecordingStyle.Meter.barWidth / 2), with: .color(color))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue(live ? "\(Int((values.last ?? 0) * 100)) percent" : "Paused")
    }
}

/// "● Recording" with the conversation's title, or "Paused". The dot is the screen's one red mark
/// besides the clock and Stop.
struct RecordingStatusHeader: View {
    @Environment(PhoneAppModel.self) private var model
    var showsTitle = true
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        let recorder = model.recorder
        VStack(alignment: alignment, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(recorder.state == .recording ? PhoneStyle.Ink.record : Color(uiColor: .tertiaryLabel))
                    .frame(width: 9, height: 9)
                Text(phaseTitle)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(recorder.state == .recording ? PhoneStyle.Ink.record : PhoneStyle.Ink.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                if let route = recorder.inputRoute, recorder.isCapturing {
                    Text("· \(recorder.isMicrophoneSilent ? "Microphone silent" : route.name)")
                        .font(.footnote)
                        .foregroundStyle(recorder.isMicrophoneSilent ? PhoneStyle.Ink.warning : PhoneStyle.Ink.meta)
                        .lineLimit(1)
                }
            }
            if showsTitle {
                Text(recorder.title.isEmpty ? "New conversation" : recorder.title)
                    .font(PhoneStyle.Typeface.title(20))
                    .foregroundStyle(PhoneStyle.Ink.title)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
        .accessibilityElement(children: .combine)
    }

    private var phaseTitle: String {
        switch model.recorder.state {
        case .starting: return "Starting"
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .stopping: return "Saving"
        case .idle: return "Saved"
        }
    }
}

/// While a Mac records this conversation too: "Also recording on Studio Mac". Otherwise, when a
/// paired Mac is connected and free, the offer to record there too.
struct MultipointStatus: View {
    @Environment(PhoneAppModel.self) private var model
    var compact = false

    var body: some View {
        if let line = model.multipointLine {
            HStack(spacing: 6) {
                Image(systemName: "macbook.and.iphone")
                    .imageScale(.small)
                    .foregroundStyle(PhoneStyle.Ink.secondary)
                if model.multipoint?.recordingMacs.isEmpty == false || model.multipoint?.isMacLed == true {
                    Circle().fill(PhoneStyle.Ink.record).frame(width: 6, height: 6)
                }
                Text(line)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(PhoneStyle.Ink.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RecordingStyle.quietFill, in: Capsule())
            .accessibilityElement(children: .combine)
        } else if let mac = model.macsToRecordWith.first {
            Button {
                Task { await model.recordOnMac(mac.id) }
            } label: {
                Label(compact ? "Also record on \(mac.name)" : "Record on \(mac.name) too", systemImage: "macbook.and.iphone")
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
            }
            .buttonStyle(.glass)
            .foregroundStyle(PhoneStyle.Ink.link)
            .accessibilityHint("Asks \(mac.name) to record this conversation as well")
        }
    }
}

/// Bookmark: amber, with the count. Bounces when it lands, so it's felt without looking.
struct BookmarkControl: View {
    @Environment(PhoneAppModel.self) private var model
    var height: CGFloat = RecordingStyle.Control.pocketHeight

    var body: some View {
        let count = model.recorder.bookmarkCount
        Button {
            Task { try? await model.addBookmark() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bookmark.fill")
                    .symbolEffect(.bounce, value: count)
                Text("Bookmark")
                if count > 0 {
                    Text("\(count)")
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(PhoneStyle.bookmark.opacity(0.2), in: Capsule())
                        .contentTransition(.numericText())
                }
            }
            .font(.headline)
            .foregroundStyle(PhoneStyle.bookmark)
            .frame(maxWidth: .infinity, minHeight: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.roundedRectangle(radius: RecordingStyle.Control.corner))
        .disabled(!model.recorder.isCapturing || model.recorder.state == .starting)
        .sensoryFeedback(.impact(weight: .medium), trigger: count)
        .accessibilityLabel(count > 0 ? "Bookmark, \(count) so far" : "Bookmark")
    }
}

/// Take Photo while recording: the photo joins the recording at its shutter moment, like a bookmark.
struct CameraControl: View {
    @Environment(PhoneAppModel.self) private var model
    var size: CGFloat = 44
    @State private var showingCamera = false

    var body: some View {
        let count = model.recorder.photos.count
        Button { showingCamera = true } label: {
            Image(systemName: "camera")
                .font(.system(size: size * 0.4, weight: .medium))
                .foregroundStyle(PhoneStyle.Ink.title)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .disabled(!CameraPicker.isAvailable || !model.recorder.isCapturing || model.recorder.state == .starting)
        .sensoryFeedback(.success, trigger: count)
        .accessibilityLabel(count > 0 ? "Take Photo, \(count) so far" : "Take Photo")
        .cameraCover(isPresented: $showingCamera) { photo in Task { await model.addPhoto(photo) } }
    }
}

/// Stop: the red control. Its own colours, so it reads as Stop in either appearance.
struct StopControl: View {
    @Environment(PhoneAppModel.self) private var model
    var height: CGFloat = RecordingStyle.Control.pocketHeight

    var body: some View {
        Button {
            Task { try? await model.stopRecording() }
        } label: {
            HStack(spacing: 8) {
                if model.recorder.state == .stopping || model.isFiling {
                    ProgressView().tint(.white)
                    Text("Saving")
                } else {
                    Image(systemName: "stop.fill")
                    Text("Stop")
                }
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: height)
            .contentShape(Rectangle())
        }
        // Red glass with its own colours, so it reads as Stop in either appearance and matches Bookmark's shape.
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.roundedRectangle(radius: RecordingStyle.Control.corner))
        .tint(PhoneStyle.Ink.recordFill)
        .disabled(model.recorder.state == .stopping || model.isFiling)
        .sensoryFeedback(.success, trigger: model.isFiling)
        .accessibilityLabel("Stop recording")
    }
}

/// The recording is paused: what happened, and Resume. One quiet box; Stop stays where it was.
struct PausedPanel: View {
    @Environment(PhoneAppModel.self) private var model
    var large = false

    var body: some View {
        let recorder = model.recorder
        VStack(alignment: .leading, spacing: large ? 14 : 10) {
            Label(headline, systemImage: "pause.circle.fill")
                .font(large ? .title3.weight(.semibold) : .headline)
                .foregroundStyle(PhoneStyle.Ink.warning)
            Text(message)
                .font(large ? .body : .subheadline)
                .foregroundStyle(PhoneStyle.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { try? await model.resumeRecording() }
            } label: {
                HStack(spacing: 8) {
                    Circle().fill(PhoneStyle.Ink.record).frame(width: 12, height: 12)
                    Text("Resume Recording")
                }
                .font(.headline)
                .foregroundStyle(PhoneStyle.Ink.title)
                .frame(maxWidth: .infinity, minHeight: large ? 56 : 50)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.roundedRectangle(radius: 16))
            .disabled(!recorder.canResume)
            .opacity(recorder.canResume ? 1 : 0.55)
        }
        .padding(large ? 20 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RecordingStyle.attentionFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    /// iOS doesn't say what interrupted; without a reason (a muted or unplugged microphone gives
    /// one) it's almost always a call.
    private var isCall: Bool {
        model.recorder.state == .paused(.interruption) && model.recorder.pauseMessage == PhoneRecorder.unspecifiedInterruption
    }

    private var headline: String {
        switch model.recorder.state {
        case .paused(.interruption): return isCall ? "Paused for a call" : "Paused"
        case .paused(.inputFailed): return "The microphone stopped"
        default: return "Paused"
        }
    }

    private var message: String {
        let recorder = model.recorder
        if recorder.canResume {
            return isCall ? "The call has ended. Everything so far is saved; resume when you're ready."
                : (recorder.pauseMessage ?? "Everything so far is saved.") + " Resume when you're ready."
        }
        return isCall ? "Everything so far is saved. Recording can continue when the call ends."
            : (recorder.pauseMessage ?? "Everything so far is saved.")
    }
}

/// The conversation so far on one line: bookmarks in amber and notes in ink at their times, with
/// "now" at the right edge.
struct LiveTimelineBar: View {
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        let recorder = model.recorder
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            // The conversation's timeline keeps running through a pause, so the bar runs to now.
            let elapsed = max(1, recorder.elapsedTime)
            let notes = NoteTimeline.paragraphTimes(anchors: recorder.timedNotes, text: recorder.notes).compactMap { $0 }
            VStack(spacing: 4) {
                GeometryReader { proxy in
                    let width = proxy.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(RecordingStyle.quietFill)
                        if let paused = recorder.pausedAt {
                            // The pause so far, in the colour of what needs you.
                            UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 2, bottomTrailingRadius: 7, topTrailingRadius: 7)
                                .fill(PhoneStyle.Ink.warning.opacity(0.35))
                                .frame(width: max(6, width * (1 - min(1, paused / elapsed))))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        ForEach(Array(notes.enumerated()), id: \.offset) { _, time in
                            Capsule().fill(PhoneStyle.Ink.meta)
                                .frame(width: 2, height: proxy.size.height * 0.45)
                                .offset(x: min(width - 2, width * time / elapsed))
                        }
                        ForEach(recorder.highlights) { mark in
                            Capsule().fill(PhoneStyle.bookmark)
                                .frame(width: 3, height: proxy.size.height)
                                .offset(x: min(width - 3, width * mark.time / elapsed))
                        }
                        Circle().fill(recorder.state == .recording ? PhoneStyle.Ink.record : PhoneStyle.Ink.faint)
                            .frame(width: 8, height: 8)
                            .offset(x: width - 8)
                    }
                }
                .frame(height: 14)
                HStack {
                    Text("0:00")
                    Spacer()
                    Text(notesSummary(notes.count))
                    Spacer()
                    Text(TimeLabel.short(recorder.elapsedTime))
                }
                .font(PhoneStyle.Typeface.marginTime)
                .foregroundStyle(PhoneStyle.Ink.meta)
            }
            .accessibilityElement()
            .accessibilityLabel("Timeline")
            .accessibilityValue("\(recorder.bookmarkCount) bookmarks, \(notes.count) notes, \(TimeLabel.short(recorder.elapsedTime)) recorded")
        }
    }

    private func notesSummary(_ notes: Int) -> String {
        let marks = model.recorder.bookmarkCount
        var parts: [String] = []
        if notes > 0 { parts.append(notes == 1 ? "1 note" : "\(notes) notes") }
        if marks > 0 { parts.append(marks == 1 ? "1 bookmark" : "\(marks) bookmarks") }
        return parts.joined(separator: " · ")
    }
}

/// This recording's bookmarks, newest first, each with the note written just before it.
struct BookmarkLog: View {
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        let recorder = model.recorder
        let marks = recorder.highlights.sorted { $0.time > $1.time }
        VStack(alignment: .leading, spacing: 10) {
            Text(marks.isEmpty ? "Bookmarks" : "Bookmarks · \(marks.count)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(PhoneStyle.Ink.meta)
                .textCase(.uppercase)
                .tracking(0.6)
            if marks.isEmpty {
                Text("Tap Bookmark to mark a moment.")
                    .font(.subheadline)
                    .foregroundStyle(PhoneStyle.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(marks) { mark in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "bookmark.fill").foregroundStyle(PhoneStyle.bookmark).imageScale(.small)
                        Text(TimeLabel.short(mark.time))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(PhoneStyle.Ink.body)
                            .frame(minWidth: 40, alignment: .leading)
                        Text(context(for: mark) ?? "")
                            .font(.subheadline)
                            .foregroundStyle(PhoneStyle.Ink.secondary)
                            .lineLimit(1)
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.snappy, value: marks.count)
    }

    /// The paragraph written last before the bookmark.
    private func context(for mark: Highlight) -> String? {
        let recorder = model.recorder
        let paragraphs = NotesTimeline.paragraphs(recorder.notes)
        let times = NoteTimeline.paragraphTimes(anchors: recorder.timedNotes, text: recorder.notes)
        var best: (TimeInterval, String)?
        for (index, text) in paragraphs.enumerated() {
            guard times.indices.contains(index), let time = times[index], time <= mark.time else { continue }
            if best == nil || time >= best!.0 { best = (time, text) }
        }
        return best?.1
    }
}

/// One line when something needs saying (a recovered recording, a Mac that declined).
struct RecordingNotice: View {
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        if let notice = model.notice {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(PhoneStyle.Ink.warning)
                Text(notice).font(.footnote).foregroundStyle(PhoneStyle.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { model.dismissNotice() } label: { Image(systemName: "xmark").font(.footnote.weight(.semibold)) }
                    .foregroundStyle(PhoneStyle.Ink.meta)
                    .accessibilityLabel("Dismiss")
            }
            .transition(.opacity)
        }
    }
}

/// The notes editor while recording. One place to swap in the reading work's margin-time editor at
/// merge; until then the shell's `TimedNotesView` (margin times, bookmarks in the lane).
struct RecordingNotesEditor: View {
    var body: some View {
        TimedNotesView()
    }
}
