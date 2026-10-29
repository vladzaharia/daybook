import Foundation

// Wi‑Fi Fast Transfer's wire format, from community protocol research: tacshi/Soundcore's PROTOCOL.md
// §6.4–6.5 and §9, and its Wi‑Fi export service (no code was copied). Unverified on hardware until a
// real Fast Transfer is captured; see docs/direct-soundcore.md, "Wi‑Fi Fast Transfer".

/// The recorder's access point, as Daybook asked for it and the recorder answered.
public struct SoundcoreAccessPoint: Equatable, Sendable {
    public var ssid: String
    public var password: String
    /// The recorder's address on its own network, and its WebSocket's port.
    public var host: String
    public var port: UInt16

    public init(ssid: String, password: String, host: String, port: UInt16) {
        self.ssid = ssid
        self.password = password
        self.host = host
        self.port = port
    }
}

public enum SoundcoreWiFi {
    /// The UDP keep-alive the recorder expects every two seconds while the WebSocket is open.
    public static let keepAlivePort: UInt16 = 32003
    public static let keepAlive = Data("soundcore-keep-alive-unicast".utf8)
    /// The text that ends the WebSocket session.
    public static let finish = "FINISH"

    /// The access point's name and password, which the app chooses. The name is in the official app's
    /// form (`WiFi-<milliseconds>`); the password is 13 random digits, as long as the official app's
    /// (which uses the same milliseconds) but not guessable from the name.
    public static func credentials(at date: Date = Date()) -> (ssid: String, password: String) {
        let milliseconds = UInt64(max(0, date.timeIntervalSince1970) * 1_000)
        let password = String((0..<13).map { _ in Character(String(Int.random(in: 0...9))) })
        return ("WiFi-\(milliseconds)", password)
    }

    /// `1A 05`'s payload: the name's length, the name, the password's length, the password (UTF-8).
    public static func accessPointRequest(ssid: String, password: String) throws -> Data {
        let name = Data(ssid.utf8), secret = Data(password.utf8)
        guard (1...32).contains(name.count), (8...63).contains(secret.count) else { throw SoundcoreError.invalidPacket }
        return Data([UInt8(name.count)]) + name + Data([UInt8(secret.count)]) + secret
    }

    /// The name and password in a `1A 05` request (the simulator).
    public static func credentials(inRequest payload: Data) -> (ssid: String, password: String)? {
        let b = [UInt8](payload)
        guard let nameLength = b.first.map(Int.init), b.count > nameLength + 1 else { return nil }
        let passwordLength = Int(b[nameLength + 1])
        guard b.count >= nameLength + 2 + passwordLength else { return nil }
        return (String(decoding: b[1..<(1 + nameLength)], as: UTF8.self),
                String(decoding: b[(nameLength + 2)..<(nameLength + 2 + passwordLength)], as: UTF8.self))
    }

    /// The recorder's address in `1A 05`'s reply: its IPv4 address with the bytes in reverse order,
    /// then the port, little-endian.
    public static func endpoint(from packet: SoundcorePacket) throws -> (host: String, port: UInt16) {
        let b = [UInt8](packet.payload)
        guard packet.type == 0x1a, packet.command == 0x05, packet.succeeded, b.count >= 6 else { throw SoundcoreError.invalidPacket }
        let port = UInt16(b[4]) | UInt16(b[5]) << 8
        guard port > 0, b[3] != 0 else { throw SoundcoreError.invalidPacket }
        return ("\(b[3]).\(b[2]).\(b[1]).\(b[0])", port)
    }

    /// That reply's payload, for an address written the usual way round (the simulator).
    public static func endpointPayload(address: [UInt8], port: UInt16) -> Data {
        Data(address.prefix(4).reversed()) + Data([UInt8(port & 255), UInt8(port >> 8)])
    }

    /// A file request over the WebSocket, as hex text: `08 EE 00 00 00 1A 07 12 00`, the offset to
    /// resume from and the recording's ID (both 32-bit little-endian), then `1B`. Eighteen bytes and no
    /// checksum, as the official app sends it.
    public static func fileRequest(recordingID: UInt32, offset: UInt32 = 0) -> String {
        var bytes: [UInt8] = [0x08, 0xee, 0x00, 0x00, 0x00, 0x1a, 0x07, 0x12, 0x00]
        bytes += [UInt8](littleEndian32(offset)) + [UInt8](littleEndian32(recordingID)) + [0x1b]
        return hex(bytes)
    }

    /// The recording and offset a file request asks for (the simulator, tests).
    public static func parseFileRequest(_ text: String) -> (recordingID: UInt32, offset: UInt32)? {
        guard let b = bytes(hex: text).map([UInt8].init), b.count == 18, b[0] == 0x08, b[1] == 0xee, b[5] == 0x1a, b[6] == 0x07,
              b[7] == 18, b[17] == 0x1b, let offset = try? b.le32(at: 9), let id = try? b.le32(at: 13) else { return nil }
        return (id, offset)
    }

    public static func hex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Bytes from hex text, ignoring spaces; nil when it isn't hex.
    public static func bytes(hex text: String) -> Data? {
        let digits = text.filter { !$0.isWhitespace }
        guard !digits.isEmpty, digits.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: digits.count / 2)
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}

/// Joins and leaves the recorder's own network. On iPhone that's `NEHotspotConfiguration`
/// (`SystemSoundcoreHotspot`), which needs the Hotspot Configuration entitlement and the app in the
/// foreground; the simulator has its own.
@MainActor
public protocol SoundcoreHotspot: AnyObject {
    /// Joins the network and returns once this device has an address on the recorder's subnet.
    func join(ssid: String, password: String, recorder host: String) async throws
    /// Leaves it and forgets it.
    func leave(ssid: String)
}

public enum SoundcoreHotspotError: LocalizedError, Equatable {
    /// This app can't join networks: no hotspot entitlement in this build, or not on this device.
    case unavailable
    /// The person declined the system's prompt.
    case declined
    /// The network didn't appear, or joining it failed.
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "This build of Daybook can’t join the recorder’s Wi‑Fi."
        case .declined: return "Joining the recorder’s Wi‑Fi was declined."
        case .failed(let reason): return "The recorder’s Wi‑Fi couldn’t be joined: \(reason)"
        }
    }
}

/// What Wi‑Fi Fast Transfer needs from the app. Shared by reference, so the app can fill it in after
/// the devices exist. With no hotspot (the Mac, tests that don't ask), every transfer is over Bluetooth.
@MainActor
public final class SoundcoreWiFiHooks {
    /// Joins and leaves the recorder's network.
    public var hotspot: (any SoundcoreHotspot)?
    /// Daybook is in the foreground. Fast Transfer runs only then: iOS joins networks for an app in
    /// front and suspends one in the background. Leaving the foreground ends it, and the transfer
    /// carries on over Bluetooth.
    public var isForeground = true {
        didSet {
            guard isForeground != oldValue else { return }
            observers.forEach { $0(isForeground) }
        }
    }
    /// Where the keep-alive goes, for a recorder's address: its port 32003, or the simulator's own.
    public var keepAlivePort: (String) -> UInt16 = { _ in SoundcoreWiFi.keepAlivePort }
    /// The connection to the recorder must go over Wi‑Fi. The simulator's is on loopback.
    public var requiresWiFi = true
    /// The app's build. A join that fails because this build can't join networks isn't tried again
    /// until the build changes.
    public var build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    private var observers: [(Bool) -> Void] = []

    public init() {}

    /// Calls `observer` whenever the app moves to or from the foreground.
    public func observeForeground(_ observer: @escaping (Bool) -> Void) { observers.append(observer) }
}
