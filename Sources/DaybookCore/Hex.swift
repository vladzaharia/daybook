import Foundation

// Bytes as lowercase hexadecimal, and back: digests, key IDs, and identifiers that travel as text (sync names,
// keychain accounts, a recorder's Wi‑Fi credentials). One spelling, so every module writes the same text for the
// same bytes.

extension Sequence where Element == UInt8 {
    /// "00ff1a": two lowercase digits a byte, nothing between them.
    public var lowercaseHex: String {
        let digits: [UInt8] = Array("0123456789abcdef".utf8)
        var text: [UInt8] = []
        text.reserveCapacity(underestimatedCount * 2)
        for byte in self {
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: text, as: UTF8.self)
    }
}

extension Data {
    /// The bytes `hex` spells: two digits a byte, upper or lower case. Nil for an odd number of digits or
    /// anything that isn't a hexadecimal digit (spaces and a "0x" prefix included).
    public init?(hex: String) {
        let utf8 = Array(hex.utf8)
        guard utf8.count % 2 == 0 else { return nil }
        func value(_ digit: UInt8) -> UInt8? {
            switch digit {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return digit - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): return digit - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): return digit - UInt8(ascii: "A") + 10
            default: return nil
            }
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(utf8.count / 2)
        var index = 0
        while index < utf8.count {
            guard let high = value(utf8[index]), let low = value(utf8[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        self.init(bytes)
    }
}
