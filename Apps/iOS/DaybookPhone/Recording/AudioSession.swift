import AVFoundation
import DaybookKit
import Foundation

/// The microphone route, as the recording's metadata records it.
struct AudioInputRoute: Codable, Equatable, Sendable {
    /// "iPhone Microphone", "AirPods Pro".
    var name: String
    /// `MicrophoneBuiltIn`, `BluetoothHFP`, `MicrophoneWired`, `USBAudio`.
    var portType: String
}

/// An input the session can record from: the built-in microphone, AirPods, a USB microphone.
struct AudioInputPort: Equatable, Sendable {
    /// The port's UID.
    var id: String
    var name: String
    /// `AVAudioSession.Port`'s raw value.
    var portType: String
    /// AirPods that can capture the room rather than their wearer (`bluetoothMicrophoneExtension?.farFieldCapture`).
    var supportsFarField = false

    var device: MicrophoneChoice.Device { MicrophoneChoice.Device(id: id, name: name, kind: Self.kind(portType)) }

    static func kind(_ portType: String) -> MicrophoneChoice.Device.Kind {
        switch AVAudioSession.Port(rawValue: portType) {
        case .builtInMic: return .builtIn
        case .bluetoothHFP, .bluetoothLE: return .bluetoothHeadset
        case .headsetMic, .usbAudio, .lineIn: return .wired
        default: return .other
        }
    }
}

/// How the session records from the person's choice of input (`MicrophoneChoice`), worked out before it's applied so
/// tests read it without a device.
///
/// The iPhone can't see other apps' audio, and while it records no other app can either, so Automatic records the
/// built-in microphone with AirPods connected, which iOS would otherwise make the input: a phone on the table then
/// records the room, not the voice of whoever wears them. With no route to read yet, iOS's own default is a wired or USB
/// input when there is one. The resolved input is always the preferred input, so a headset connecting mid-recording
/// doesn't take over. A chosen Bluetooth input that can capture the room does (`.farFieldInput`, iOS 26.2).
struct AudioInputPlan: Equatable, Sendable {
    /// The input to prefer (a port's UID); nil when there's nothing to choose.
    var preferredInput: String?
    /// Far-field capture: chosen AirPods that support it hear the room, not their wearer.
    var farField: Bool

    static func make(inputs: [AudioInputPort], currentInput: String?, preference: MicrophoneChoice.Preference,
                     farFieldAvailable: Bool) -> AudioInputPlan {
        let devices = inputs.map(\.device)
        let systemDefault = currentInput.flatMap { id in devices.contains { $0.id == id } ? id : nil }
            ?? devices.first { $0.kind == .wired }?.id
        guard let chosen = MicrophoneChoice.resolve(devices: devices, systemDefault: systemDefault, preference: preference),
              let port = inputs.first(where: { $0.id == chosen.id }) else { return AudioInputPlan(preferredInput: nil, farField: false) }
        return AudioInputPlan(preferredInput: chosen.id, farField: farFieldAvailable && chosen.kind == .bluetoothHeadset && port.supportsFarField)
    }

    /// The category options: AirPods may be the microphone (full band where they can, HFP otherwise), any cue plays from
    /// the speaker, and far-field when planned.
    var categoryOptions: AVAudioSession.CategoryOptions {
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .bluetoothHighQualityRecording, .defaultToSpeaker]
        if farField, #available(iOS 26.2, *) { options.insert(.farFieldInput) }
        return options
    }

    /// Whether this iOS has far-field Bluetooth capture.
    static var farFieldAvailable: Bool {
        if #available(iOS 26.2, *) { return true } else { return false }
    }
}

/// The person's choice of input, kept between recordings.
struct PhoneMicrophonePreference: @unchecked Sendable {
    static let key = "microphoneChoice"
    let defaults: UserDefaults

    func load() -> MicrophoneChoice.Preference {
        guard let data = defaults.data(forKey: Self.key),
              let preference = try? JSONDecoder().decode(MicrophoneChoice.Preference.self, from: data) else { return .automatic }
        return preference
    }

    func save(_ preference: MicrophoneChoice.Preference) {
        if preference == .automatic { defaults.removeObject(forKey: Self.key) }
        else if let data = try? JSONEncoder().encode(preference) { defaults.set(data, forKey: Self.key) }
    }
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
    /// Whether Daybook may record, without asking.
    var microphonePermission: MicrophonePermission { get }
    func requestRecordPermission() async -> Bool
    /// Configures and activates the session for recording, from the input the person's choice resolves to
    /// (`AudioInputPlan`).
    func activate() throws
    func deactivate()
    /// Records from the input the choice resolves to now (a headset came or went), with far-field to match.
    func applyInputChoice()
    /// The person chose the current input in the system's input picker: it's remembered, by device and by kind, for
    /// the recordings after this one, and far-field follows it.
    func rememberCurrentInput()
}

/// Whether the person has let Daybook use the microphone. Never asked, iOS asks with Daybook on
/// screen, so a start from the background continues in front first (`StartRecordingIntent`).
enum MicrophonePermission: Equatable, Sendable {
    case notAsked
    case allowed
    case denied
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
///   which suits a phone lying on a table. `.farFieldInput` (iOS 26.2) when the person chose AirPods
///   that can capture the room.
/// - The input: the person's choice (`AudioInputPlan`), the built-in microphone with AirPods connected
///   unless the person picked them, set as the preferred input before the session activates.
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
    private let preference: PhoneMicrophonePreference
    /// The input Daybook last made the preferred one.
    private var pinned: String?
    private var observers: [NSObjectProtocol] = []

    init(preferences: UserDefaults = .standard) {
        preference = PhoneMicrophonePreference(defaults: preferences)
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

    var microphonePermission: MicrophonePermission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .allowed
        case .denied: return .denied
        default: return .notAsked
        }
    }

    func requestRecordPermission() async -> Bool {
        switch microphonePermission {
        case .allowed: return true
        case .denied: return false
        case .notAsked: return await AVAudioApplication.requestRecordPermission()
        }
    }

    func activate() throws {
        // The category first, so the inputs are listed; the preferred input before activating, so AirPods nobody chose
        // never switch to their hands-free profile for a moment.
        try configure(AudioInputPlan(preferredInput: nil, farField: false))
        configureInput()
        try? session.setPreferredSampleRate(RecordingFormat.speech.sampleRate)
        try? session.setPrefersNoInterruptionsFromSystemAlerts(true)
        try? session.setPrefersInterruptionOnRouteDisconnect(false)
        try session.setActive(true)
    }

    func deactivate() {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    func applyInputChoice() { configureInput() }

    func rememberCurrentInput() {
        // The picker sets the preferred input, and the route follows a moment later; a preferred input that's still the
        // one Daybook set means the route says what was picked.
        let preferred = session.preferredInput?.uid
        guard let id = (preferred != pinned ? preferred : nil) ?? session.currentRoute.inputs.first?.uid,
              let input = inputs.first(where: { $0.id == id }) else { return }
        // Opening the picker and leaving the input as it was chooses nothing.
        if input.id != plan().preferredInput { preference.save(.device(input.device)) }
        configureInput()
    }

    /// The inputs the category offers now.
    private var inputs: [AudioInputPort] {
        (session.availableInputs ?? []).map { port in
            AudioInputPort(id: port.uid, name: port.portName, portType: port.portType.rawValue,
                           supportsFarField: port.bluetoothMicrophoneExtension?.farFieldCapture.isSupported ?? false)
        }
    }

    private func plan() -> AudioInputPlan {
        AudioInputPlan.make(inputs: inputs, currentInput: session.currentRoute.inputs.first?.uid,
                            preference: preference.load(), farFieldAvailable: AudioInputPlan.farFieldAvailable)
    }

    /// Prefers the input the choice resolves to, and sets far-field to match.
    private func configureInput() {
        let plan = plan()
        // Far-field is a refinement: a route that won't take it records as before.
        if (try? configure(plan)) == nil, plan.farField { try? configure(AudioInputPlan(preferredInput: plan.preferredInput, farField: false)) }
        let port = plan.preferredInput.flatMap { id in session.availableInputs?.first { $0.uid == id } }
        if let port, session.preferredInput?.uid != port.uid { try? session.setPreferredInput(port) }
        if let port { pinned = port.uid }
    }

    private func configure(_ plan: AudioInputPlan) throws {
        let options = plan.categoryOptions
        guard session.category != .playAndRecord || session.mode != .default || session.categoryOptions != options else { return }
        try session.setCategory(.playAndRecord, mode: .default, options: options)
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
    /// The person's answer, once asked.
    var permission = true
    /// Whether they've been asked; until then, asking gives `permission`.
    var permissionAsked = true
    var activationError: Error?
    private(set) var activations = 0
    private(set) var deactivations = 0
    private(set) var isActive = false
    /// The inputs the session offers, as a test sets them; none leaves `currentInput` as it is.
    var availableInputs: [AudioInputPort] = []
    /// Whether this iOS has far-field capture (iOS 26.2), as a test sets it.
    var farFieldAvailable = true
    /// The person's choice of input, as the live session keeps it.
    var preference = MicrophoneChoice.Preference.automatic
    /// Each input plan applied, in order: the preferred input and far-field.
    private(set) var plans: [AudioInputPlan] = []

    var microphonePermission: MicrophonePermission { !permissionAsked ? .notAsked : permission ? .allowed : .denied }

    /// The category options the last plan set.
    var categoryOptions: AVAudioSession.CategoryOptions { (plans.last ?? AudioInputPlan(preferredInput: nil, farField: false)).categoryOptions }

    func requestRecordPermission() async -> Bool {
        permissionAsked = true
        return permission
    }

    func activate() throws {
        if let activationError { throw activationError }
        activations += 1
        isActive = true
        applyInputChoice()
    }

    func deactivate() {
        deactivations += 1
        isActive = false
    }

    func applyInputChoice() {
        guard !availableInputs.isEmpty else { return }
        let plan = AudioInputPlan.make(inputs: availableInputs, currentInput: currentPort?.id, preference: preference,
                                       farFieldAvailable: farFieldAvailable)
        plans.append(plan)
        // iOS records from the preferred input.
        if let port = availableInputs.first(where: { $0.id == plan.preferredInput }) {
            currentInput = AudioInputRoute(name: port.name, portType: port.portType)
        }
    }

    func rememberCurrentInput() {
        guard let input = currentPort else { return }
        if input.id != plans.last?.preferredInput { preference = .device(input.device) }
        applyInputChoice()
    }

    private var currentPort: AudioInputPort? {
        availableInputs.first { $0.name == currentInput?.name && $0.portType == currentInput?.portType }
    }

    /// Delivers an event as the system would.
    func send(_ event: AudioSessionEvent) {
        if case .interruptionBegan = event { isActive = false }
        if case .routeChanged(_, let input) = event { currentInput = input }
        onEvent?(event)
    }

    /// The person picks `input` in the system's input picker: iOS records from it at once.
    func pick(_ input: AudioInputPort) {
        send(.routeChanged(reason: "override", input: AudioInputRoute(name: input.name, portType: input.portType)))
    }
}
