import Foundation

/// Original implementation of the documented D3200 wire format. Protocol facts:
/// https://github.com/tacshi/Soundcore/blob/main/PROTOCOL.md
struct SoundcorePacket: Equatable {
    let type: UInt8
    let command: UInt8
    let status: UInt8
    let payload: Data
    var succeeded: Bool { status & 0x0f == 1 }

    static func command(type: UInt8, id: UInt8, payload: Data = Data()) throws -> Data {
        guard payload.count <= 65_525 else { throw SoundcoreError.invalidPacket }
        let count = payload.count + 10
        var bytes: [UInt8] = [8, 0xee, 0, 0, 0, type, id, UInt8(count & 255), UInt8(count >> 8)]
        bytes.append(contentsOf: payload)
        bytes.append(bytes.reduce(UInt8(0), &+))
        return Data(bytes)
    }
}

struct SoundcorePacketBuffer {
    private var bytes: [UInt8] = []
    private(set) var rejectedFrames = 0

    mutating func reset() { bytes.removeAll(); rejectedFrames = 0 }

    mutating func append(_ data: Data) -> [SoundcorePacket] {
        guard data.count <= 1_048_576 else { reset(); rejectedFrames += 1; return [] }
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
        if bytes.count > 65_535 { reset(); rejectedFrames += 1 }
        return result
    }
}

struct SoundcoreDeviceInfo: Equatable {
    var microphoneBattery: Int?
    var caseBattery: Int?
    var microphoneCharging = false
    var caseCharging = false
    var firmware = ""
    var caseFirmware = ""
    var serial = ""
    var totalBytes: UInt64 = 0
    var freeBytes: UInt64 = 0
    var isRecording = false

    static func battery(_ wire: UInt8) -> Int? {
        if wire <= 9 { return (Int(wire) + 1) * 10 }
        return wire <= 100 ? Int(wire) : nil
    }

    static func parse(_ payload: Data) throws -> Self {
        let b = [UInt8](payload)
        guard b.count >= 51 else { throw SoundcoreError.invalidPacket }
        func ascii(_ range: Range<Int>) -> String {
            String(bytes: b[range].prefix(while: { $0 != 0 }), encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return .init(microphoneBattery: battery(b[1]), caseBattery: battery(b[38]),
                     microphoneCharging: b[2] == 1, caseCharging: b[32] == 1,
                     firmware: ascii(3..<8), caseFirmware: ascii(33..<38), serial: ascii(8..<24),
                     totalBytes: UInt64(read32(b, 24)) * 1_024, freeBytes: UInt64(read32(b, 28)) * 1_024,
                     isRecording: b[50] == 1)
    }
}

struct SoundcoreRecording: Identifiable, Equatable {
    let id: UInt32
    let size: UInt32
    var endTimestamp: UInt32?
    var date: Date? {
        let value = Date(timeIntervalSince1970: Double(id))
        return id >= 946_684_800 && value < Date().addingTimeInterval(31_536_000) ? value : nil
    }

    static func parseList(_ packet: SoundcorePacket) throws -> [Self] {
        let b = [UInt8](packet.payload)
        guard b.count >= 10, packet.command == 0x0e, packet.type == 0x1a || packet.type == 0x1b else {
            throw SoundcoreError.invalidPacket
        }
        let count = Int(b[0]) | Int(b[1]) << 8
        let stride = packet.type == 0x1b ? 12 : 8
        guard count <= 5_000, b.count >= 2 + count * stride + 8 else { throw SoundcoreError.invalidPacket }
        return (0..<count).map { index in
            let offset = 2 + index * stride
            return .init(id: read32(b, offset), size: read32(b, offset + stride - 4),
                         endTimestamp: stride == 12 ? read32(b, offset + 4) : nil)
        }
    }
}

struct SoundcoreAudioSlice: Equatable {
    let sequence: UInt32
    let flags: UInt8
    let audio: Data

    static func parse(_ payload: Data) throws -> [Self] {
        let b = [UInt8](payload)
        // Some observed packets omit the final per-slice trailer; the outer
        // frame checksum is already removed by SoundcorePacketBuffer.
        guard !b.isEmpty, b.count % 166 == 0 || b.count % 166 == 165 else { throw SoundcoreError.invalidPacket }
        return stride(from: 0, to: b.count, by: 166).map {
            .init(sequence: read32(b, $0), flags: b[$0 + 4], audio: Data(b[($0 + 5)..<($0 + 165)]))
        }
    }
}

enum SoundcoreError: LocalizedError {
    case invalidPacket, disconnected, unsupported, rejected, invalidEncryption, incompleteTransfer, codecUnavailable, corruptAudio, liveFileUnavailable
    var errorDescription: String? {
        switch self {
        case .invalidPacket: return "Soundcore sent an unrecognized or incomplete packet. This firmware may use a different protocol."
        case .disconnected: return "Connect to a Soundcore Work first."
        case .unsupported: return "This Soundcore firmware does not expose the expected Bluetooth service."
        case .rejected: return "The Soundcore device rejected this request. It may require its official app or a different firmware protocol."
        case .invalidEncryption: return "The local Soundcore encryption exchange could not be verified. Audio was not imported."
        case .incompleteTransfer: return "The Soundcore transfer has missing, conflicting, or out-of-order audio packets. Audio was not imported."
        case .codecUnavailable: return "The system's local Opus decoder is unavailable."
        case .corruptAudio: return "Soundcore audio could not be decoded reliably. Audio was not imported."
        case .liveFileUnavailable: return "The device did not identify an active recording. Refresh its status and try live reception again."
        }
    }
}

func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
}

func littleEndian32(_ value: UInt32) -> Data {
    Data([UInt8(value & 255), UInt8((value >> 8) & 255), UInt8((value >> 16) & 255), UInt8(value >> 24)])
}
