import CoreAudio
import DaybookKit
import Foundation
import Observation

// The Mac's microphones, as the recording chooses among them (`MicrophoneChoice`; docs/capture.md, "Choosing the
// microphone"): the inputs there now, the system default, which ones another app is recording from, and the person's
// choice from Settings › Recording or Floating Notes' input menu. Reading devices needs no permission and never opens a
// microphone.

/// The person's microphone choice, kept in the app's preferences (a `--library` run's own).
struct MicrophonePreferenceStore: @unchecked Sendable {
    static let key = "microphoneChoice"
    /// Posted (on the main queue) when the choice changes, so a recording follows it at once.
    static let changed = Notification.Name("local.daybook.microphone-choice-changed")

    let defaults: UserDefaults

    static var live: MicrophonePreferenceStore { MicrophonePreferenceStore(defaults: LaunchOptions.defaults) }

    func load() -> MicrophoneChoice.Preference {
        guard let data = defaults.data(forKey: Self.key),
              let preference = try? JSONDecoder().decode(MicrophoneChoice.Preference.self, from: data) else { return .automatic }
        return preference
    }

    func save(_ preference: MicrophoneChoice.Preference) {
        guard preference != load() else { return }
        if preference == .automatic {
            defaults.removeObject(forKey: Self.key)
        } else if let data = try? JSONEncoder().encode(preference) {
            defaults.set(data, forKey: Self.key)
        }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}

/// The inputs through Core Audio properties.
enum CoreAudioInputs {
    /// The call tap's private aggregate has input streams too; it's never a microphone.
    static let ownDevicePrefix = "app.daybook."

    /// Every input that could be the system's default input and is alive, in Core Audio's order, with its object ID.
    static func devices() -> [(device: MicrophoneChoice.Device, object: AudioDeviceID)] {
        let objects: [AudioObjectID] = CoreAudioProperty.array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        return objects.compactMap { object in
            guard hasInput(object), let uid = CoreAudioProperty.string(object, kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix(ownDevicePrefix) else { return nil }
            if let alive: UInt32 = CoreAudioProperty.scalar(object, kAudioDevicePropertyDeviceIsAlive), alive == 0 { return nil }
            if let usable: UInt32 = CoreAudioProperty.scalar(object, kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: kAudioObjectPropertyScopeInput),
               usable == 0 { return nil }
            let transport: UInt32 = CoreAudioProperty.scalar(object, kAudioDevicePropertyTransportType) ?? 0
            let name = CoreAudioProperty.string(object, kAudioObjectPropertyName) ?? "Microphone"
            return (MicrophoneChoice.Device(id: uid, name: name, kind: kind(transport: transport)), object)
        }
    }

    /// The inputs now, with the default, the ones another app records from, and `preference`.
    static func snapshot(preference: MicrophoneChoice.Preference) -> MicrophoneChoice.Snapshot {
        let found = devices()
        let defaultObject: AudioObjectID? = CoreAudioProperty.scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)
        return MicrophoneChoice.Snapshot(devices: found.map(\.device),
                                         systemDefault: found.first { $0.object == defaultObject }?.device.id,
                                         runningElsewhere: inUseElsewhere(found),
                                         preference: preference)
    }

    /// The object for a device UID, while it's there.
    static func object(for uid: String) -> AudioDeviceID? {
        let objects: [AudioObjectID] = CoreAudioProperty.array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        return objects.first { CoreAudioProperty.string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    static func kind(transport: UInt32) -> MicrophoneChoice.Device.Kind {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetoothHeadset
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypeFireWire,
             kAudioDeviceTransportTypePCI: return .wired
        default: return .other
        }
    }

    private static func hasInput(_ object: AudioObjectID) -> Bool {
        var address = CoreAudioProperty.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr && size > 0
    }

    /// The inputs another app is recording from. A device runs for playback too, so a running one counts only when
    /// another process has input running on it (`kAudioProcessPropertyDevices`, input scope); when the processes
    /// can't be read, a running device counts.
    static func inUseElsewhere(_ found: [(device: MicrophoneChoice.Device, object: AudioDeviceID)]) -> Set<String> {
        let running = found.filter { (CoreAudioProperty.scalar($0.object, kAudioDevicePropertyDeviceIsRunningSomewhere) as UInt32?) == 1 }
        guard !running.isEmpty else { return [] }
        guard let processes: [AudioObjectID] = try? CoreAudioProperty.readArray(AudioObjectID(kAudioObjectSystemObject),
                                                                                kAudioHardwarePropertyProcessObjectList) else {
            return Set(running.map(\.device.id))
        }
        let me = ProcessInfo.processInfo.processIdentifier
        var recording = Set<AudioDeviceID>()
        for process in processes {
            guard (CoreAudioProperty.scalar(process, kAudioProcessPropertyPID) as pid_t?) != me,
                  (CoreAudioProperty.scalar(process, kAudioProcessPropertyIsRunningInput) as UInt32?) == 1 else { continue }
            recording.formUnion(inputDevices(of: process))
        }
        return Set(running.filter { recording.contains($0.object) }.map(\.device.id))
    }

    private static func inputDevices(of process: AudioObjectID) -> [AudioDeviceID] {
        var address = CoreAudioProperty.address(kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(process, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.stride)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &devices) == noErr else { return [] }
        return Array(devices.prefix(Int(size) / MemoryLayout<AudioDeviceID>.stride))
    }
}

/// The inputs as the microphone source chooses among them, behind a protocol so tests drive the choice without devices.
protocol MicrophoneDevices: AnyObject {
    /// The inputs now, the default, which another app records from, and the person's choice.
    func snapshot() -> MicrophoneChoice.Snapshot
    /// Called on the main queue when an input comes or goes, the default input changes, the followed input stops
    /// being alive, or the person chooses another.
    var onChange: (() -> Void)? { get set }
    /// The input being recorded, whose death (`kAudioDevicePropertyDeviceIsAlive`) is a change; nil stops listening.
    func follow(_ id: String?)
}

/// The live inputs: Core Audio's devices and the stored choice, listened to while a recording follows them.
///
/// Its listeners are added and removed only on the main queue (`follow` hops there, in order), where Core Audio calls
/// them too; `onChange` is behind a lock, since the source sets it from any thread. `@unchecked Sendable` rests on that.
final class CoreAudioMicrophoneDevices: MicrophoneDevices, @unchecked Sendable {
    var onChange: (() -> Void)? {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }
    private let store: MicrophonePreferenceStore
    private let lock = NSLock()
    private var handler: (() -> Void)?
    // Main queue only.
    private var systemListener: AudioObjectPropertyListenerBlock?
    private var alive: (object: AudioDeviceID, block: AudioObjectPropertyListenerBlock)?
    private var preferenceObserver: NSObjectProtocol?

    private static let systemSelectors = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice]

    init(store: MicrophonePreferenceStore = .live) { self.store = store }

    deinit {
        // Nothing else holds it now: a pending `follow` would have kept it alive.
        removeAliveListener()
        removeSystemListeners()
    }

    func snapshot() -> MicrophoneChoice.Snapshot { CoreAudioInputs.snapshot(preference: store.load()) }

    func follow(_ id: String?) {
        DispatchQueue.main.async { [self] in listen(to: id) }
    }

    private func listen(to id: String?) {
        dispatchPrecondition(condition: .onQueue(.main))
        removeAliveListener()
        guard let id else {
            removeSystemListeners()
            return
        }
        addSystemListeners()
        guard let object = CoreAudioInputs.object(for: id) else { return }
        var address = CoreAudioProperty.address(kAudioDevicePropertyDeviceIsAlive)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.changed() }
        if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr { alive = (object, block) }
    }

    private func changed() { onChange?() }

    private func addSystemListeners() {
        guard systemListener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.changed() }
        for selector in Self.systemSelectors {
            var address = CoreAudioProperty.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
        systemListener = block
        preferenceObserver = NotificationCenter.default.addObserver(forName: MicrophonePreferenceStore.changed, object: nil, queue: .main) { [weak self] _ in
            self?.changed()
        }
    }

    private func removeSystemListeners() {
        if let block = systemListener {
            for selector in Self.systemSelectors {
                var address = CoreAudioProperty.address(selector)
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
            }
        }
        systemListener = nil
        if let preferenceObserver { NotificationCenter.default.removeObserver(preferenceObserver) }
        preferenceObserver = nil
    }

    private func removeAliveListener() {
        guard let alive else { return }
        var address = CoreAudioProperty.address(kAudioDevicePropertyDeviceIsAlive)
        AudioObjectRemovePropertyListenerBlock(alive.object, &address, .main, alive.block)
        self.alive = nil
    }
}

/// The input this Mac's recording uses now, for the words that name it (Floating Notes' band); nil while not recording.
@MainActor
@Observable
final class MicrophoneInUse {
    static let shared = MicrophoneInUse()
    private(set) var device: MicrophoneChoice.Device?

    /// Reports from any thread, in order.
    nonisolated static func report(_ device: MicrophoneChoice.Device?) {
        DispatchQueue.main.async { MainActor.assumeIsolated { if shared.device != device { shared.device = device } } }
    }
}
