import Combine
import CoreBluetooth
import Foundation
import AVFoundation

struct DiscoveredSoundcore: Identifiable {
    let id: UUID
    var name: String
    var signal: Int
}

/// Experimental direct BLE integration. Initialization never starts scanning,
/// records audio, changes pairing, or prompts for Bluetooth permission.
@MainActor
final class SoundcoreController: NSObject, ObservableObject {
    @Published private(set) var devices: [DiscoveredSoundcore] = []
    @Published private(set) var status = "Connect a nearby Soundcore Work to read its status."
    @Published private(set) var isScanning = false
    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    @Published private(set) var connectedName: String?
    @Published private(set) var deviceInfo: SoundcoreDeviceInfo?
    @Published private(set) var files: [SoundcoreRecording] = []
    @Published private(set) var error: String?
    @Published private(set) var transferProgress: Double?
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var encryptionReady = false
    @Published private(set) var isReceivingLive = false
    @Published private(set) var liveTranscript = ""
    @Published private(set) var livePreviewStatus = ""
    var onRecordingReady: ((URL) -> Void)?
    /// Application-provided local ASR. A separate runtime avoids interrupting
    /// final meeting processing; no network or model download is initiated here.
    var transcribeLiveAudio: ((URL) async throws -> String)?

    private static let service = CBUUID(string: "020cf5da-0000-1000-8000-00805f9b34fb")
    private static let writeUUID = CBUUID(string: "7777")
    private static let notifyUUID = CBUUID(string: "8888")
    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var pendingScan = false
    private var packetBuffer = SoundcorePacketBuffer()
    private var scanTimeout: Task<Void, Never>?
    private var connectionTimeout: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var transferTimeout: Task<Void, Never>?
    private var writes: [(data: Data, last: Bool)] = []
    private var awaitingWrite = false
    private var lastWriteInCommand = false
    private let crypto = SoundcoreCrypto()
    private var pendingDownload: SoundcoreRecording?
    private var pendingIsLive = false
    private var download: Download?
    private var filePage: UInt16 = 0
    private var liveRequested = false
    private var liveSamples: [Float] = []
    private var previewTask: Task<Void, Never>?
    private var liveSession = UUID()

    private struct Download {
        let recording: SoundcoreRecording
        let url: URL
        let isLive: Bool
        var decoder: SoundcoreOpusDecoder?
        var key: SoundcoreFileKey?
        var expectedBytes: UInt64
        var receivedBytes: UInt64 = 0
        var nextSequence: UInt32?
        var lastSlice: SoundcoreAudioSlice?
    }

    func scan() {
        error = nil; pendingScan = true
        if central == nil { central = CBCentralManager(delegate: self, queue: .main); return }
        beginScanIfReady()
    }

    func stopScan() {
        pendingScan = false; central?.stopScan(); scanTimeout?.cancel(); isScanning = false
    }

    func connect(_ device: DiscoveredSoundcore) {
        guard let selected = peripherals[device.id], central?.state == .poweredOn else { return }
        disconnect()
        error = nil; peripheral = selected; selected.delegate = self
        connectedName = device.name; isConnecting = true; status = "Connecting to \(device.name)…"
        central?.connect(selected)
        connectionTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, self.isConnecting else { return }
            self.error = "Soundcore did not finish connecting. Wake the device and close other apps using its Bluetooth connection."
            self.disconnect()
        }
    }

    func disconnect() {
        stopScan(); connectionTimeout?.cancel(); writeTask?.cancel(); transferTimeout?.cancel()
        writes.removeAll(); awaitingWrite = false; writeCharacteristic = nil; notifyCharacteristic = nil
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil; isConnected = false; isConnecting = false; connectedName = nil
        deviceInfo = nil; files = []; packetBuffer.reset(); crypto.reset(); encryptionReady = false
        discardDownload(); status = "Disconnected"
    }

    func refreshStatus() { perform { try enqueue(type: 0x01, command: 0x01) } }

    func listFiles() {
        guard transferProgress == nil else { return }
        files = []; filePage = 0
        perform { try enqueue(type: 0x1b, command: 0x0e, payload: Data([0,0])) }
    }

    func startRecording() {
        perform { try enqueue(type: 0x18, command: 0x82, payload: Data([1])); status = "Start requested; awaiting device confirmation" }
    }

    func pauseRecording() {
        perform { try enqueue(type: 0x18, command: 0x82, payload: Data([2])); status = "Pause requested; awaiting device confirmation" }
    }

    func downloadRecording(_ recording: SoundcoreRecording) {
        guard download == nil, pendingDownload == nil else { return }
        error = nil
        perform {
            guard isConnected else { throw SoundcoreError.disconnected }
            pendingDownload = recording; pendingIsLive = false; transferProgress = 0
            if crypto.isReady { try requestDownload() }
            else {
                status = "Establishing local audio encryption session…"
                try enqueue(type: 0x2e, command: 0x01, payload: crypto.publicKey)
                resetTransferTimeout()
            }
        }
    }

    func startLiveCapture() {
        guard download == nil, pendingDownload == nil, !isReceivingLive else { return }
        guard isConnected, deviceInfo?.isRecording == true else {
            error = "Start recording on the Soundcore first, then receive its live audio."; return
        }
        error = nil; liveRequested = true; isReceivingLive = true; liveSession = UUID()
        liveTranscript = ""; livePreviewStatus = "Waiting for live audio…"; liveSamples = []
        transferProgress = 0
        perform {
            try enqueue(type: 0x1b, command: 0x0e, payload: Data([0,0]))
            status = "Finding the active device recording…"; resetTransferTimeout()
        }
    }

    func stopLiveCapture() {
        perform {
            try enqueue(type: 0x1a, command: 0x11, payload: Data([1]))
            if download?.receivedBytes ?? 0 > 0 { try finishDownload() }
            else { discardDownload() }
            status = "Live reception stopped. Device recording is unchanged."
        }
    }

    func cancelDownload() {
        discardDownload()
        // This stops transport only; it does not delete or stop the device recording.
        perform { try enqueue(type: 0x1a, command: 0x11, payload: Data([1])); status = "Transfer cancelled" }
    }

    private func beginScanIfReady() {
        guard pendingScan, let central else { return }
        switch central.state {
        case .poweredOn:
            devices = []; peripherals = [:]; isScanning = true; status = "Scanning for Soundcore Work…"
            central.scanForPeripherals(withServices: [Self.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            scanTimeout?.cancel()
            scanTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self else { return }
                self.stopScan()
                if self.devices.isEmpty { self.status = "No Soundcore found. Wake the device and bring it near this Mac." }
            }
        case .unauthorized: error = "Allow Daybook to use Bluetooth in System Settings → Privacy & Security → Bluetooth."; pendingScan = false
        case .poweredOff: error = "Turn on Bluetooth to discover Soundcore Work."; pendingScan = false
        case .unsupported: error = "Bluetooth Low Energy is unavailable on this Mac."; pendingScan = false
        default: status = "Waiting for Bluetooth…"
        }
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation() }
        catch {
            self.error = error.localizedDescription
            if download != nil || pendingDownload != nil || isReceivingLive { discardDownload() }
        }
    }

    private func enqueue(type: UInt8, command: UInt8, payload: Data = Data()) throws {
        guard isConnected, let peripheral, let characteristic = writeCharacteristic else { throw SoundcoreError.disconnected }
        let packet = try SoundcorePacket.command(type: type, id: command, payload: payload)
        let writeType: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        let maximum = max(1, peripheral.maximumWriteValueLength(for: writeType))
        for offset in stride(from: 0, to: packet.count, by: maximum) {
            let end = min(packet.count, offset + maximum)
            writes.append((packet.subdata(in: offset..<end), end == packet.count))
        }
        pumpWrite()
    }

    private func pumpWrite() {
        guard writeTask == nil, !awaitingWrite, !writes.isEmpty,
              let peripheral, let characteristic = writeCharacteristic, isConnected else { return }
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        if type == .withoutResponse && !peripheral.canSendWriteWithoutResponse { return }
        let next = writes.removeFirst(); lastWriteInCommand = next.last
        awaitingWrite = type == .withResponse
        peripheral.writeValue(next.data, for: characteristic, type: type)
        if type == .withoutResponse { scheduleNextWrite(last: next.last) }
    }

    private func scheduleNextWrite(last: Bool) {
        writeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(last ? 500 : 15))
            guard !Task.isCancelled, let self else { return }
            self.writeTask = nil; self.pumpWrite()
        }
    }

    private func receive(_ packet: SoundcorePacket) throws {
        switch (packet.type, packet.command) {
        case (0x01, 0x01):
            guard packet.succeeded else { throw SoundcoreError.rejected }
            deviceInfo = try SoundcoreDeviceInfo.parse(packet.payload); status = "Connected — status updated"
        case (0x01, 0x03):
            let b = [UInt8](packet.payload); guard b.count >= 2 else { throw SoundcoreError.invalidPacket }
            if deviceInfo == nil { deviceInfo = SoundcoreDeviceInfo() }
            deviceInfo?.microphoneBattery = SoundcoreDeviceInfo.battery(b[0]); deviceInfo?.caseBattery = SoundcoreDeviceInfo.battery(b[1])
        case (0x01, 0x04):
            let b = [UInt8](packet.payload); guard b.count >= 2 else { throw SoundcoreError.invalidPacket }
            if deviceInfo == nil { deviceInfo = SoundcoreDeviceInfo() }
            deviceInfo?.microphoneCharging = b[0] == 1; deviceInfo?.caseCharging = b[1] == 1
        case (0x18, 0x82):
            if let recordingStatus = packet.payload.first, recordingStatus <= 2 {
                if deviceInfo == nil { deviceInfo = SoundcoreDeviceInfo() }
                deviceInfo?.isRecording = recordingStatus == 1
            } else if !packet.succeeded { throw SoundcoreError.rejected }
            status = "Recording control accepted; refreshing device status"; refreshStatus()
        case (0x1a, 0x0e), (0x1b, 0x0e):
            if !packet.succeeded && packet.type == 0x1b {
                try enqueue(type: 0x1a, command: 0x0e, payload: Data([0,0])); return
            }
            guard packet.succeeded else { throw SoundcoreError.rejected }
            let page = try SoundcoreRecording.parseList(packet)
            if liveRequested, download == nil, pendingDownload == nil {
                let b = [UInt8](packet.payload)
                let stride = packet.type == 0x1b ? 12 : 8
                let offset = 2 + page.count * stride
                let identifier = read32(b, offset)
                guard identifier > 0 else { throw SoundcoreError.liveFileUnavailable }
                pendingDownload = .init(id: identifier, size: 0); pendingIsLive = true
                if crypto.isReady { try requestDownload() }
                else { try enqueue(type: 0x2e, command: 0x01, payload: crypto.publicKey); resetTransferTimeout() }
                return
            }
            let existing = Set(files.map(\.id)); let newFiles = page.filter { !existing.contains($0.id) }
            files.append(contentsOf: newFiles); files.sort { $0.id > $1.id }
            if !newFiles.isEmpty, filePage < 100 {
                filePage += 1
                try enqueue(type: packet.type, command: 0x0e, payload: Data([UInt8(filePage & 255), UInt8(filePage >> 8)]))
            }
            status = "Found \(files.count) device recordings"
        case (0x2e, 0x01):
            guard packet.succeeded else { throw SoundcoreError.rejected }
            try crypto.completeHandshake(packet.payload); encryptionReady = true
            if pendingDownload != nil { try requestDownload() }
        case (0x1a, 0x07), (0x1b, 0x07):
            guard var transfer = download else { return }
            guard packet.succeeded else { throw SoundcoreError.rejected }
            transfer.key = try crypto.fileKey(from: packet.payload, expectedID: transfer.recording.id)
            if let size = transfer.key?.expectedBytes, size > 0 { transfer.expectedBytes = UInt64(size) }
            download = transfer; resetTransferTimeout()
        case (0x1a, 0x08), (0x1a, 0x12), (0x1b, 0x08), (0x1b, 0x12):
            guard var transfer = download, let key = transfer.key, let decoder = transfer.decoder else { return }
            for slice in try SoundcoreAudioSlice.parse(packet.payload) {
                if slice == transfer.lastSlice { continue }
                if let expected = transfer.nextSequence {
                    guard slice.sequence == expected else { throw SoundcoreError.incompleteTransfer }
                } else { guard slice.sequence <= 1 else { throw SoundcoreError.incompleteTransfer } }
                guard slice.sequence < UInt32.max else { throw SoundcoreError.incompleteTransfer }
                try decoder.append(key.decrypt(slice))
                transfer.receivedBytes += 160; transfer.nextSequence = slice.sequence + 1; transfer.lastSlice = slice
                guard transfer.isLive || transfer.expectedBytes == 0 || transfer.receivedBytes <= transfer.expectedBytes else { throw SoundcoreError.incompleteTransfer }
            }
            download = transfer; resetTransferTimeout()
            transferProgress = !transfer.isLive && transfer.expectedBytes > 0 ? Double(transfer.receivedBytes) / Double(transfer.expectedBytes) : 0
            status = transfer.isLive ? "Receiving live Soundcore audio locally…" : "Receiving Soundcore recording…"
        case (0x1a, 0x0a), (0x1b, 0x0a):
            try finishDownload()
        default: break
        }
    }

    private func requestDownload() throws {
        guard let recording = pendingDownload else { return }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Daybook/SoundcoreImports", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = root.appendingPathComponent("Soundcore-\(pendingIsLive ? "Live-" : "")\(recording.id)-\(UUID().uuidString.prefix(8)).wav")
        let decoder = try SoundcoreOpusDecoder(outputURL: url)
        if pendingIsLive { decoder.onPCM = { [weak self] in self?.receiveLivePCM($0) } }
        download = Download(recording: recording, url: url, isLive: pendingIsLive,
                            decoder: decoder, expectedBytes: UInt64(recording.size))
        pendingDownload = nil
        var payload = littleEndian32(0); payload.append(littleEndian32(recording.id)); payload.append(pendingIsLive ? 1 : 0)
        try enqueue(type: 0x1a, command: 0x07, payload: payload)
        status = "Requesting Soundcore audio…"; resetTransferTimeout()
    }

    private func finishDownload() throws {
        guard var transfer = download else { return }
        guard transfer.key != nil, transfer.receivedBytes > 0,
              transfer.isLive || (transfer.expectedBytes > 0 && transfer.receivedBytes == transfer.expectedBytes),
              let decoder = transfer.decoder else { throw SoundcoreError.incompleteTransfer }
        try decoder.finish()
        guard decoder.sampleCount > 0 else { throw SoundcoreError.corruptAudio }
        transfer.decoder = nil; download = nil; pendingDownload = nil
        isReceivingLive = false; liveRequested = false; liveSamples = []
        previewTask?.cancel(); previewTask = nil
        if transfer.isLive { livePreviewStatus = "Live preview ended; the saved recording will be processed in full." }
        transferTimeout?.cancel(); transferProgress = nil; lastRecordingURL = transfer.url
        status = "Downloaded and decoded \(transfer.recording.id) locally"
        onRecordingReady?(transfer.url)
    }

    private func discardDownload() {
        let url = download?.url; download = nil; pendingDownload = nil; transferProgress = nil
        isReceivingLive = false; liveRequested = false; liveSamples = []
        previewTask?.cancel(); previewTask = nil
        transferTimeout?.cancel()
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    private func receiveLivePCM(_ buffer: AVAudioPCMBuffer) {
        guard isReceivingLive, let channel = buffer.floatChannelData?[0] else { return }
        liveSamples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        guard liveSamples.count >= 240_000 else { return } // Fifteen seconds at 16 kHz
        let samples = liveSamples; liveSamples.removeAll(keepingCapacity: true)
        guard let transcribeLiveAudio else {
            livePreviewStatus = "Receiving audio; local live transcription is not configured."; return
        }
        guard previewTask == nil else {
            livePreviewStatus = "Preview is catching up. All received audio is still being saved."; return
        }
        let session = liveSession
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Daybook-Soundcore-Preview-\(UUID().uuidString).wav")
        previewTask = Task { [weak self] in
            defer { try? FileManager.default.removeItem(at: url) }
            guard let self else { return }
            do {
                guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
                      let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
                    throw SoundcoreError.corruptAudio
                }
                pcm.frameLength = AVAudioFrameCount(samples.count)
                samples.withUnsafeBufferPointer { pcm.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
                do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: pcm) }
                self.livePreviewStatus = "Transcribing the latest audio on this Mac…"
                let text = try await transcribeLiveAudio(url)
                try Task.checkCancellation()
                if self.liveSession == session {
                    self.liveTranscript += (self.liveTranscript.isEmpty ? "" : "\n") + text
                    self.livePreviewStatus = "Provisional local transcript; complete processing follows after capture."
                }
            } catch is CancellationError { }
            catch {
                if self.liveSession == session { self.livePreviewStatus = "Preview unavailable: \(error.localizedDescription) Audio is still being saved." }
            }
            if self.liveSession == session { self.previewTask = nil }
        }
    }

    private func resetTransferTimeout() {
        transferTimeout?.cancel()
        transferTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled, let self else { return }
            self.error = "Soundcore stopped responding during audio transfer. The incomplete recording was discarded."
            self.discardDownload()
        }
    }
}

extension SoundcoreController: @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn, isConnected || isConnecting { disconnect() }
        beginScanIfReady()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        peripherals[peripheral.identifier] = peripheral
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Soundcore Work"
        if let index = devices.firstIndex(where: { $0.id == peripheral.identifier }) { devices[index].signal = RSSI.intValue }
        else { devices.append(.init(id: peripheral.identifier, name: String(name.prefix(80)), signal: RSSI.intValue)) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral == self.peripheral else { return }
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral == self.peripheral else { return }
        self.error = error?.localizedDescription ?? "Soundcore connection failed."; disconnect()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral == self.peripheral else { return }
        if let error { self.error = error.localizedDescription }
        disconnect()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral == self.peripheral else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            self.error = error?.localizedDescription ?? SoundcoreError.unsupported.localizedDescription; disconnect(); return
        }
        peripheral.discoverCharacteristics([Self.writeUUID, Self.notifyUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral == self.peripheral else { return }
        writeCharacteristic = service.characteristics?.first(where: { $0.uuid == Self.writeUUID })
        notifyCharacteristic = service.characteristics?.first(where: { $0.uuid == Self.notifyUUID })
        guard error == nil, let writer = writeCharacteristic, let reader = notifyCharacteristic,
              writer.properties.contains(.write) || writer.properties.contains(.writeWithoutResponse),
              reader.properties.contains(.notify) || reader.properties.contains(.indicate) else {
            self.error = error?.localizedDescription ?? SoundcoreError.unsupported.localizedDescription; disconnect(); return
        }
        peripheral.setNotifyValue(true, for: reader)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral == self.peripheral, characteristic.uuid == Self.notifyUUID else { return }
        guard error == nil, characteristic.isNotifying else {
            self.error = error?.localizedDescription ?? "Soundcore notifications could not be enabled."; disconnect(); return
        }
        connectionTimeout?.cancel(); isConnecting = false; isConnected = true; status = "Connected"
        refreshStatus()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral == self.peripheral, characteristic.uuid == Self.notifyUUID else { return }
        if let error { self.error = error.localizedDescription; return }
        guard let data = characteristic.value else { return }
        for packet in packetBuffer.append(data) { perform { try receive(packet) } }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral == self.peripheral else { return }
        awaitingWrite = false
        if let error { self.error = error.localizedDescription; writes.removeAll(); discardDownload(); return }
        scheduleNextWrite(last: lastWriteInCommand)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard peripheral == self.peripheral else { return }; pumpWrite()
    }
}
