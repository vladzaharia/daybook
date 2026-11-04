import AppKit
import DaybookDesign
import DaybookDevices
import DaybookUI
import SwiftUI

/// First-run Welcome window (Direction A §5.6): what Daybook is, how carefully it listens, allowing the microphone and
/// computer audio, and how to begin. The pages and their words are the iPhone's too (DaybookUI's `WelcomePager`,
/// `WelcomeWords`); each step can be skipped with Esc or the close button.
struct WelcomeWindow: View {
    enum Page: Int, CaseIterable, Hashable {
        case intro, quality, allow, ready
    }

    let state: AppState
    @AppStorage(AppState.Preference.onboardingCompleted) private var onboardingCompleted = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var page = WelcomeWindow.initialPage
    @State private var preset = ModelPreset.recommended
    /// The preset chosen on the quality page, named while it downloads.
    @State private var chosen: ModelPreset?
    @State private var permissions = CapturePermissions()

    var body: some View {
        WelcomePager(pages: Page.allCases, selection: $page) { page in
            switch page {
            case .intro:
                WelcomeIntroPage(device: .mac) { go(to: .quality) }
            case .quality:
                WelcomeQuality(state: state, preset: $preset, freeBytes: WelcomeDiskSpace.forModels(of: state), download: download) {
                    go(to: .allow)
                }
            case .allow:
                WelcomeAllow(permissions: permissions) { go(to: .ready) }
            case .ready:
                WelcomeReady(state: state, chosen: chosen, record: record, importAudio: importAudio, addDevice: addDevice,
                             finish: finish)
            }
        }
        .frame(width: 560, height: 520)
        .environment(\.daybookDensity, .window)
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
        // Back from System Settings, the Allow page says what's allowed now.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in permissions.refresh() }
        .onDisappear { onboardingCompleted = true }
    }

    /// `--welcome-step 1…3` opens a later page, so every page can be captured without clicking.
    private static var initialPage: Page {
        #if DEBUG
        return LaunchOptions.value(after: "--welcome-step").flatMap(Int.init).flatMap(Page.init(rawValue:)) ?? .intro
        #else
        return .intro
        #endif
    }

    private func go(to target: Page) { page = target }

    private func download() {
        chosen = preset
        preset.apply(to: state)
        state.downloadModels(preset.downloadKeys(in: state))
        go(to: .allow)
    }

    private func finish() {
        onboardingCompleted = true
        dismissWindow(id: WindowID.welcome)
    }

    private func openLibrary() {
        openWindow(id: WindowID.library)
        finish()
    }

    /// Opens the main window and starts recording once the library is open; nothing records while a library move
    /// holds the library, which the main window then asks about.
    private func record() {
        openLibrary()
        Task { @MainActor in
            guard await LibraryOpening.opens(state) else { return }
            await state.startRecording()
        }
    }

    private func importAudio() {
        openLibrary()
        Task { @MainActor in
            guard await LibraryOpening.opens(state) else { return }
            state.chooseImport()
        }
    }

    private func addDevice() {
        state.requestAddDevice()
        openLibrary()
    }
}

/// Free space on the disk the models download to, for the quality page's "Needs 16.5 GB · 12 GB free".
enum WelcomeDiskSpace {
    @MainActor static func forModels(of state: AppState) -> Int64? {
        #if DEBUG
        // `--welcome-free-space <bytes>` stands in for the disk, so the page can be seen with too little room.
        if let bytes = LaunchOptions.value(after: "--welcome-free-space").flatMap(Int64.init) { return bytes }
        #endif
        return available(at: state.storageURL.appendingPathComponent("Models", isDirectory: true))
    }

    /// The volume's space for things the person asked for, read where `url` is or, before it exists, its nearest parent.
    static func available(at url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        return (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }
}

// MARK: - Quality

private struct WelcomeQuality: View {
    let state: AppState
    @Binding var preset: ModelPreset
    let freeBytes: Int64?
    let download: () -> Void
    let skip: () -> Void

    private var needsDownload: Bool { WelcomeQualityFit.needed(preset, in: state) > 0 }
    private var fits: Bool { WelcomeQualityFit.fits(preset, in: state, free: freeBytes) }

    var body: some View {
        WelcomeStepPage(title: WelcomeWords.qualityTitle, message: WelcomeWords.qualityMessage) {
            WelcomePresetGroup(state: state, selection: $preset, freeBytes: freeBytes)
                .frame(width: WelcomeMetrics.columnWidth)
                .padding(.top, Space.s5)
            Text(WelcomeWords.changeLater)
                .font(.subheadline)
                .foregroundStyle(Ink.secondary)
                .padding(.top, Space.s3)
        } actions: {
            WelcomePrimaryButton(needsDownload ? WelcomeWords.downloadAndContinue : WelcomeWords.next, action: download)
                .disabled(!fits)
            WelcomeNotNowButton(action: skip)
        }
    }
}

/// Whether a preset's download fits on this Mac: what it still needs (the models not here yet) against the free space.
@MainActor
enum WelcomeQualityFit {
    static func needed(_ preset: ModelPreset, in state: AppState) -> Int64 {
        ModelSize.bytes(preset.downloadKeys(in: state).filter { !state.installedModels.contains($0) }, in: state.modelCatalog)
    }

    static func fits(_ preset: ModelPreset, in state: AppState, free: Int64?) -> Bool {
        guard let free else { return true }
        return needed(preset, in: state) <= free
    }

    /// "Needs 16.5 GB · 12 GB free" for a preset that doesn't fit; nil for one that does.
    static func shortfall(_ preset: ModelPreset, in state: AppState, free: Int64?) -> String? {
        guard let free, !fits(preset, in: state, free: free) else { return nil }
        return WelcomeWords.needsSpace(ModelSize.format(needed(preset, in: state)), free: ModelSize.format(free))
    }
}

/// Quick, Balanced and Detailed as one radio group, with each total size: laid out as Settings › Models › Quality
/// lays them out, with this Mac's recommendation marked the same way. A preset the disk can't hold says so.
private struct WelcomePresetGroup: View {
    let state: AppState
    @Binding var selection: ModelPreset
    let freeBytes: Int64?

    var body: some View {
        WelcomeCard(dividerInset: WelcomeMetrics.radioInset) {
            ForEach(ModelPreset.allCases) { preset in
                let shortfall = WelcomeQualityFit.shortfall(preset, in: state, free: freeBytes)
                Button { selection = preset } label: {
                    HStack(alignment: .center, spacing: Space.s3) {
                        PresetRadio(isOn: selection == preset)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(preset.title).fontWeight(.semibold)
                                if preset == .recommended { ModelLabelChip("Recommended") }
                            }
                            Text(shortfall ?? description(preset))
                                .foregroundStyle(shortfall == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Ink.warning))
                                .fixedSize(horizontal: false, vertical: true)
                        }
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
                .daybookMotion(Motion.hover, value: selection)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(selection == preset ? .isSelected : [])
            }
        }
    }

    /// What each is for. Memory is named only where it rules a Mac out.
    private func description(_ preset: ModelPreset) -> String {
        switch preset {
        case .quick: return "Fastest. Good for clear audio."
        case .balanced: return "Good accuracy for most conversations."
        case .detailed:
            return preset == .recommended ? "Most accurate." : "Most accurate. Needs \(preset.recommendedMemoryGB(in: state)) GB of memory."
        }
    }
}

// MARK: - Allow

/// The microphone and computer audio, with the same Allow… buttons as Settings › Recording › Permissions.
private struct WelcomeAllow: View {
    let permissions: CapturePermissions
    let next: () -> Void

    var body: some View {
        WelcomeStepPage(title: WelcomeWords.allowTitle, message: WelcomeWords.allowMessage(.mac)) {
            WelcomeCard {
                WelcomePermissionRow(WelcomeWords.microphone, symbol: "mic", state: permissions.microphone, device: .mac,
                                     allow: { Task { await permissions.allowMicrophone() } },
                                     openSettings: { permissions.openSettings(for: .microphone) })
                WelcomePermissionRow(WelcomeWords.computerAudio, symbol: "speaker.wave.2", state: permissions.computerAudio,
                                     device: .mac, allow: permissions.allowComputerAudio,
                                     openSettings: { permissions.openSettings(for: .computerAudio) })
            }
            .frame(width: 400)
            .padding(.top, Space.s6)
        } actions: {
            WelcomePrimaryButton(WelcomeWords.next, action: next)
        }
    }
}

// MARK: - Ready

private struct WelcomeReady: View {
    let state: AppState
    let chosen: ModelPreset?
    let record: () -> Void
    let importAudio: () -> Void
    let addDevice: () -> Void
    let finish: () -> Void

    private var ids: [String] {
        chosen?.downloadKeys(in: state) ?? [state.transcriptionModel, state.summaryModel, state.processingPreferences.speakerModelID]
    }
    private var isDownloading: Bool { ModelSize.isDownloading(ids, in: state) }

    var body: some View {
        // The actions sit where the other steps put Continue, rather than floating mid-window; the mark again, closing
        // the welcome it opened.
        WelcomeStepPage(title: WelcomeWords.readyTitle,
                        message: WelcomeWords.readyMessage(downloading: isDownloading, canTranscribe: state.canProcess),
                        showsMark: true) {
            if isDownloading {
                let total = ModelSize.bytes(ids, in: state.modelCatalog), done = ModelSize.downloaded(ids, in: state)
                WelcomeDownloadProgress(WelcomeWords.downloading(chosen?.title), fraction: Double(done) / Double(max(total, 1)))
                    .frame(width: 400)
                    .padding(.top, Space.s6)
            }
        } actions: {
            HStack(spacing: Space.s3) {
                Button(action: record) {
                    RecordControlLabel(title: WelcomeWords.record, size: 15)
                        .frame(minWidth: 96, minHeight: 38)
                        .padding(.horizontal, Space.s4)
                        .contentShape(Rectangle())
                }
                .daybookControl(.standard, shape: .capsule)
                .keyboardShortcut(.defaultAction)
                Button(action: importAudio) {
                    Text(WelcomeWords.importAudio)
                        .font(.system(size: 15, weight: .medium))
                        .frame(minWidth: 96, minHeight: 38)
                        .padding(.horizontal, Space.s4)
                        .contentShape(Rectangle())
                }
                .daybookControl(.standard, shape: .capsule)
            }
            HStack(spacing: Space.s1) {
                Text(WelcomeWords.recorderQuestion).foregroundStyle(Ink.secondary)
                Button(WelcomeWords.addDevice, action: addDevice).buttonStyle(.daybookLink)
            }
            .padding(.top, Space.s2)
            WelcomeNotNowButton(action: finish)
        }
    }
}
