import AVFoundation
import Foundation

/// The microphone route, as the recording's metadata records it.
struct AudioInputRoute: Codable, Equatable, Sendable {
    /// "iPhone Microphone", "AirPods Pro".
    var name: String
    /// `MicrophoneBuiltIn`, `BluetoothHFP`, `MicrophoneWired`, `USBAudio`.
    var portType: String
}

/// What the audio session reports while recording.
enum AudioSessionEvent: Equatable, Sendable {
    /// A call, Siri, an alarm, or another app took the session. Input has stopped.
    case interruptionBegan(reason: String?)
    /// The interruption ended. `shouldResume` is the system's recommendation.
    case interruptionEnded(shouldResume: Bool)
    /// The input or output changed (AirPods connected or removed, a wired mic, the built-in mic).
    case routeChanged(reason: String, input: AudioInputRoute?)
    /// The media server restarted. Every audio object must be rebuilt.
    case mediaServicesReset
}

/// The system audio session, behind a protocol so tests and simulator demos never touch the
/// microphone.
@MainActor
protocol AudioSessionControlling: AnyObject {
    var onEvent: ((AudioSessionEvent) -> Void)? { get set }
    var currentInput: AudioInputRoute? { get }
    func requestRecordPermission() async -> Bool
    /// Configures and activates the session for recording.
    func activate() throws
    func deactivate()
}

/// The real `AVAudioSession`.
///
/// **Category: `.playAndRecord`, mode `.default`, not mixable.**
/// - `.record` would silence the app's own output, so a later start/stop cue or replaying the last
///   seconds would need a category change mid-recording, and changing category reconfigures I/O
///   and drops audio. `.playAndRecord` also gives explicit control of Bluetooth and the speaker.
/// - Mode `.default` keeps the full-band microphone signal. `.voiceChat` and `.videoChat` add
///   call-tuned echo cancellation, AGC, and ducking that can lower the sample rate and fight the
///   Mac's own alignment and echo removal; `.measurement` turns the gain down too far for a room.
/// - Not mixable, so music the phone is playing stops instead of being recorded into the meeting,
///   and the session gets proper interruption begin/end notifications.
/// - Options: `.allowBluetoothHFP` so AirPods can be the microphone, `.bluetoothHighQualityRecording`
///   (iOS 26) for full-band AirPods recording with HFP as the fallback, and `.defaultToSpeaker`
///   so any cue plays from the speaker and the built-in input uses the speakerphone microphone,
///   which suits a phone lying on a table.
/// - `prefersNoInterruptionsFromSystemAlerts`: an incoming call's ringtone doesn't interrupt the
///   recording; answering the call still does. `prefersInterruptionOnRouteDisconnect = false`:
///   removing AirPods falls back to the built-in microphone instead of interrupting.
///
/// Background recording comes from the `audio` background mode: while the session is active and
/// input is running, the app keeps running when the screen locks or another app is in front.
@MainActor
final class LiveAudioSession: AudioSessionControlling {
    var onEvent: ((AudioSessionEvent) -> Void)?
    private let session = AVAudioSession.sharedInstance()
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        // The classic notifications work on iOS 26 and 27; iOS 27's resumption-recommendation API
        // is a drop-in once the deployment target reaches 27.
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            let event = Self.interruptionEvent(note.userInfo)
            MainActor.assumeIsolated { if let event { self?.onEvent?(event) } }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
            let reason = Self.routeChangeReason(note.userInfo)
            MainActor.assumeIsolated {
                guard let self, let reason else { return }
                self.onEvent?(.routeChanged(reason: reason, input: self.currentInput))
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEvent?(.mediaServicesReset) }
        })
    }

    var currentInput: AudioInputRoute? {
        session.currentRoute.inputs.first.map { AudioInputRoute(name: $0.portName, portType: $0.portType.rawValue) }
    }

    func requestRecordPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }

    func activate() throws {
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.allowBluetoothHFP, .bluetoothHighQualityRecording, .defaultToSpeaker])
        try? session.setPreferredSampleRate(RecordingFormat.speech.sampleRate)
        try? session.setPrefersNoInterruptionsFromSystemAlerts(true)
        try? session.setPrefersInterruptionOnRouteDisconnect(false)
        try session.setActive(true)
    }

    func deactivate() {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated private static func interruptionEvent(_ info: [AnyHashable: Any]?) -> AudioSessionEvent? {
        guard let raw = info?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return nil }
        switch type {
        case .began:
            let reason = (info?[AVAudioSessionInterruptionReasonKey] as? UInt).flatMap(AVAudioSession.InterruptionReason.init(rawValue:))
            switch reason {
            case .builtInMicMuted: return .interruptionBegan(reason: "The microphone was muted.")
            case .routeDisconnected: return .interruptionBegan(reason: "The microphone disconnected.")
            default: return .interruptionBegan(reason: nil)
            }
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: info?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            return .interruptionEnded(shouldResume: options.contains(.shouldResume))
        @unknown default:
            return nil
        }
    }

    nonisolated private static func routeChangeReason(_ info: [AnyHashable: Any]?) -> String? {
        guard let raw = info?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return nil }
        switch reason {
        case .newDeviceAvailable: return "new-device"
        case .oldDeviceUnavailable: return "device-removed"
        case .categoryChange: return "category"
        case .override: return "override"
        case .wakeFromSleep: return "wake"
        case .noSuitableRouteForCategory: return "no-route"
        case .routeConfigurationChange: return "configuration"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }
}

/// A session that never touches the hardware: tests send it events, and simulator demos use it
/// with synthetic audio so nothing records the Mac's microphone.
@MainActor
final class ScriptedAudioSession: AudioSessionControlling {
    var onEvent: ((AudioSessionEvent) -> Void)?
    var currentInput: AudioInputRoute? = AudioInputRoute(name: "Synthetic Microphone", portType: "Synthetic")
    var permission = true
    var activationError: Error?
    private(set) var activations = 0
    private(set) var deactivations = 0
    private(set) var isActive = false

    func requestRecordPermission() async -> Bool { permission }

    func activate() throws {
        if let activationError { throw activationError }
        activations += 1
        isActive = true
    }

    func deactivate() {
        deactivations += 1
        isActive = false
    }

    /// Delivers an event as the system would.
    func send(_ event: AudioSessionEvent) {
        if case .interruptionBegan = event { isActive = false }
        if case .routeChanged(_, let input) = event { currentInput = input }
        onEvent?(event)
    }
}
