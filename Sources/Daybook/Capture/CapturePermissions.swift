import AppKit
import AVFoundation
import CoreGraphics
import DaybookUI
import Foundation
import Observation

/// The two permissions a recording on this Mac needs, where they stand and how to ask, for Welcome's Allow page in
/// the same terms as Settings › Recording › Permissions: the microphone, asked for in place; and Screen & System Audio
/// Recording (computer audio), which macOS asks for once. After that it's allowed in System Settings, often with a
/// relaunch, so a recording without it records the microphone alone (`RecordingController.computerAudioLeftOut`).
@MainActor
@Observable
final class CapturePermissions {
    /// What the system says and does. Tests pass their own, so nothing asks the real system.
    struct System {
        var microphoneStatus: @MainActor () -> AVAuthorizationStatus
        var requestMicrophone: @MainActor () async -> Bool
        var screenCaptureAllowed: @MainActor () -> Bool
        /// Shows macOS's own prompt, once; returns whether it's allowed now.
        var requestScreenCapture: @MainActor () -> Bool
        var openSettings: @MainActor (PrivacySettings.Pane) -> Void

        static let live = System(
            microphoneStatus: { AVCaptureDevice.authorizationStatus(for: .audio) },
            requestMicrophone: { await AVCaptureDevice.requestAccess(for: .audio) },
            screenCaptureAllowed: { CGPreflightScreenCaptureAccess() },
            requestScreenCapture: { CGRequestScreenCaptureAccess() },
            openSettings: { PrivacySettings.open($0) })
    }

    /// Settings › Recording's key: whether macOS has asked for Screen & System Audio Recording, which it does once.
    static let screenCaptureRequestedKey = "screenCaptureRequested"

    private(set) var microphone: WelcomePermissionState
    private(set) var computerAudio: WelcomePermissionState
    @ObservationIgnored private let system: System
    @ObservationIgnored private let defaults: UserDefaults

    init(system: System = .live, defaults: UserDefaults = LaunchOptions.defaults) {
        self.system = system
        self.defaults = defaults
        microphone = Self.state(microphone: system.microphoneStatus())
        computerAudio = Self.state(screenCaptureAllowed: system.screenCaptureAllowed(),
                                   requested: defaults.bool(forKey: Self.screenCaptureRequestedKey))
    }

    /// Reads both again: after the person comes back from System Settings, say.
    func refresh() {
        microphone = Self.state(microphone: system.microphoneStatus())
        computerAudio = Self.state(screenCaptureAllowed: system.screenCaptureAllowed(),
                                   requested: defaults.bool(forKey: Self.screenCaptureRequestedKey))
    }

    func allowMicrophone() async {
        guard microphone == .askable else { return }
        _ = await system.requestMicrophone()
        refresh()
    }

    /// macOS asks once; its prompt sends the person to System Settings to allow it.
    func allowComputerAudio() {
        guard computerAudio == .askable else { return }
        defaults.set(true, forKey: Self.screenCaptureRequestedKey)
        _ = system.requestScreenCapture()
        refresh()
    }

    func openSettings(for permission: Permission) {
        system.openSettings(permission == .microphone ? .microphone : .screenCapture)
    }

    enum Permission {
        case microphone, computerAudio
    }

    static func state(microphone status: AVAuthorizationStatus) -> WelcomePermissionState {
        switch status {
        case .authorized: return .allowed
        case .notDetermined: return .askable
        default: return .openSettings
        }
    }

    static func state(screenCaptureAllowed: Bool, requested: Bool) -> WelcomePermissionState {
        if screenCaptureAllowed { return .allowed }
        return requested ? .openSettings : .askable
    }
}
