import Foundation

// Original implementation of the D3200 wire format, from community protocol research:
// https://github.com/tacshi/Soundcore/blob/main/PROTOCOL.md (no code was copied). Every parser
// here is bounds-checked and throws `SoundcoreError.invalidPacket` on malformed input; none traps.

/// One frame from the recorder: `09 FF 00 00 status type command lenLo lenHi payload… checksum`.
public struct SoundcorePacket: Equatable {
    public let type: UInt8
    public let command: UInt8
    public let status: UInt8
    public let payload: Data
    public var succeeded: Bool { status & 0x0f == 1 }

    /// A command to the recorder: `08 EE 00 00 00 type command lenLo lenHi payload… checksum`.
    public static func command(type: UInt8, id: UInt8, payload: Data = Data()) throws -> Data {
        guard payload.count <= 65_525 else { throw SoundcoreError.invalidPacket }
        let count = payload.count + 10
        var bytes: [UInt8] = [8, 0xee, 0, 0, 0, type, id, UInt8(count & 255), UInt8(count >> 8)]
        bytes.append(contentsOf: payload)
        bytes.append(bytes.reduce(UInt8(0), &+))
        return Data(bytes)
    }

    /// A frame as the recorder sends it. Used by the simulator and tests.
    public static func frame(type: UInt8, command: UInt8, status: UInt8 = 1, payload: Data = Data()) -> Data {
        let count = min(payload.count, 65_525) + 10
        var bytes: [UInt8] = [9, 0xff, 0, 0, status, type, command, UInt8(count & 255), UInt8(count >> 8)]
        bytes.append(contentsOf: payload.prefix(65_525))
        bytes.append(bytes.reduce(UInt8(0), &+))
        return Data(bytes)
    }

    public init(type: UInt8, command: UInt8, status: UInt8, payload: Data) {
        self.type = type
        self.command = command
        self.status = status
        self.payload = payload
    }
}

/// Reassembles notifications into frames. Garbage between frames is skipped, frames with a bad
/// length or checksum are rejected, and the buffer never grows past one maximum-size frame.
public struct SoundcorePacketBuffer {
    public static let maximumFrame = 65_535
    private var bytes: [UInt8] = []
    public private(set) var rejectedFrames = 0

    public mutating func reset() { bytes.removeAll(); rejectedFrames = 0 }

    public mutating func append(_ data: Data) -> [SoundcorePacket] {
        guard data.count <= 1_048_576 else { bytes.removeAll(); rejectedFrames += 1; return [] }
        bytes.append(contentsOf: data)
        var result: [SoundcorePacket] = []
        var offset = 0
        while bytes.count - offset >= 2 {
            guard bytes[offset] == 9, bytes[offset + 1] == 255 else { offset += 1; continue }
            guard bytes.count - offset >= 9 else { break }
            guard bytes[offset + 2] == 0, bytes[offset + 3] == 0 else { offset += 1; rejectedFrames += 1; continue }
            let length = Int(bytes[offset + 7]) | Int(bytes[offset + 8]) << 8
            guard length >= 10 else { offset += 1; rejectedFrames += 1; continue }
            guard bytes.count - offset >= length else { break }
            let end = offset + length
            guard bytes[offset..<(end - 1)].reduce(UInt8(0), &+) == bytes[end - 1] else {
                offset += 1; rejectedFrames += 1; continue
            }
            result.append(.init(type: bytes[offset + 5], command: bytes[offset + 6], status: bytes[offset + 4],
                                payload: Data(bytes[(offset + 9)..<(end - 1)])))
            offset = end
        }
        if offset > 0 { bytes.removeFirst(offset) }
        if bytes.count > Self.maximumFrame { bytes.removeAll(); rejectedFrames += 1 }
        return result
    }
}

/// The recorder's status reply (`01 01`).
public struct SoundcoreDeviceInfo: Equatable, Codable {
    public var microphoneBattery: Int?
    public var caseBattery: Int?
    public var microphoneCharging = false
    public var caseCharging = false
    public var firmware = ""
    public var caseFirmware = ""
    public var serial = ""
    public var totalBytes: UInt64 = 0
    public var freeBytes: UInt64 = 0
    public var isRecording = false

    public static let minimumLength = 51

    /// Wire values 0–9 are 10% buckets; larger values up to 100 are literal percentages.
    public static func battery(_ wire: UInt8) -> Int? {
        if wire <= 9 { return (Int(wire) + 1) * 10 }
        return wire <= 100 ? Int(wire) : nil
    }

    public static func parse(_ payload: Data) throws -> Self {
        let b = [UInt8](payload)
        guard b.count >= minimumLength else { throw SoundcoreError.invalidPacket }
        func text(_ range: Range<Int>) -> String {
            let characters = b[range].prefix { $0 != 0 }.filter { (0x20...0x7e).contains($0) }
            return String(decoding: characters, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }
        let total = try b.le32(at: 24), free = try b.le32(at: 28)
        return .init(microphoneBattery: battery(b[1]), caseBattery: battery(b[38]),
                     microphoneCharging: b[2] == 1, caseCharging: b[32] == 1,
                     firmware: text(3..<8), caseFirmware: text(33..<38), serial: text(8..<24),
                     totalBytes: UInt64(total) * 1_024, freeBytes: UInt64(min(free, total)) * 1_024,
                     isRecording: b[50] == 1)
    }

    public init(microphoneBattery: Int? = nil, caseBattery: Int? = nil, microphoneCharging: Bool = false, caseCharging: Bool = false, firmware: String = "", caseFirmware: String = "", serial: String = "", totalBytes: UInt64 = 0, freeBytes: UInt64 = 0, isRecording: Bool = false) {
        self.microphoneBattery = microphoneBattery
        self.caseBattery = caseBattery
        self.microphoneCharging = microphoneCharging
        self.caseCharging = caseCharging
        self.firmware = firmware
        self.caseFirmware = caseFirmware
        self.serial = serial
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.isRecording = isRecording
    }
}

/// A recording on the recorder. Its ID is its Unix start time.
public struct SoundcoreRecording: Identifiable, Equatable, Codable {
    public let id: UInt32
    public let size: UInt32
    public var endTimestamp: UInt32?

    /// The start time, when the ID is a plausible one.
    public var date: Date? {
        let value = Date(timeIntervalSince1970: Double(id))
        return id >= 946_684_800 && value < Date().addingTimeInterval(31_536_000) ? value : nil
    }

    /// The decoder takes one 160-byte frame per 20 ms, so 8,000 bytes is about one second.
    public static let bytesPerSecond: Double = 8_000
    /// 8,000 bytes a second is 28.8 MB an hour.
    public static let bytesPerHour: Double = 28_800_000

    /// Exact when the recorder reports a sensible end time, otherwise estimated from the size.
    public var length: RecordingLength {
        if let end = endTimestamp, end > id, end - id <= 172_800 { return .exact(TimeInterval(end - id)) }
        return .estimated(Double(size) / Self.bytesPerSecond)
    }

    /// A page of the recording list (`1A 0E` with 8-byte entries, or `1B 0E` with 12-byte entries
    /// that add the end time), followed by the ID of the recording in progress.
    public static func parseList(_ packet: SoundcorePacket) throws -> [Self] {
        try page(packet).recordings
    }

    /// The recording in progress, reported after a page's entries; nil when there is none.
    public static func activeRecordingID(in packet: SoundcorePacket) throws -> UInt32? {
        try page(packet).active
    }

    public static func page(_ packet: SoundcorePacket) throws -> (recordings: [Self], active: UInt32?) {
        let b = [UInt8](packet.payload)
        guard packet.command == 0x0e, packet.type == 0x1a || packet.type == 0x1b, b.count >= 10 else {
            throw SoundcoreError.invalidPacket
        }
        let count = Int(b[0]) | Int(b[1]) << 8
        let stride = packet.type == 0x1b ? 12 : 8
        guard count <= 5_000, b.count >= 2 + count * stride + 8 else { throw SoundcoreError.invalidPacket }
        let recordings = try (0..<count).map { index in
            let offset = 2 + index * stride
            return Self(id: try b.le32(at: offset), size: try b.le32(at: offset + stride - 4),
                        endTimestamp: stride == 12 ? try b.le32(at: offset + 4) : nil)
        }
        let active = try b.le32(at: 2 + count * stride)
        return (recordings.filter { $0.id > 0 }, active > 0 ? active : nil)
    }

    public init(id: UInt32, size: UInt32, endTimestamp: UInt32? = nil) {
        self.id = id
        self.size = size
        self.endTimestamp = endTimestamp
    }
}

/// One encrypted 20 ms audio frame: `sequence(4) flags(1) audio(160) trailer(1)`.
public struct SoundcoreAudioSlice: Equatable {
    public static let size = 166
    public let sequence: UInt32
    public let flags: UInt8
    public let audio: Data

    public static func parse(_ payload: Data) throws -> [Self] {
        let b = [UInt8](payload)
        // Some observed packets omit the final slice's trailer; the frame checksum was already checked.
        guard !b.isEmpty, b.count % size == 0 || b.count % size == size - 1 else { throw SoundcoreError.invalidPacket }
        return try stride(from: 0, to: b.count, by: size).map { offset in
            guard offset + 165 <= b.count else { throw SoundcoreError.invalidPacket }
            return .init(sequence: try b.le32(at: offset), flags: b[offset + 4], audio: Data(b[(offset + 5)..<(offset + 165)]))
        }
    }

    /// The wire form, for the simulator and tests.
    public static func encode(sequence: UInt32, flags: UInt8 = 0, audio: Data) -> Data {
        var data = littleEndian32(sequence)
        data.append(flags)
        data.append(audio.prefix(160))
        if audio.count < 160 { data.append(Data(repeating: 0, count: 160 - audio.count)) }
        data.append(0)
        return data
    }

    public init(sequence: UInt32, flags: UInt8, audio: Data) {
        self.sequence = sequence
        self.flags = flags
        self.audio = audio
    }
}

/// Protocol failures. Their descriptions appear only in Device Details › Technical Details; the
/// device page shows the matching problem instead.
public enum SoundcoreError: LocalizedError, Equatable {
    case invalidPacket, disconnected, unsupported, rejected, invalidEncryption, incompleteTransfer
    case codecUnavailable, corruptAudio, liveFileUnavailable, timedOut, stalled

    public var errorDescription: String? {
        switch self {
        case .invalidPacket: return "The recorder sent an unrecognized or incomplete packet. This firmware may use a different protocol."
        case .disconnected: return "The recorder isn’t connected."
        case .unsupported: return "This firmware doesn’t expose the expected Bluetooth service."
        case .rejected: return "The recorder rejected the request. It may need its official app or use a different protocol."
        case .invalidEncryption: return "The audio key exchange couldn’t be verified. Audio was not imported."
        case .incompleteTransfer: return "Audio packets were missing, conflicting, or out of order. Audio was not imported."
        case .codecUnavailable: return "The system’s Opus decoder is unavailable."
        case .corruptAudio: return "The audio couldn’t be decoded reliably. Audio was not imported."
        case .liveFileUnavailable: return "The recorder didn’t identify a recording in progress."
        case .timedOut: return "The recorder didn’t answer in time."
        case .stalled: return "No audio arrived for 45 seconds."
        }
    }
}

extension Array where Element == UInt8 {
    /// A little-endian 32-bit value, or `invalidPacket` when it runs past the end.
    public func le32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= count - 4 else { throw SoundcoreError.invalidPacket }
        return UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 | UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
    }
}

public func littleEndian32(_ value: UInt32) -> Data {
    Data([UInt8(value & 255), UInt8((value >> 8) & 255), UInt8((value >> 16) & 255), UInt8(value >> 24)])
}
