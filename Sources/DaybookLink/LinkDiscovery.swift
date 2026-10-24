import CryptoKit
import Foundation
@preconcurrency import Network

/// What the Mac puts in its Bonjour TXT record.
///
/// The library and device IDs are never advertised as they are: each is a salted tag,
/// `SHA-256(label ‖ salt ‖ id)` truncated to 8 bytes, with a fresh salt every time the Mac starts
/// advertising. A phone that knows the IDs can recognise its library and its paired Mac; other
/// devices on the network can't read them or follow the Mac from one network to the next.
struct LinkAdvertisement: Equatable {
    var salt: Data
    var libraryTag: Data?
    var deviceTag: Data
    var versions: LinkVersionRange
    var isPairing: Bool

    init(salt: Data = PasskeyExchange.randomBytes(8), libraryID: UUID?, deviceID: UUID, versions: ClosedRange<Int>, isPairing: Bool) {
        self.salt = salt
        libraryTag = libraryID.map { Self.tag(label: "library", salt: salt, id: $0) }
        deviceTag = Self.tag(label: "device", salt: salt, id: deviceID)
        self.versions = LinkVersionRange(versions)
        self.isPairing = isPairing
    }

    private init(salt: Data, libraryTag: Data?, deviceTag: Data, versions: LinkVersionRange, isPairing: Bool) {
        self.salt = salt
        self.libraryTag = libraryTag
        self.deviceTag = deviceTag
        self.versions = versions
        self.isPairing = isPairing
    }

    static func tag(label: String, salt: Data, id: UUID) -> Data {
        var input = Data("DaybookLink \(label) tag v1".utf8)
        input.append(salt)
        input.append(PasskeyExchange.bytes(of: id))
        return Data(SHA256.hash(data: input).prefix(8))
    }

    func matches(libraryID: UUID) -> Bool { libraryTag == Self.tag(label: "library", salt: salt, id: libraryID) }
    func matches(deviceID: UUID) -> Bool { deviceTag == Self.tag(label: "device", salt: salt, id: deviceID) }

    var entries: [String: String] {
        var entries = [
            "s": Self.hex(salt),
            "d": Self.hex(deviceTag),
            "v": "\(versions.min)-\(versions.max)",
            "p": isPairing ? "1" : "0"
        ]
        if let libraryTag { entries["l"] = Self.hex(libraryTag) }
        return entries
    }

    init?(entries: [String: String]) {
        guard let salt = entries["s"].flatMap(Self.unhex), salt.count >= 8,
              let deviceTag = entries["d"].flatMap(Self.unhex), deviceTag.count == 8 else { return nil }
        let parts = (entries["v"] ?? "1-1").split(separator: "-").compactMap { Int($0) }
        let versions = parts.count == 2 ? LinkVersionRange(min: parts[0], max: parts[1]) : LinkVersionRange(1...1)
        self.init(salt: salt, libraryTag: entries["l"].flatMap(Self.unhex), deviceTag: deviceTag, versions: versions,
                  isPairing: entries["p"] == "1")
    }

    var txtRecord: NWTXTRecord { NWTXTRecord(entries) }

    init?(txtRecord: NWTXTRecord) { self.init(entries: txtRecord.dictionary) }

    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    private static func unhex(_ text: String) -> Data? {
        guard text.count.isMultiple(of: 2) else { return nil }
        var data = Data()
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    /// What a phone makes of one browse result.
    func discovered(serviceName: String, endpoint: NWEndpoint, libraryID: UUID?, pairedMacs: [UUID]) -> LinkDiscoveredMac {
        LinkDiscoveredMac(serviceName: serviceName, endpoint: LinkEndpoint(endpoint),
                          pairedDeviceID: pairedMacs.first { matches(deviceID: $0) },
                          sharesLibrary: libraryID.flatMap { id in libraryTag.map { _ in matches(libraryID: id) } },
                          isPairing: isPairing, protocolVersions: versions.range)
    }
}
