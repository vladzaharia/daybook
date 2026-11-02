import DaybookDesign
import SwiftUI

/// The surface for the posture and the moment: the library and reading (`LibraryBrowser`) while
/// nothing is being recorded, and the recorder (`RecorderScreen`) while something is, laid out
/// for pocket (closed), notebook (open), or table (partly open while recording). After a Stop seen on the recorder,
/// the recorder stays for a moment to say Saved, with Open and Keep Recording (`AfterStop`).
///
/// Ownership (docs/iphone.md, phase 2): `LibraryBrowser` and this routing belong to the library and
/// reading work; `RecorderScreen`, `RecordStartButton`, and `SettingsScreen` to the recording,
/// devices, and settings work.
///
/// It owns the `ReadingSession` (where the person is in the library, what's playing), so reading
/// survives folds and recordings, and gives the default `\.audioProvider` the app's library unless
/// the app root injected another provider.
struct RootView: View {
    @Environment(PhoneAppModel.self) private var model
    @Environment(DevicePosture.self) private var posture
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.audioProvider) private var audioProvider
    @State private var reading = ReadingSession()
    /// The recording under way, as it began: what an after-Stop moment is about.
    @State private var recording: AfterStop?
    @State private var afterStop: AfterStop?

    private var showsRecorder: Bool { model.isRecordingActive || afterStop != nil }

    var body: some View {
        let layout = posture.layout(isRecording: model.recorder.isCapturing, horizontalSizeClass: sizeClass)
        Group {
            if showsRecorder {
                RecorderScreen(style: SurfaceStyle(layout), afterStop: model.isRecordingActive ? nil : afterStop) { afterStop = nil }
            } else {
                LibraryBrowser(style: layout == .pocket ? .pocket : .notebook)
            }
        }
        .environment(reading)
        .environment(\.surfaceStyle, SurfaceStyle(layout))
        .environment(\.audioProvider, boundAudioProvider)
        .daybookMotion(DaybookMotion.page, value: layout)
        .daybookMotion(DaybookMotion.page, value: showsRecorder)
        .onChange(of: model.isRecordingActive, initial: true) { _, active in
            if active {
                // Playback stops for a recording, so the microphone doesn't record it.
                reading.player.pause()
                afterStop = nil
                recording = model.recorder.captureID.map { AfterStop(conversationID: $0, title: model.recorder.title,
                                                                      startedAt: model.recorder.startedAt, before: model.lastFiling) }
            } else {
                // Seen stopping (in front, on the recorder): it stays a moment to say what became of it.
                if model.isForeground, let recording { afterStop = recording }
                recording = nil
            }
        }
        // Leaving a conversation: edits to it held back for a burst go now.
        .onChange(of: reading.openID) { left, _ in
            if let left { model.sync.publishHeldEdits(of: left) }
        }
        .onChange(of: reading.reading) { _, isReading in
            if !isReading, let id = reading.openID { model.sync.publishHeldEdits(of: id) }
        }
        .onChange(of: model.recorder.captureID) { _, id in
            guard model.isRecordingActive, let id, recording?.conversationID != id else { return }
            recording = AfterStop(conversationID: id, title: model.recorder.title, startedAt: model.recorder.startedAt, before: model.lastFiling)
        }
        .onChange(of: model.recorder.title) { _, title in recording?.title = title }
        // Where Daybook was asked to open: a notification's tap, Open Conversation, New Note.
        .opensDestinations(reading)
        .modifier(HingeObserver(posture: posture))
        .modifier(GeometryProbe(enabled: model.options.logGeometry, posture: posture))
        .overlay(alignment: .top) {
            if model.options.showPosture {
                Text(posture.summary + (posture.isForced ? " (forced)" : ""))
                    .font(.caption2.weight(.medium)).monospacedDigit()
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.thinMaterial, in: Capsule())
                    .accessibilityHidden(true)
            }
        }
        .tint(PhoneStyle.accent)
        // A first launch: Welcome in the app's place until it's done.
        .phoneWelcome()
    }

    /// The environment's default reads the library's local files once it knows the library; an
    /// injected provider (sync-backed, at the app root) is used as it is.
    private var boundAudioProvider: any AudioProviding {
        #if DEBUG
        // `--simulate-download` and `--simulate-offline` stand in for the app's sync-backed provider too.
        if let simulated = SimulatedAudioProvider.fromArguments(base: LocalAudioProvider(library: model.library)) { return simulated }
        #endif
        if let local = audioProvider as? LocalAudioProvider, local.library == nil { return LocalAudioProvider(library: model.library) }
        return audioProvider
    }
}

/// How a surface lays itself out: one column in the hand, two pages open, glanceable on a table.
enum SurfaceStyle: Equatable {
    case pocket, notebook, table

    init(_ layout: DevicePosture.Layout) {
        switch layout {
        case .pocket: self = .pocket
        case .notebook: self = .notebook
        case .table: self = .table
        }
    }
}

extension EnvironmentValues {
    /// The surface's layout, for what's presented over it: inside a sheet the size class is compact
    /// even across the open iPhone Duo.
    @Entry var surfaceStyle: SurfaceStyle = .pocket
}
