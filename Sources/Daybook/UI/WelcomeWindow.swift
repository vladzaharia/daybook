import SwiftUI

/// First-run Welcome window (Direction A §5.6): what Daybook is, how carefully it listens, and how to begin.
/// Every step can be skipped with Esc or the close button. Permissions are asked for at first use, not here.
struct WelcomeWindow: View {
    @ObservedObject var state: AppState
    @AppStorage("onboardingCompleted") private var onboardingCompleted = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = WelcomeWindow.initialStep
    @State private var forward = true
    @State private var preset = ModelPreset.recommended
    /// The preset chosen in step 2, named while it downloads.
    @State private var chosen: ModelPreset?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: WelcomeIntro { go(to: 1) }
                case 1: WelcomeQuality(state: state, preset: $preset, download: download) { go(to: 2) }
                default: WelcomeReady(state: state, chosen: chosen, record: record, importAudio: importAudio,
                                      setUpRecorder: setUpRecorder, finish: finish)
                }
            }
            .id(step)
            .transition(reduceMotion ? .opacity : .push(from: forward ? .trailing : .leading))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            WelcomePageIndicator(step: step) { go(to: $0) }
                .padding(.bottom, Space.s5)
        }
        .frame(width: 560, height: 520)
        .background {
            // Esc skips the rest of the welcome from any step, whatever has focus.
            Button("Close", action: finish)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
        .containerBackground(DaybookStyle.paper, for: .window)
        .onDisappear { onboardingCompleted = true }
    }

    /// `--welcome-step 1|2` opens a later step, so every step can be captured without clicking.
    private static var initialStep: Int {
        #if DEBUG
        return LaunchOptions.value(after: "--welcome-step").flatMap(Int.init).map { min(max($0, 0), 2) } ?? 0
        #else
        return 0
        #endif
    }

    private func go(to target: Int) {
        forward = target >= step
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.3)) { step = target }
    }

    private func download() {
        chosen = preset
        preset.apply(to: state)
        state.downloadModels(preset.downloadKeys(in: state))
        go(to: 2)
    }

    private func finish() {
        onboardingCompleted = true
        dismissWindow(id: WindowID.welcome)
    }

    private func openLibrary() {
        openWindow(id: WindowID.library)
        finish()
    }

    /// Opens the main window and starts recording once the library has loaded.
    private func record() {
        openLibrary()
        Task { @MainActor in
            for _ in 0..<50 where !state.isReady { try? await Task.sleep(for: .milliseconds(100)) }
            await state.startRecording()
        }
    }

    private func importAudio() {
        openLibrary()
        Task { @MainActor in state.chooseImport() }
    }

    private func setUpRecorder() {
        state.requestAddDevice()
        openLibrary()
    }
}

// MARK: - Step 1

private struct WelcomeIntro: View {
    let next: () -> Void
    private let points = [
        ("mic.circle.fill", "Record calls, and conversations in the room."),
        ("magnifyingglass.circle.fill", "Read a short summary. Search every word."),
        ("play.circle.fill", "Play back any moment."),
        ("lock.circle.fill", "Transcribed and summarized here. Nothing is uploaded.")
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: Space.s7)
            DaybookMark(size: 96)
            Text("Daybook")
                .font(.system(size: 34, weight: .semibold, design: .serif))
                .foregroundStyle(Ink.title)
                .padding(.top, Space.s4)
            Text("Your conversations, on this Mac.")
                .font(.title3)
                .foregroundStyle(Ink.secondary)
                .padding(.top, Space.s1)
            VStack(alignment: .leading, spacing: Space.s3) {
                ForEach(points, id: \.1) { symbol, point in
                    HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                        Image(systemName: symbol)
                            .font(.system(size: 17))
                            .foregroundStyle(DaybookStyle.brandGradient)
                            .frame(width: 22)
                            .accessibilityHidden(true)
                        Text(point).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(TypeStyle.body())
            .foregroundStyle(Ink.body)
            .frame(width: 360, alignment: .leading)
            .padding(.top, Space.s6)
            Spacer(minLength: Space.s5)
            Button(action: next) {
                Text("Continue").frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            .tint(DaybookStyle.prominentFill)
            .keyboardShortcut(.defaultAction)
            .padding(.bottom, Space.s5)
        }
    }
}

// MARK: - Step 2

private struct WelcomeQuality: View {
    @ObservedObject var state: AppState
    @Binding var preset: ModelPreset
    let download: () -> Void
    let skip: () -> Void

    private var needsDownload: Bool { preset.downloadKeys(in: state).contains { !state.installedModels.contains($0) } }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: Space.s7)
            Text("Choose How Carefully Daybook Listens")
                .font(TypeStyle.docTitleSmall)
                .foregroundStyle(Ink.title)
            Text("Models download once and run on this Mac.")
                .foregroundStyle(Ink.secondary)
                .padding(.top, Space.s2)
            WelcomePresetGroup(state: state, selection: $preset)
                .frame(width: 472)
                .padding(.top, Space.s5)
            Text("You can change this later in Settings.")
                .font(.subheadline)
                .foregroundStyle(Ink.secondary)
                .padding(.top, Space.s3)
            Spacer(minLength: Space.s5)
            Button(action: download) {
                Text(needsDownload ? "Download and Continue" : "Continue").frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            .tint(DaybookStyle.prominentFill)
            .keyboardShortcut(.defaultAction)
            Button("Not Now", action: skip)
                .buttonStyle(.plain)
                .foregroundStyle(Ink.secondary)
                .padding(.top, Space.s3)
                .padding(.bottom, Space.s2)
        }
    }
}

/// Quick, Balanced and Detailed as one radio group, with each total size.
private struct WelcomePresetGroup: View {
    @ObservedObject var state: AppState
    @Binding var selection: ModelPreset

    var body: some View {
        VStack(spacing: 0) {
            ForEach(ModelPreset.allCases) { preset in
                if preset != ModelPreset.allCases.first { Divider().padding(.leading, 44) }
                Button { selection = preset } label: {
                    HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
                        PresetRadio(isOn: selection == preset)
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                        Text(preset.title)
                            .fontWeight(.semibold)
                            .frame(width: 72, alignment: .leading)
                        Text(description(preset))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: Space.s3)
                        Text(ModelSize.format(preset.bytes(in: state)))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, Space.s4)
                    .padding(.vertical, Space.s3)
                    .background(DaybookStyle.accent.opacity(selection == preset ? 0.08 : 0))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .animation(Motion.hover, value: selection)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(selection == preset ? .isSelected : [])
            }
        }
        // Clipped, so the first or last row's selection wash follows the card's corners.
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor))
        }
    }

    private func description(_ preset: ModelPreset) -> String {
        if preset == .recommended { return "Best for this Mac." }
        switch preset {
        case .quick: return "Fastest. Good for clear audio."
        case .balanced: return "Good accuracy for most conversations."
        case .detailed: return "Most accurate. Needs \(preset.recommendedMemoryGB(in: state)) GB of memory."
        }
    }
}

// MARK: - Step 3

private struct WelcomeReady: View {
    @ObservedObject var state: AppState
    let chosen: ModelPreset?
    let record: () -> Void
    let importAudio: () -> Void
    let setUpRecorder: () -> Void
    let finish: () -> Void

    private var ids: [String] {
        chosen?.downloadKeys(in: state) ?? [state.transcriptionModel, state.summaryModel, state.processingPreferences.speakerModelID]
    }
    private var isDownloading: Bool { ModelSize.isDownloading(ids, in: state) }

    private var message: String {
        if isDownloading { return "Start a conversation now. It’s transcribed once the models download." }
        if state.canProcess { return "Start a conversation now." }
        return "Start a conversation now. Download models in Settings to transcribe it."
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: Space.s7)
            Text("You’re Ready")
                .font(TypeStyle.docTitleSmall)
                .foregroundStyle(Ink.title)
            Text(message)
                .foregroundStyle(Ink.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 400)
                .padding(.top, Space.s2)
            if isDownloading {
                let total = ModelSize.bytes(ids, in: state.modelCatalog), done = ModelSize.downloaded(ids, in: state)
                VStack(alignment: .leading, spacing: Space.s2) {
                    HStack {
                        Text(chosen.map { "Downloading \($0.title) models" } ?? "Downloading models")
                        Spacer()
                        Text(Double(done) / Double(max(total, 1)), format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                    }
                    .font(.subheadline)
                    .foregroundStyle(Ink.secondary)
                    ProgressView(value: Double(done) / Double(max(total, 1)))
                        .progressViewStyle(.brand(width: nil))
                        .labelsHidden()
                }
                .frame(width: 400)
                .padding(.top, Space.s6)
            }
            Spacer(minLength: Space.s5)
            HStack(spacing: Space.s3) {
                Button(action: record) {
                    Label("Record", systemImage: "record.circle").frame(minWidth: 96)
                }
                .buttonStyle(.borderedProminent)
                .tint(DaybookStyle.prominentFill)
                .keyboardShortcut(.defaultAction)
                Button(action: importAudio) {
                    Text("Import Audio…").frame(minWidth: 96)
                }
            }
            .controlSize(.extraLarge)
            Spacer(minLength: Space.s5)
            HStack(spacing: Space.s1) {
                Text("Use a wearable or handheld recorder?").foregroundStyle(Ink.secondary)
                Button("Set Up a Recorder…", action: setUpRecorder).buttonStyle(.daybookLink)
            }
            Button("Not Now", action: finish)
                .buttonStyle(.plain)
                .foregroundStyle(Ink.secondary)
                .padding(.top, Space.s3)
                .padding(.bottom, Space.s2)
        }
    }
}

// MARK: - Page indicator

private struct WelcomePageIndicator: View {
    let step: Int
    let go: (Int) -> Void

    var body: some View {
        HStack(spacing: Space.s1) {
            ForEach(0..<3) { index in
                Button { go(index) } label: {
                    Capsule()
                        .fill(index == step ? AnyShapeStyle(DaybookStyle.accent) : AnyShapeStyle(Color.secondary.opacity(0.3)))
                        .frame(width: index == step ? 18 : 7, height: 7)
                        .padding(2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(index > step)
                .accessibilityLabel("Step \(index + 1) of 3")
                .accessibilityAddTraits(index == step ? .isSelected : [])
            }
        }
    }
}
