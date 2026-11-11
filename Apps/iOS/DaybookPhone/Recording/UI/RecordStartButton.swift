import DaybookDesign
import SwiftUI
import UniformTypeIdentifiers

/// Starting a recording from the library: Record, wide, at the thumb, the first of the status sheet's row with Import
/// and Search beside it, at a toolbar's size (`StatusQuickActions`, which says what Record has to say above it). When a
/// recording is saved while it's on screen, it says so for a moment (the accent checkmark drawn on, "Saved"), then reads
/// Record again.
struct RecordStartButton: View {
    @Environment(PhoneAppModel.self) private var model
    /// The person's own presses of Record, for the tap that answers them.
    @State private var presses = 0
    /// A recording was saved just now: the checkmark and "Saved" stand in for the dot and "Record".
    @State private var savedBeat = false
    @ScaledMetric(relativeTo: .body) private var dot: CGFloat = 12

    var body: some View {
        Button {
            presses += 1
            // While only a recorder records the shared recording, this iPhone joins it.
            if model.recorderOnly != nil { Task { await model.recordAlongWithRecorder() } }
            else { Task { try? await model.startRecording() } }
        } label: {
            HStack(spacing: DaybookSpacing.s2) {
                if savedBeat {
                    DoneMark(size: dot + 2).accessibilityHidden(true)
                } else {
                    Circle().fill(DaybookPalette.Ink.record).frame(width: dot, height: dot)
                        .daybookGlow(DaybookPalette.Ink.record, radius: 3)
                }
                Text(model.isFiling ? "Saving…" : savedBeat ? "Saved" : "Record")
                    .font(.body.weight(.semibold))
                    .contentTransition(.interpolate)
                    .lineLimit(1)
                    // On a narrow page at the row's largest size (the left page on its side), smaller, never "Rec…".
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(DaybookPalette.Ink.title)
            .frame(maxWidth: .infinity, minHeight: StatusCompactDetent.control)
            .contentShape(Capsule())
        }
        .daybookControl(.standard, shape: .capsule)
        .disabled(model.recorder.state != .idle || model.isFiling)
        .sensoryFeedback(.impact(weight: .medium), trigger: presses)
        .accessibilityLabel(savedBeat ? "Record. Saved." : "Record")
        .accessibilityHint(model.recorderOnly != nil ? "Records on this iPhone too" : "Starts recording with the microphone")
        // The row stops growing at the sheet's largest size; past it, a long press shows the label large.
        .accessibilityShowsLargeContentViewer { Label("Record", systemImage: "record.circle") }
        .daybookMotion(DaybookMotion.fade, value: savedBeat)
        .onChange(of: model.lastFiling) { _, filing in
            // Saved while this is on screen: one short beat, then Record again.
            guard case .saved? = filing else { return }
            savedBeat = true
        }
        .sensoryFeedback(.success, trigger: savedBeat) { _, saved in saved }
        .task(id: savedBeat) {
            guard savedBeat else { return }
            try? await Task.sleep(for: DaybookMotion.hold)
            savedBeat = false
        }
    }

    /// What Import Audio offers: anything iOS can play as audio.
    static let audioTypes: [UTType] = [.audio, .mpeg4Audio, .mp3, .wav, .aiff]
}

/// What Record has to say, over the status sheet's row, only while there's something: a notice (a recording that
/// couldn't be added, the microphone not allowed), only a recorder recording the shared recording, and an import
/// under way.
struct RecordStartNotices: View {
    @Environment(PhoneAppModel.self) private var model

    /// Whether it has anything to say now; with nothing, the library leaves no room for it.
    static func isShowing(_ model: PhoneAppModel) -> Bool {
        RecordingNotice.isShowing(model) || (model.recorderOnly != nil && !model.recorder.isActive) || model.importing > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DaybookSpacing.s2) {
            RecordingNotice()
            if let only = model.recorderOnly, !model.recorder.isActive {
                RecorderOnlyLine(recorder: only.recorderName)
                    .transition(.opacity)
            }
            if model.importing > 0 {
                HStack(spacing: DaybookSpacing.s2) {
                    ProgressView().controlSize(.small)
                    Text(model.importing == 1 ? "Importing 1 recording…" : "Importing \(model.importing) recordings…")
                        .font(.footnote)
                        .foregroundStyle(DaybookPalette.Ink.secondary)
                    Spacer(minLength: 0)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, DaybookSpacing.s1)
        .daybookMotion(DaybookMotion.state, value: model.importing)
        .daybookMotion(DaybookMotion.state, value: model.recorderOnly)
    }
}

/// Only a recorder records the shared recording: its button started it while Daybook was in the
/// background, where iOS doesn't let this iPhone start its microphone (docs/multipoint.md, "Starting
/// anywhere"). Record, under it, records on this iPhone too.
struct RecorderOnlyLine: View {
    let recorder: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(DaybookPalette.Ink.record).frame(width: 8, height: 8)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                .accessibilityHidden(true)
            Text(Self.text(recorder)).font(.footnote).foregroundStyle(DaybookPalette.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    static func text(_ recorder: String) -> String { "\(recorder) is recording. This iPhone isn’t." }
}
