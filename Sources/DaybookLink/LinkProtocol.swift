import CryptoKit
import Foundation

/// Wire constants for DaybookLink. Changing any of these is a protocol change; see docs/link.md.
public enum LinkProtocol {
    /// Bonjour service type the Mac advertises and the phone browses. Must also be listed in each
    /// app's `NSBonjourServices`.
    public static let serviceType = "_daybook-link._tcp"

    /// Session protocol versions this build speaks. Peers settle on the highest version both speak.
    public static let supportedVersions: ClosedRange<Int> = 1...1

    /// The version written on messages sent before a version is agreed (hello, welcome, pairing).
    /// Those messages never change shape incompatibly, so every version can read them.
    static let baselineVersion = 1

    /// Version of the pairing exchange (`pair.begin.protocolVersion`).
    static let pairingVersion = 1

    /// Digits in the code the Mac shows.
    public static let pairingCodeDigits = 6

    /// One commit/reveal round per bit of the code: 10^6 < 2^20.
    static let pairingRounds = 20

    /// Largest frame either side accepts. Messages are small JSON documents.
    static let maxFrameLength = 256 * 1024

    /// TLS PSK identity of pairing connections. Its key is public and gives no authentication; it
    /// only lets a phone that isn't paired yet open the same TLS listener. Pairing then
    /// authenticates on its own (see `PasskeyExchange`) and every session authenticates with its
    /// own key bound to the TLS session.
    static let pairingPSKIdentity = Data("daybook-link-pairing-v1".utf8)
    static let pairingPSK = Data(SHA256.hash(data: Data("DaybookLink public pairing PSK v1; not a secret".utf8)))

    /// TLS exporter label used to bind session authentication to one TLS session (RFC 5705).
    static let exporterLabel = "EXPORTER-DaybookLink-session-v1"

    static let sessionAuthLabel = Data("DaybookLink session auth v1".utf8)
}
