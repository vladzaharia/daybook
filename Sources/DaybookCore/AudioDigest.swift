import Foundation

/// Streaming SHA-256 avoids loading long recordings into memory and needs no external package.
public enum AudioDigest {
    public static func sha256(fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation()
            hasher.update(Array(bytes))
        }
        return hasher.finish().map { String(format: "%02x", $0) }.joined()
    }
    public static func sha256(data: Data) -> String {
        var hasher = SHA256(); hasher.update(Array(data))
        return hasher.finish().map { String(format: "%02x", $0) }.joined()
    }
}

private struct SHA256 {
    private var state: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    private var pending: [UInt8] = []
    private var count: UInt64 = 0
    private static let k: [UInt32] = [
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2]
    mutating func update(_ bytes: [UInt8]) {
        count += UInt64(bytes.count)
        var buffer = pending; buffer.append(contentsOf: bytes)
        let end = buffer.count - buffer.count % 64
        for offset in stride(from: 0, to: end, by: 64) { compress(buffer, offset: offset) }
        pending = Array(buffer[end...])
    }
    mutating func finish() -> [UInt8] {
        let bitCount = count * 8
        pending.append(0x80)
        while pending.count % 64 != 56 { pending.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { pending.append(UInt8(truncatingIfNeeded: bitCount >> shift)) }
        for offset in stride(from: 0, to: pending.count, by: 64) { compress(pending, offset: offset) }
        return state.flatMap { value in [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)] }
    }
    private func rotate(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
    private mutating func compress(_ bytes: [UInt8], offset: Int) {
        var w = Array(repeating: UInt32(0), count: 64)
        for i in 0..<16 {
            let j = offset + i * 4
            w[i] = UInt32(bytes[j]) << 24 | UInt32(bytes[j + 1]) << 16 | UInt32(bytes[j + 2]) << 8 | UInt32(bytes[j + 3])
        }
        for i in 16..<64 {
            let s0 = rotate(w[i - 15], 7) ^ rotate(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotate(w[i - 2], 17) ^ rotate(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var a = state[0], b = state[1], c = state[2], d = state[3], e = state[4], f = state[5], g = state[6], h = state[7]
        for i in 0..<64 {
            let s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
            let choice = (e & f) ^ (~e & g)
            let t1 = h &+ s1 &+ choice &+ Self.k[i] &+ w[i]
            let s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 &+ majority
            h = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
        }
        let working = [a,b,c,d,e,f,g,h]
        for i in state.indices { state[i] = state[i] &+ working[i] }
    }
}
