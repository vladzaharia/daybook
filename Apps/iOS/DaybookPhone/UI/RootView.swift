import SwiftUI

/// The surface for the posture and the moment: the library and reading (`LibraryBrowser`) while
/// nothing is being recorded, and the recorder (`RecordingSurface`) while something is, laid out
/// for pocket (closed), notebook (open), or table (partly open while recording).
///
/// Ownership (docs/iphone.md, phase 2): `LibraryBrowser` and this routing belong to the library and
/// reading work; `RecordingSurface`, `RecordStartButton`, and `SettingsScreen` to the recording,
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reading = ReadingSession()

    var body: some View {
        let layout = posture.layout(isRecording: model.recorder.isCapturing, horizontalSizeClass: sizeClass)
        Group {
            if model.isRecordingActive {
                RecordingSurface(style: SurfaceStyle(layout))
            } else {
                LibraryBrowser(style: layout == .pocket ? .pocket : .notebook)
            }
        }
        .environment(reading)
        .environment(\.audioProvider, boundAudioProvider)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .easeInOut(duration: 0.3), value: layout)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .easeInOut(duration: 0.3), value: model.isRecordingActive)
        .onChange(of: model.isRecordingActive) { _, recording in
            // Playback stops for a recording, so the microphone doesn't record it.
            if recording { reading.player.pause() }
        }
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
    }

    /// The environment's default reads the library's local files once it knows the library; an
    /// injected provider (sync-backed, at the app root) is used as it is.
    private var boundAudioProvider: any AudioProviding {
        if let local = audioProvider as? LocalAudioProvider, local.library == nil {
            let bound = LocalAudioProvider(library: model.library)
            #if DEBUG
            if let simulated = SimulatedAudioProvider.fromArguments(base: bound) { return simulated }
            #endif
            return bound
        }
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
