import CoreBluetooth
import Foundation

/// The Bluetooth radio, in the terms the connection cares about.
public enum RadioState: Equatable {
    case unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn
}

/// Why a connection attempt didn't become usable.
public enum TransportFailure: Equatable {
    /// The system couldn't connect.
    case connectFailed(String?)
    /// Connected, but the recorder doesn't offer the expected service or characteristics.
    case unsupported(String)
}

/// The link to a Soundcore recorder, separated from the protocol so the connection and its tests
/// never need CoreBluetooth. Everything runs on the main actor.
@MainActor
public protocol SoundcoreTransport: AnyObject {
    var events: (any SoundcoreTransportEvents)? { get set }
    var radio: RadioState { get }
    /// Creates the system Bluetooth manager if needed. The first call may ask for permission, so
    /// it's made only when the person sets up the recorder or one is already remembered.
    func activate()
    func startScan()
    func stopScan()
    /// Whether the system still knows this recorder, so it can reconnect without scanning.
    func canReconnect(to id: UUID) -> Bool
    /// Connects, discovers the service and characteristics, and enables notifications. Reports
    /// `transportReady` when the link can carry commands. Without a deadline of its own, a
    /// CoreBluetooth connection waits until the recorder is in range.
    func connect(_ id: UUID)
    func disconnect(_ id: UUID)
    /// Writes one command, split to the link's maximum write size, with flow control.
    func send(_ packet: Data) throws
}

@MainActor
public protocol SoundcoreTransportEvents: AnyObject {
    func transportRadioChanged(_ radio: RadioState)
    func transportDiscovered(_ id: UUID, name: String, rssi: Int)
    func transportReady(_ id: UUID)
    func transportFailed(_ id: UUID, _ failure: TransportFailure)
    func transportDisconnected(_ id: UUID, error: String?)
    func transportReceived(_ data: Data)
}

/// The real link, over CoreBluetooth. It reads and writes only the documented command service.
@MainActor
public final class CoreBluetoothSoundcoreTransport: NSObject, SoundcoreTransport {
    public static let service = CBUUID(string: "020cf5da-0000-1000-8000-00805f9b34fb")
    public static let writeUUID = CBUUID(string: "7777")
    public static let notifyUUID = CBUUID(string: "8888")

    public weak var events: (any SoundcoreTransportEvents)?
    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var writer: CBCharacteristic?
    private var reader: CBCharacteristic?
    private var writes: [(data: Data, last: Bool)] = []
    private var awaitingWrite = false
    private var lastWriteInCommand = false
    private var writeTask: Task<Void, Never>?
    private var scanning = false

    /// iOS state restoration: with an identifier, the system can relaunch the app in the background
    /// for its recorder and hand back the connections it held. Nil on the Mac. Background Bluetooth
    /// on iPhone (the `bluetooth-central` mode, reconnecting) builds on this.
    public let restoreIdentifier: String?
    /// The recorders the system restored, reported before the radio's state. The iPhone app
    /// reconnects from here.
    public var onRestore: (([UUID]) -> Void)?

    public init(restoreIdentifier: String? = nil) {
        self.restoreIdentifier = restoreIdentifier
        super.init()
    }

    public var radio: RadioState {
        switch central?.state {
        case .poweredOn?: return .poweredOn
        case .poweredOff?: return .poweredOff
        case .unauthorized?: return .unauthorized
        case .unsupported?: return .unsupported
        case .resetting?: return .resetting
        default: return .unknown
        }
    }

    public func activate() {
        guard central == nil else { return }
        var options: [String: Any]?
        #if os(iOS)
        if let restoreIdentifier { options = [CBCentralManagerOptionRestoreIdentifierKey: restoreIdentifier] }
        #endif
        central = CBCentralManager(delegate: self, queue: .main, options: options)
    }

    public func startScan() {
        guard let central, central.state == .poweredOn else { return }
        scanning = true
        central.scanForPeripherals(withServices: [Self.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    public func stopScan() {
        guard scanning else { return }
        scanning = false
        central?.stopScan()
    }

    public func canReconnect(to id: UUID) -> Bool {
        guard let central, central.state == .poweredOn else { return false }
        if let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            peripherals[id] = known
            return true
        }
        return false
    }

    public func connect(_ id: UUID) {
        guard let central, let target = peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else {
            events?.transportFailed(id, .connectFailed("The recorder isn’t known to this Mac."))
            return
        }
        if let current = peripheral, current.identifier != id { central.cancelPeripheralConnection(current) }
        resetLink()
        peripheral = target
        target.delegate = self
        central.connect(target)
    }

    public func disconnect(_ id: UUID) {
        if let target = peripheral, target.identifier == id {
            central?.cancelPeripheralConnection(target)
            resetLink()
            peripheral = nil
        } else if let target = peripherals[id] {
            central?.cancelPeripheralConnection(target)
        }
    }

    public func send(_ packet: Data) throws {
        guard let peripheral, peripheral.state == .connected, let writer else { throw SoundcoreError.disconnected }
        let type: CBCharacteristicWriteType = writer.properties.contains(.write) ? .withResponse : .withoutResponse
        let maximum = max(1, peripheral.maximumWriteValueLength(for: type))
        for offset in stride(from: 0, to: packet.count, by: maximum) {
            let end = min(packet.count, offset + maximum)
            writes.append((packet.subdata(in: offset..<end), end == packet.count))
        }
        pumpWrite()
    }

    private func resetLink() {
        writeTask?.cancel(); writeTask = nil
        writes.removeAll(); awaitingWrite = false
        writer = nil; reader = nil
    }

    /// One chunk at a time: with-response writes wait for the acknowledgement, the rest wait for
    /// the link to be ready. Commands are spaced so the recorder can keep up.
    private func pumpWrite() {
        guard writeTask == nil, !awaitingWrite, !writes.isEmpty, let peripheral, let writer else { return }
        let type: CBCharacteristicWriteType = writer.properties.contains(.write) ? .withResponse : .withoutResponse
        if type == .withoutResponse && !peripheral.canSendWriteWithoutResponse { return }
        let next = writes.removeFirst()
        lastWriteInCommand = next.last
        awaitingWrite = type == .withResponse
        peripheral.writeValue(next.data, for: writer, type: type)
        if type == .withoutResponse { scheduleNextWrite(last: next.last) }
    }

    private func scheduleNextWrite(last: Bool) {
        writeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(last ? 500 : 15))
            guard !Task.isCancelled, let self else { return }
            self.writeTask = nil
            self.pumpWrite()
        }
    }

    private func fail(_ target: CBPeripheral, _ failure: TransportFailure) {
        central?.cancelPeripheralConnection(target)
        resetLink()
        peripheral = nil
        events?.transportFailed(target.identifier, failure)
    }
}

extension CoreBluetoothSoundcoreTransport: @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    /// The system relaunched the app and hands back the recorders it was connected or connecting to.
    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        for peripheral in restored { peripherals[peripheral.identifier] = peripheral }
        onRestore?(restored.map(\.identifier))
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn { scanning = false; resetLink() }
        events?.transportRadioChanged(radio)
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        peripherals[peripheral.identifier] = peripheral
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Soundcore Work"
        events?.transportDiscovered(peripheral.identifier, name: String(name.prefix(80)), rssi: RSSI.intValue)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral == self.peripheral else { return }
        peripheral.discoverServices([Self.service])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral == self.peripheral else { return }
        resetLink()
        self.peripheral = nil
        events?.transportFailed(peripheral.identifier, .connectFailed(error?.localizedDescription))
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral == self.peripheral else { return }
        resetLink()
        self.peripheral = nil
        events?.transportDisconnected(peripheral.identifier, error: error?.localizedDescription)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral == self.peripheral else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            fail(peripheral, .unsupported(error?.localizedDescription ?? SoundcoreError.unsupported.localizedDescription))
            return
        }
        peripheral.discoverCharacteristics([Self.writeUUID, Self.notifyUUID], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral == self.peripheral else { return }
        writer = service.characteristics?.first { $0.uuid == Self.writeUUID }
        reader = service.characteristics?.first { $0.uuid == Self.notifyUUID }
        guard error == nil, let writer, let reader,
              writer.properties.contains(.write) || writer.properties.contains(.writeWithoutResponse),
              reader.properties.contains(.notify) || reader.properties.contains(.indicate) else {
            fail(peripheral, .unsupported(error?.localizedDescription ?? SoundcoreError.unsupported.localizedDescription))
            return
        }
        peripheral.setNotifyValue(true, for: reader)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral == self.peripheral, characteristic.uuid == Self.notifyUUID else { return }
        guard error == nil, characteristic.isNotifying else {
            fail(peripheral, .unsupported(error?.localizedDescription ?? "Notifications couldn’t be turned on."))
            return
        }
        events?.transportReady(peripheral.identifier)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral == self.peripheral, characteristic.uuid == Self.notifyUUID, error == nil,
              let data = characteristic.value else { return }
        events?.transportReceived(data)
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral == self.peripheral else { return }
        awaitingWrite = false
        if error != nil { writes.removeAll(); return }
        scheduleNextWrite(last: lastWriteInCommand)
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard peripheral == self.peripheral else { return }
        pumpWrite()
    }
}
