import CoreAudio
import Foundation

/// The device the Mac plays sound through, classified for echo: headphones cannot feed the call
/// back into the microphone; speakers can.
struct AudioOutputRoute: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// Built-in or external speakers, displays, AirPlay.
        case speakers
        /// Wired headphones, or Bluetooth devices that are known to be worn (AirPods).
        case headphones
        /// Bluetooth audio whose form factor is unknown (headphones or a speaker).
        case bluetooth
        /// USB or other interfaces whose output could be either.
        case external
        /// More than one kind during one recording.
        case mixed
        case unknown
    }
    var kind: Kind
    var deviceName: String
    var transport: String?

    /// Classification from Core Audio properties; pure so it can be tested.
    static func classify(transportType: UInt32, dataSource: UInt32?, name: String) -> Kind {
        let lowered = name.lowercased()
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            // 'hdpn' is the headphone jack; 'ispk' the internal speakers.
            if dataSource == fourCC("hdpn") { return .headphones }
            if dataSource == fourCC("ispk") { return .speakers }
            return lowered.contains("headphone") ? .headphones : .speakers
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            let worn = ["airpods", "headphone", "earbud", "buds", "headset"]
            return worn.contains { lowered.contains($0) } ? .headphones : .bluetooth
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeAirPlay:
            return .speakers
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypeFireWire, kAudioDeviceTransportTypePCI:
            return lowered.contains("headphone") || lowered.contains("headset") ? .headphones : .external
        default:
            return .unknown
        }
    }

    static func fourCC(_ code: String) -> UInt32 {
        code.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

/// Reads and observes the default output device through Core Audio properties. Reading device
/// properties needs no permission and shows no prompt.
final class AudioRouteMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.daybook.audio-route")
    private var listener: AudioObjectPropertyListenerBlock?
    private var dataSourceListener: (device: AudioObjectID, block: AudioObjectPropertyListenerBlock)?
    private var onChange: ((AudioOutputRoute) -> Void)?

    static func currentRoute() -> AudioOutputRoute {
        guard let device = defaultOutputDevice() else { return AudioOutputRoute(kind: .unknown, deviceName: "No output device") }
        return route(for: device)
    }

    static func route(for device: AudioObjectID) -> AudioOutputRoute {
        let transport: UInt32 = CoreAudioProperty.scalar(device, kAudioDevicePropertyTransportType) ?? 0
        let source: UInt32? = CoreAudioProperty.scalar(device, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput)
        let name = CoreAudioProperty.string(device, kAudioObjectPropertyName) ?? "Output"
        return AudioOutputRoute(kind: AudioOutputRoute.classify(transportType: transport, dataSource: source, name: name),
                                deviceName: name, transport: transportName(transport))
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        let device: AudioObjectID? = CoreAudioProperty.scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
        return device.flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    /// Calls `onChange` (on a private queue) whenever the default output device or its data source changes.
    func start(onChange: @escaping (AudioOutputRoute) -> Void) {
        stop()
        self.onChange = onChange
        var address = CoreAudioProperty.address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.routeChanged() }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block) == noErr {
            listener = block
        }
        observeDataSource()
    }

    func stop() {
        if let listener {
            var address = CoreAudioProperty.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        }
        listener = nil
        removeDataSourceListener()
        onChange = nil
    }

    deinit { stop() }

    private func routeChanged() {
        observeDataSource()
        onChange?(Self.currentRoute())
    }

    /// Plugging headphones into the built-in jack changes the data source, not the device.
    private func observeDataSource() {
        removeDataSourceListener()
        guard let device = Self.defaultOutputDevice() else { return }
        var address = CoreAudioProperty.address(kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.onChange?(Self.currentRoute())
        }
        if AudioObjectAddPropertyListenerBlock(device, &address, queue, block) == noErr {
            dataSourceListener = (device, block)
        }
    }

    private func removeDataSourceListener() {
        guard let current = dataSourceListener else { return }
        var address = CoreAudioProperty.address(kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput)
        AudioObjectRemovePropertyListenerBlock(current.device, &address, queue, current.block)
        dataSourceListener = nil
    }

    private static func transportName(_ transport: UInt32) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "bluetooth"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeHDMI: return "hdmi"
        case kAudioDeviceTransportTypeDisplayPort: return "displayport"
        case kAudioDeviceTransportTypeAirPlay: return "airplay"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        default: return "other"
        }
    }
}

/// Small helpers for reading Core Audio object properties.
enum CoreAudioProperty {
    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func scalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var property = address(selector, scope: scope)
        guard AudioObjectHasProperty(object, &property) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.load(as: T.self)
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var property = address(selector)
        guard AudioObjectHasProperty(object, &property) else { return nil }
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [T] {
        var property = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, pointer) == noErr else { return [] }
        let typed = pointer.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: typed, count: Int(size) / MemoryLayout<T>.stride))
    }
}
