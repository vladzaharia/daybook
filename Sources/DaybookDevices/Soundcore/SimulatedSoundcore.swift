import Foundation

#if DEBUG
import AVFoundation
import AudioToolbox
import CryptoKit

/// A Soundcore Work that speaks the documented protocol from generated fixtures: status, the paged
/// recording list, the key exchange, encrypted Opus transfers, live audio, and record control. It
/// can drop the link, skip a slice, go quiet, or misreport a size, so tests exercise every path
/// without hardware. Debug builds only; `--device-simulator` runs the app against it.
@MainActor
public final class SimulatedSoundcore {
    public struct Recording {
        public var id: UInt32
        /// Padded 160-byte Opus packets, one per 20 ms.
        public var frames: [Data]
        public var reportsEnd = true
        public var size: UInt32 { UInt32(frames.count * 160) }
        public var seconds: UInt32 { UInt32(frames.count / 50) }

        public init(id: UInt32, frames: [Data], reportsEnd: Bool = true) {
            self.id = id
            self.frames = frames
            self.reportsEnd = reportsEnd
        }
    }

    public enum Fault: Equatable {
        /// Drops the link after this many slices of a transfer.
        case disconnect(afterSlices: Int)
        /// Skips one sequence number at this slice.
        case skipSlice(at: Int)
        /// Stops sending after this many slices, without ending the transfer.
        case stall(afterSlices: Int)
        /// Reports a file size one frame larger than what it sends.
        case wrongSize
        /// Goes quiet once after this many slices, then carries on where it left off: a recorder
        /// delivering live audio in bursts. Shorter than the stall timeout, it loses nothing.
        case pause(afterSlices: Int, for: Duration)
        /// The fault, for the next transfer only: the transfer that takes it disarms it, so a retry
        /// or a resumed import after a reconnect runs clean.
        indirect case once(Fault)
    }

    public var name = "soundcore Work"
    public var serial = "D3200SIM0000001"
    public var firmware = "2.1.4"
    public var caseFirmware = "1.0.9"
    /// Wire values: 0–9 are 10% buckets.
    public var recorderBattery: UInt8 = 7
    public var caseBattery: UInt8 = 5
    public var recorderCharging = false
    public var caseCharging = true
    public var totalKilobytes: UInt32 = 7_031_250
    public var freeKilobytes: UInt32 = 5_957_031
    public var isRecording = false
    public var recordings: [Recording]
    /// The recording in progress, while `isRecording`.
    public var activeRecording: Recording?
    public var pageSize = 10
    /// Firmware without the 12-byte list layout answers it with a failure.
    public var supportsExtendedListing = true
    public var advertises = true
    /// Ignores Start and Pause, so the app never sees the state change.
    public var ignoresRecordCommands = false
    /// Firmware variant: the recording in progress appears among the listing's entries, growing,
    /// as well as after them as the active one.
    public var listsActiveRecording = false
    /// Firmware variant: Pause keeps the recording open (still named as active, not recording) and
    /// Start resumes it; `finishRecording()` closes it.
    public var keepsActiveWhilePaused = false
    public var fault: Fault?
    /// Leaves the key exchange unanswered, as a recorder that went quiet would: a transfer waits in
    /// it until its request times out or the transfer is stopped.
    public var answersKeyExchange = true
    /// Audio slices per notification.
    public var slicesPerPacket = 3
    /// Time between audio notifications; nil sends as fast as possible.
    public var pace: Duration?

    /// Every command received, for tests: (type, command).
    public private(set) var received: [(type: UInt8, command: UInt8)] = []
    private var privateKey = P256.KeyAgreement.PrivateKey()
    private var sessionKey: SymmetricKey?
    private var streaming: Task<Void, Never>?
    fileprivate weak var link: SimulatedSoundcoreTransport?
    /// The device connected now. Like the real recorder, it talks to one device at a time: while one
    /// is connected it doesn't advertise, and another device's connection waits until it's free.
    fileprivate weak var occupant: SimulatedSoundcoreTransport?
    private var transports: [WeakTransport] = []
    /// Connections it accepted, in order, by transport (tests of handing it between devices).
    public private(set) var connectionLog: [UUID] = []

    private struct WeakTransport { weak var transport: SimulatedSoundcoreTransport? }

    /// Whether a device is connected to it now.
    public var isOccupied: Bool { occupant != nil }

    public init(recordings: [Recording]) {
        self.recordings = recordings
    }

    /// Two recordings and a little live audio, for `--device-simulator`.
    public static func demo() -> SimulatedSoundcore {
        let now = UInt32(Date().timeIntervalSince1970)
        let device = SimulatedSoundcore(recordings: [
            Recording(id: now - 3 * 3_600, frames: frames(seconds: 6, frequency: 330)),
            Recording(id: now - 26 * 3_600, frames: frames(seconds: 9, frequency: 440))
        ])
        device.pace = .milliseconds(60)
        return device
    }

    // MARK: Fixtures

    /// A tone encoded with the system Opus encoder into padded 160-byte packets.
    public nonisolated static func frames(seconds: Double, frequency: Float = 440) -> [Data] {
        guard let pcm = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else { return [] }
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                                                      mBytesPerPacket: 0, mFramesPerPacket: 960, mBytesPerFrame: 0,
                                                      mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        guard let opus = AVAudioFormat(streamDescription: &description), let encoder = AVAudioConverter(from: pcm, to: opus) else { return [] }
        encoder.bitRate = 32_000
        let count = AVAudioFrameCount(48_000 * seconds)
        guard let input = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: count) else { return [] }
        input.frameLength = count
        for index in 0..<Int(count) { input.floatChannelData![0][index] = sin(Float(index) * 2 * .pi * frequency / 48_000) * 0.25 }
        var supplied = false
        var frames: [Data] = []
        for _ in 0..<Int(seconds * 10 + 10) {
            let compressed = AVAudioCompressedBuffer(format: opus, packetCapacity: 64, maximumPacketSize: 1_275)
            var error: NSError?
            let status = encoder.convert(to: compressed, error: &error) { _, state in
                if supplied { state.pointee = .endOfStream; return nil }
                supplied = true; state.pointee = .haveData; return input
            }
            guard error == nil, let descriptions = compressed.packetDescriptions else { break }
            for index in 0..<Int(compressed.packetCount) {
                let packet = descriptions[index]
                guard packet.mDataByteSize <= 160 else { continue }
                var data = Data(bytes: compressed.data.advanced(by: Int(packet.mStartOffset)), count: Int(packet.mDataByteSize))
                data.append(Data(repeating: 0, count: 160 - data.count))
                frames.append(data)
            }
            if status == .endOfStream { break }
        }
        return frames
    }

    // MARK: The protocol

    /// One command from Daybook.
    fileprivate func handle(_ packet: Data) {
        let b = [UInt8](packet)
        guard b.count >= 10, b[0] == 8, b[1] == 0xee else { return }
        let type = b[5], command = b[6]
        let payload = Data(b[9..<(b.count - 1)])
        received.append((type, command))
        switch (type, command) {
        case (0x01, 0x01):
            reply(0x01, 0x01, statusPayload())
        case (0x1b, 0x0e) where !supportsExtendedListing:
            reply(0x1b, 0x0e, Data(), status: 0)
        case (0x1a, 0x0e), (0x1b, 0x0e):
            let page = Int(payload.first ?? 0) | Int(payload.count > 1 ? payload[payload.startIndex + 1] : 0) << 8
            reply(type, 0x0e, listPayload(page: page, extended: type == 0x1b))
        case (0x2e, 0x01):
            guard answersKeyExchange else { return }
            handshake(payload)
        case (0x1a, 0x07):
            let p = [UInt8](payload)
            guard p.count >= 9, let id = try? p.le32(at: 4) else { reply(0x1a, 0x07, Data(), status: 0); return }
            startTransfer(id: id, live: p[8] == 1)
        case (0x1a, 0x11):
            streaming?.cancel()
            streaming = nil
        case (0x18, 0x82):
            guard !ignoresRecordCommands, let action = payload.first else { reply(0x18, 0x82, Data(), status: 0); return }
            if action == 1 { record(true) } else if action == 2 { record(false) }
            reply(0x18, 0x82, Data([isRecording ? 1 : 2]))
        default:
            reply(type, command, Data(), status: 0)
        }
    }

    /// Starts or pauses as the recorder does. A new recording's ID is its start on the recorder's clock.
    private func record(_ on: Bool) {
        if on && !isRecording {
            isRecording = true
            // Firmware that keeps a paused recording open resumes it.
            if !(keepsActiveWhilePaused && activeRecording != nil) {
                let now = Date().timeIntervalSince1970 + clockOffset
                activeRecording = Recording(id: UInt32(now), frames: Self.frames(seconds: 4, frequency: 520))
            }
        } else if !on && isRecording {
            isRecording = false
            if !keepsActiveWhilePaused { finishRecording() }
        }
    }

    /// Closes the recording in progress: it joins the list as a finished recording.
    public func finishRecording() {
        isRecording = false
        if let active = activeRecording { recordings.insert(active, at: 0) }
        activeRecording = nil
    }

    /// The recorder's own button: starts or stops recording and reports the new state unasked.
    public func pressButton() {
        record(!isRecording)
        send(SoundcorePacket.frame(type: 0x18, command: 0x82, payload: Data([isRecording ? 1 : 2])))
    }

    /// The recorder's clock against true time, in seconds (positive: it runs ahead). New recordings'
    /// IDs are their start by this clock.
    public var clockOffset: TimeInterval = 0

    /// Pushes a battery update, as the recorder does on its own.
    public func pushBattery(recorder: UInt8, case caseLevel: UInt8) {
        recorderBattery = recorder
        caseBattery = caseLevel
        send(SoundcorePacket.frame(type: 0x01, command: 0x03, payload: Data([recorder, caseLevel])))
    }

    public func connectionEnded() {
        streaming?.cancel()
        streaming = nil
        sessionKey = nil
        privateKey = P256.KeyAgreement.PrivateKey()
    }

    fileprivate func register(_ transport: SimulatedSoundcoreTransport) {
        transports.removeAll { $0.transport == nil }
        transports.append(WeakTransport(transport: transport))
    }

    fileprivate func occupy(_ transport: SimulatedSoundcoreTransport) {
        occupant = transport
        link = transport
        connectionLog.append(transport.peripheralLogID)
    }

    /// The connected device let go: it advertises again, and a connection another device was waiting
    /// on completes.
    fileprivate func vacate(_ transport: SimulatedSoundcoreTransport) {
        guard occupant === transport else { return }
        occupant = nil
        connectionEnded()
        for waiting in transports.compactMap(\.transport) where waiting !== transport && waiting.isWaitingToConnect {
            waiting.recorderIsFree()
            break
        }
    }

    private func statusPayload() -> Data {
        var b = [UInt8](repeating: 0, count: 56)
        b[1] = recorderBattery
        b[2] = recorderCharging ? 1 : 0
        for (index, byte) in firmware.utf8.prefix(5).enumerated() { b[3 + index] = byte }
        for (index, byte) in serial.utf8.prefix(16).enumerated() { b[8 + index] = byte }
        b.replaceSubrange(24..<28, with: littleEndian32(totalKilobytes))
        b.replaceSubrange(28..<32, with: littleEndian32(freeKilobytes))
        b[32] = caseCharging ? 1 : 0
        for (index, byte) in caseFirmware.utf8.prefix(5).enumerated() { b[33 + index] = byte }
        b[38] = caseBattery
        b[50] = isRecording ? 1 : 0
        return Data(b)
    }

    private func listPayload(page: Int, extended: Bool) -> Data {
        let start = page * pageSize
        var listed = recordings
        if listsActiveRecording, let active = activeRecording { listed.insert(active, at: 0) }
        let entries = start < listed.count ? Array(listed[start..<min(listed.count, start + pageSize)]) : []
        var data = Data([UInt8(entries.count & 255), UInt8(entries.count >> 8)])
        for recording in entries {
            data.append(littleEndian32(recording.id))
            if extended { data.append(littleEndian32(recording.reportsEnd ? recording.id + recording.seconds : 0)) }
            data.append(littleEndian32(recording.size))
        }
        let open = isRecording || keepsActiveWhilePaused
        data.append(littleEndian32(open ? activeRecording?.id ?? 0 : 0))
        data.append(Data(repeating: 0, count: 4))
        return data
    }

    private func handshake(_ appKey: Data) {
        guard let peer = try? P256.KeyAgreement.PublicKey(x963Representation: appKey.prefix(65)),
              let secret = try? privateKey.sharedSecretFromKeyAgreement(with: peer) else {
            reply(0x2e, 0x01, Data(), status: 0)
            return
        }
        sessionKey = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data([1, 2, 3]), sharedInfo: Data([1, 2, 3]), outputByteCount: 32)
        reply(0x2e, 0x01, privateKey.publicKey.x963Representation + secret.withUnsafeBytes { Data($0) })
    }

    private func startTransfer(id: UInt32, live: Bool) {
        let source = live ? (activeRecording?.id == id ? activeRecording : nil) : recordings.first { $0.id == id }
        guard let recording = source, let sessionKey else { reply(0x1a, 0x07, Data(), status: 0); return }
        // A transfer takes the fault armed when it starts; a one-shot fault is disarmed as it's taken.
        var fault = self.fault
        while case .once(let inner)? = fault {
            fault = inner
            self.fault = nil
        }
        let fileKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let nonce = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let iv = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let wrapped = (try? SoundcoreCrypto.crypt(Data("soundcored3200".utf8) + fileKey,
                                                  key: sessionKey.withUnsafeBytes { Data($0) }, iv: iv)) ?? Data()
        let size = live ? 0 : recording.size + (fault == .wrongSize ? 160 : 0)
        var header = littleEndian32(id)
        header.append(littleEndian32(size))
        header.append(nonce)
        header.append(wrapped)
        header.append(iv)
        header.append(0)
        reply(0x1a, 0x07, header)

        let perPacket = max(1, slicesPerPacket)
        let pace = self.pace
        streaming?.cancel()
        streaming = Task { [weak self] in
            var sequence: UInt32 = 0
            var sent = 0
            var index = 0
            var paused = false
            let frames = recording.frames
            while !Task.isCancelled {
                if !live && index >= frames.count { break }
                var payload = Data()
                for _ in 0..<perPacket where live || index < frames.count {
                    if case .skipSlice(let at)? = fault, sent == at { sequence += 1 }
                    let frame = frames[index % max(1, frames.count)]
                    let audio = (try? SoundcoreFileKey.crypt(frame, sequence: sequence, key: fileKey, nonce: nonce)) ?? frame
                    payload.append(SoundcoreAudioSlice.encode(sequence: sequence, audio: audio))
                    sequence += 1; sent += 1; index += 1
                }
                guard let self else { return }
                self.send(SoundcorePacket.frame(type: 0x1a, command: live ? 0x12 : 0x08, payload: payload))
                if case .disconnect(let after)? = fault, sent >= after { self.link?.dropLink(); return }
                if case .stall(let after)? = fault, sent >= after { return }
                if case .pause(let after, let quiet)? = fault, sent >= after, !paused {
                    paused = true
                    try? await Task.sleep(for: quiet)
                    continue
                }
                if let pace { try? await Task.sleep(for: pace) } else { await Task.yield() }
            }
            guard !Task.isCancelled, !live, let self else { return }
            self.send(SoundcorePacket.frame(type: 0x1a, command: 0x0a))
            self.streaming = nil
        }
    }

    private func reply(_ type: UInt8, _ command: UInt8, _ payload: Data, status: UInt8 = 1) {
        send(SoundcorePacket.frame(type: type, command: command, status: status, payload: payload))
    }

    private func send(_ frame: Data) { link?.notify(frame) }
}

/// The simulated link: it advertises the recorder, connects it, and delivers its notifications in
/// order, split to a Bluetooth-sized MTU so reassembly is exercised too.
@MainActor
public final class SimulatedSoundcoreTransport: SoundcoreTransport {
    public weak var events: (any SoundcoreTransportEvents)?
    public let device: SimulatedSoundcore
    public let peripheralID = UUID()
    public var radio: RadioState = .unknown
    /// The radio state `activate()` reports.
    public var radioOnActivate: RadioState = .poweredOn
    /// Whether the system "remembers" the recorder for `retrievePeripherals`.
    public var isKnown = true
    public var mtu = 182
    public var rssi = -58
    public private(set) var connected = false
    public private(set) var activations = 0
    public private(set) var scans = 0
    public private(set) var connectAttempts = 0
    private var pendingConnect = false
    private var outbox: [@MainActor () -> Void] = []
    private var delivering = false

    /// Identifies this transport (one per device reaching for the recorder) in `connectionLog`.
    public let peripheralLogID = UUID()

    public init(device: SimulatedSoundcore) {
        self.device = device
        if device.occupant == nil { device.link = self }
        device.register(self)
    }

    /// A connection is waiting for the recorder to come into range or to be free.
    fileprivate var isWaitingToConnect: Bool { pendingConnect }

    public func activate() {
        activations += 1
        guard radio == .unknown else { return }
        radio = radioOnActivate
        deliver { [weak self] in guard let self else { return }; self.events?.transportRadioChanged(self.radio) }
    }

    public func startScan() {
        scans += 1
        guard radio == .poweredOn, device.advertises, !connected, device.occupant == nil else { return }
        let id = peripheralID, name = device.name, rssi = rssi
        deliver { [weak self] in self?.events?.transportDiscovered(id, name: name, rssi: rssi) }
    }

    public func stopScan() {}

    public func canReconnect(to id: UUID) -> Bool { radio == .poweredOn && isKnown && id == peripheralID }

    public func connect(_ id: UUID) {
        connectAttempts += 1
        guard id == peripheralID, radio == .poweredOn else {
            deliver { [weak self] in self?.events?.transportFailed(id, .connectFailed("Unknown recorder")) }
            return
        }
        // Out of range, or connected to another device: the system keeps trying until it's reachable.
        guard device.advertises, device.occupant == nil || device.occupant === self else { pendingConnect = true; return }
        open()
    }

    public func disconnect(_ id: UUID) {
        pendingConnect = false
        guard connected else { return }
        connected = false
        endConnection()
    }

    /// The device this one was waiting on let go.
    fileprivate func recorderIsFree() {
        guard pendingConnect, device.advertises, radio == .poweredOn else { return }
        pendingConnect = false
        open()
    }

    private func endConnection() {
        if device.occupant === self { device.vacate(self) } else { device.connectionEnded() }
    }

    public func send(_ packet: Data) throws {
        guard connected else { throw SoundcoreError.disconnected }
        device.handle(packet)
    }

    // MARK: Test controls

    /// The recorder comes into range; a pending connection completes.
    public func comeIntoRange() {
        device.advertises = true
        if pendingConnect, device.occupant == nil || device.occupant === self { pendingConnect = false; open() }
    }

    /// The link drops unexpectedly.
    public func dropLink() {
        guard connected else { return }
        connected = false
        endConnection()
        let id = peripheralID
        outbox.removeAll()
        deliver { [weak self] in self?.events?.transportDisconnected(id, error: "The simulated recorder went out of range.") }
    }

    public func setRadio(_ state: RadioState) {
        radio = state
        if state != .poweredOn, connected { connected = false; endConnection(); outbox.removeAll() }
        deliver { [weak self] in self?.events?.transportRadioChanged(state) }
    }

    fileprivate func notify(_ frame: Data) {
        guard connected else { return }
        var offset = 0
        while offset < frame.count {
            let chunk = frame.subdata(in: offset..<min(frame.count, offset + mtu))
            offset += mtu
            deliver { [weak self] in
                guard let self, self.connected else { return }
                self.events?.transportReceived(chunk)
            }
        }
    }

    private func open() {
        connected = true
        device.occupy(self)
        let id = peripheralID
        deliver { [weak self] in self?.events?.transportReady(id) }
    }

    /// In order, one at a time, after the caller returns: like delegate callbacks on the main queue.
    private func deliver(_ work: @escaping @MainActor () -> Void) {
        outbox.append(work)
        guard !delivering else { return }
        delivering = true
        Task { [weak self] in
            while let self, !self.outbox.isEmpty {
                await Task.yield()
                guard !self.outbox.isEmpty else { break }
                self.outbox.removeFirst()()
            }
            self?.delivering = false
        }
    }
}

#endif

/// A link that does nothing: demos and test hosts never scan, connect, or ask for Bluetooth
/// permission. Outside DEBUG because the iPhone's test host uses it in any configuration.
@MainActor
public final class InertSoundcoreTransport: SoundcoreTransport {
    public init() {}
    public weak var events: (any SoundcoreTransportEvents)?
    public var radio: RadioState { .unknown }
    public func activate() {}
    public func startScan() {}
    public func stopScan() {}
    public func canReconnect(to id: UUID) -> Bool { false }
    public func connect(_ id: UUID) {}
    public func disconnect(_ id: UUID) {}
    public func send(_ packet: Data) throws { throw SoundcoreError.disconnected }
}
