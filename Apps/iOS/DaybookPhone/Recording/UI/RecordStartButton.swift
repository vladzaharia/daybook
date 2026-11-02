import DaybookDesign
import SwiftUI
import UniformTypeIdentifiers

/// Starting a recording from the library: the Record control at the thumb, Import Audio beside it,
/// and one line when something needs saying. `LibraryBrowser` places it. When a recording is saved while it's
/// on screen, it says so for a moment (the accent checkmark drawn on, "Saved"), then reads Record again.
struct RecordStartButton: View {
    @Environment(PhoneAppModel.self) private var model
    @State private var importing = false
    @State private var showingDebugSettings = false
    /// The person's own presses of Record, for the tap that answers them.
    @State private var presses = 0
    /// A recording was saved just now: the checkmark and "Saved" stand in for the dot and "Record".
    @State private var savedBeat = false

    var body: some View {
        VStack(spacing: PhoneStyle.Space.s2) {
            RecordingNotice()
                .padding(.horizontal, PhoneStyle.Space.s1)
            if let only = model.recorderOnly, !model.recorder.isActive {
                RecorderOnlyLine(recorder: only.recorderName)
                    .padding(.horizontal, PhoneStyle.Space.s1)
                    .transition(.opacity)
            }
            if model.importing > 0 {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.importing == 1 ? "Importing 1 recording…" : "Importing \(model.importing) recordings…")
                        .font(.footnote)
                        .foregroundStyle(PhoneStyle.Ink.secondary)
                }
                .transition(.opacity)
            }
            HStack(spacing: PhoneStyle.Space.s3) {
                Button {
                    presses += 1
                    // While only a recorder records the shared recording, this iPhone joins it.
                    if model.recorderOnly != nil { Task { await model.recordAlongWithRecorder() } }
                    else { Task { try? await model.startRecording() } }
                } label: {
                    HStack(spacing: 10) {
                        if savedBeat {
                            DoneMark(size: 18).accessibilityHidden(true)
                        } else {
                            Circle().fill(PhoneStyle.Ink.record).frame(width: 16, height: 16)
                                .daybookGlow(PhoneStyle.Ink.record, radius: 3)
                        }
                        Text(model.isFiling ? "Saving…" : savedBeat ? "Saved" : "Record")
                            .font(.title3.weight(.semibold))
                            .contentTransition(.interpolate)
                    }
                    .foregroundStyle(PhoneStyle.Ink.title)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .contentShape(Capsule())
                }
                .daybookControl(.standard, shape: .capsule)
                .disabled(model.recorder.state != .idle || model.isFiling)
                .sensoryFeedback(.impact(weight: .medium), trigger: presses)
                .accessibilityLabel(savedBeat ? "Record. Saved." : "Record")
                .accessibilityHint(model.recorderOnly != nil ? "Records on this iPhone too" : "Starts recording with the microphone")
                // The row stops growing at the status sheet's largest size; past it, a long press shows the label large.
                .accessibilityShowsLargeContentViewer { Label("Record", systemImage: "record.circle") }

                Button { importing = true } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(PhoneStyle.Ink.title)
                        .frame(width: 60, height: 60)
                        .contentShape(Circle())
                }
                .daybookControl(.standard, shape: .circle)
                .accessibilityLabel("Import Audio")
                .accessibilityHint("Adds a recording from Files, such as a voice memo")
                .accessibilityShowsLargeContentViewer()
            }
        }
        .daybookMotion(DaybookMotion.state, value: model.importing)
        .daybookMotion(DaybookMotion.state, value: model.recorderOnly)
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
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.audioTypes, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await model.importFiles(urls) }
        }
        .settingsSheet(isPresented: $showingDebugSettings)
        .task {
            if model.options.showImporter {
                try? await Task.sleep(for: .milliseconds(600))
                importing = true
            }
            // `--open-settings`: Settings at launch, for screenshots.
            if model.options.openSettings != nil, !showingDebugSettings {
                try? await Task.sleep(for: .milliseconds(400))
                showingDebugSettings = true
            }
        }
    }

    /// What Import Audio offers: anything iOS can play as audio.
    static let audioTypes: [UTType] = [.audio, .mpeg4Audio, .mp3, .wav, .aiff]
}

/// Only a recorder records the shared recording: its button started it while Daybook was in the
/// background, where iOS doesn't let this iPhone start its microphone (docs/multipoint.md, "Starting
/// anywhere"). Record, under it, records on this iPhone too.
struct RecorderOnlyLine: View {
    let recorder: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(PhoneStyle.Ink.record).frame(width: 8, height: 8)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                .accessibilityHidden(true)
            Text(Self.text(recorder)).font(.footnote).foregroundStyle(PhoneStyle.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    static func text(_ recorder: String) -> String { "\(recorder) is recording. This iPhone isn’t." }
}
