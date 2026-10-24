import AVFoundation
import AudioToolbox
import CryptoKit
import DaybookIntelligence
import XCTest
@testable import DaybookDevices

/// The Soundcore wire format: framing, parsers, cryptography, and the Opus path, with malformed
/// input that must be rejected without crashing.
final class SoundcoreProtocolTests: XCTestCase {
    func testKnownStatusCommandAndFragmentedRecovery() throws {
        XCTAssertEqual(try SoundcorePacket.command(type: 1, id: 1), Data([8, 238, 0, 0, 0, 1, 1, 10, 0, 2]))
        let response = SoundcorePacket.frame(type: 1, command: 3, payload: Data([0, 9]))
        var broken = response; broken[broken.count - 1] ^= 1
        var parser = SoundcorePacketBuffer()
        XCTAssertTrue(parser.append(Data([5, 6, 9])).isEmpty)
        XCTAssertTrue(parser.append(Data(response.prefix(7))).isEmpty)
        let frames = parser.append(Data(response.dropFirst(7)) + broken + response)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames.first?.payload, Data([0, 9]))
        XCTAssertEqual(parser.rejectedFrames, 1)
    }

    func testBatteryBucketsAndStorageUnits() throws {
        var bytes = [UInt8](repeating: 0, count: 56)
        bytes[1] = 0; bytes[38] = 9; bytes[2] = 1; bytes[50] = 1
        bytes.replaceSubrange(24..<28, with: littleEndian32(1_048_576))
        bytes.replaceSubrange(28..<32, with: littleEndian32(524_288))
        let info = try SoundcoreDeviceInfo.parse(Data(bytes))
        XCTAssertEqual(info.microphoneBattery, 10); XCTAssertEqual(info.caseBattery, 100)
        XCTAssertTrue(info.microphoneCharging); XCTAssertTrue(info.isRecording)
        XCTAssertEqual(info.totalBytes, 1_073_741_824)
        XCTAssertEqual(info.freeBytes, 536_870_912)
        XCTAssertEqual(SoundcoreDeviceInfo.battery(80), 80)
        XCTAssertNil(SoundcoreDeviceInfo.battery(255))
        XCTAssertThrowsError(try SoundcoreDeviceInfo.parse(Data([0])))
    }

    func testStatusTextIgnoresControlAndNonASCIIBytes() throws {
        var bytes = [UInt8](repeating: 0, count: 56)
        bytes.replaceSubrange(8..<16, with: [0x41, 0x0a, 0xff, 0x42, 0x07, 0x43, 0x20, 0x00])
        let info = try SoundcoreDeviceInfo.parse(Data(bytes))
        XCTAssertEqual(info.serial, "ABC")
        // Free space larger than the total is clamped rather than reported as more than exists.
        bytes.replaceSubrange(24..<28, with: littleEndian32(10))
        bytes.replaceSubrange(28..<32, with: littleEndian32(99))
        XCTAssertEqual(try SoundcoreDeviceInfo.parse(Data(bytes)).freeBytes, 10 * 1_024)
    }

    func testFileListBothLayoutsAndActiveRecording() throws {
        var payload = Data([1, 0]); payload.append(littleEndian32(1_780_000_000))
        payload.append(littleEndian32(1_780_000_020)); payload.append(littleEndian32(160))
        payload.append(littleEndian32(1_780_000_500)); payload.append(Data(repeating: 0, count: 4))
        let page = try SoundcoreRecording.page(SoundcorePacket(type: 0x1b, command: 0x0e, status: 1, payload: payload))
        XCTAssertEqual(page.recordings.count, 1)
        XCTAssertEqual(page.recordings[0].size, 160)
        XCTAssertEqual(page.recordings[0].endTimestamp, 1_780_000_020)
        XCTAssertEqual(page.active, 1_780_000_500)

        var short = Data([1, 0]); short.append(littleEndian32(1_780_000_000)); short.append(littleEndian32(8_000))
        short.append(Data(repeating: 0, count: 8))
        let legacy = try SoundcoreRecording.page(SoundcorePacket(type: 0x1a, command: 0x0e, status: 1, payload: short))
        XCTAssertNil(legacy.recordings[0].endTimestamp)
        XCTAssertNil(legacy.active)
        XCTAssertEqual(legacy.recordings[0].length, .estimated(1))
    }

    func testSlicesRoundTripAndBounds() throws {
        let slice = SoundcoreAudioSlice.encode(sequence: 42, audio: Data(repeating: 5, count: 160))
        XCTAssertEqual(slice.count, SoundcoreAudioSlice.size)
        XCTAssertEqual(try SoundcoreAudioSlice.parse(slice).first?.sequence, 42)
        XCTAssertEqual(try SoundcoreAudioSlice.parse(slice + slice).count, 2)
        XCTAssertEqual(try SoundcoreAudioSlice.parse(slice + slice.dropLast()).count, 2, "The last trailer may be missing")
        XCTAssertThrowsError(try SoundcoreAudioSlice.parse(slice.dropLast(2)))
        XCTAssertThrowsError(try SoundcoreAudioSlice.parse(Data()))
    }

    /// Hostile lengths and counts are rejected, never read past the end.
    func testMalformedListsAreRejected() {
        let cases: [Data] = [
            Data(),                                   // empty
            Data([1, 0, 1, 2, 3]),                    // shorter than the header
            Data([0xff, 0xff]) + Data(repeating: 0, count: 8),   // a count far beyond the payload
            Data([2, 0]) + Data(repeating: 1, count: 20),         // two 12-byte entries promised, too few bytes
            Data([0x89, 0x13]) + Data(repeating: 0, count: 100)   // over the 5,000-entry limit
        ]
        for payload in cases {
            XCTAssertThrowsError(try SoundcoreRecording.page(SoundcorePacket(type: 0x1b, command: 0x0e, status: 1, payload: payload)))
        }
        XCTAssertThrowsError(try SoundcoreRecording.page(SoundcorePacket(type: 0x01, command: 0x0e, status: 1, payload: Data(count: 20))),
                             "Only list packets are lists")
        XCTAssertThrowsError(try [UInt8]([1, 2, 3]).le32(at: 0))
        XCTAssertThrowsError(try [UInt8]([1, 2, 3, 4]).le32(at: -1))
        XCTAssertEqual(try [UInt8]([1, 0, 0, 0]).le32(at: 0), 1)
    }

    /// Random bytes through the frame buffer and every parser: nothing traps, and the buffer stays bounded.
    func testRandomInputNeverCrashesTheParsers() {
        var generator = SeededGenerator(seed: 0x5EED)
        var buffer = SoundcorePacketBuffer()
        for round in 0..<2_000 {
            let count = Int.random(in: 0...400, using: &generator)
            var bytes = (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
            if round % 3 == 0, bytes.count > 9 { bytes[0] = 9; bytes[1] = 255; bytes[2] = 0; bytes[3] = 0 }
            for packet in buffer.append(Data(bytes)) {
                _ = try? SoundcoreDeviceInfo.parse(packet.payload)
                _ = try? SoundcoreRecording.page(packet)
                _ = try? SoundcoreAudioSlice.parse(packet.payload)
            }
            _ = try? SoundcoreDeviceInfo.parse(Data(bytes))
            _ = try? SoundcoreAudioSlice.parse(Data(bytes))
            _ = try? SoundcoreRecording.page(SoundcorePacket(type: 0x1b, command: 0x0e, status: 1, payload: Data(bytes)))
            _ = try? SoundcoreCrypto().fileKey(from: Data(bytes), expectedID: 1)
            _ = try? SoundcoreCrypto().completeHandshake(Data(bytes))
        }
        XCTAssertLessThanOrEqual(buffer.rejectedFrames, 2_000 * 400)
        XCTAssertTrue(buffer.append(Data(repeating: 0, count: 1_048_577)).isEmpty, "Oversized notifications are dropped")
    }

    func testAESCTRMatchesNISTVector() throws {
        let key = hex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4")
        let iv = hex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
        let plaintext = hex("6bc1bee22e409f96e93d7e117393172a")
        let encrypted = try SoundcoreCrypto.crypt(plaintext, key: key, iv: iv)
        XCTAssertEqual(encrypted, hex("601ec313775789a5b7a7f504bbf3d228"))
        XCTAssertEqual(try SoundcoreCrypto.crypt(encrypted, key: key, iv: iv), plaintext)
        XCTAssertThrowsError(try SoundcoreCrypto.crypt(plaintext, key: Data(count: 16), iv: iv))
    }

    func testVerifiedEphemeralExchangeAndFileKey() throws {
        let crypto = SoundcoreCrypto()
        let peer = P256.KeyAgreement.PrivateKey()
        let appPublic = try P256.KeyAgreement.PublicKey(x963Representation: crypto.publicKey)
        let secret = try peer.sharedSecretFromKeyAgreement(with: appPublic)
        try crypto.completeHandshake(peer.publicKey.x963Representation + secret.withUnsafeBytes { Data($0) })
        XCTAssertTrue(crypto.isReady)
        let session = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data([1, 2, 3]),
                                                     sharedInfo: Data([1, 2, 3]), outputByteCount: 32).withUnsafeBytes { Data($0) }
        let fileKey = Data(repeating: 7, count: 32), nonce = Data(repeating: 9, count: 16)
        let wrapped = try SoundcoreCrypto.crypt(Data("soundcored3200".utf8) + fileKey, key: session, iv: nonce)
        var header = littleEndian32(123); header.append(littleEndian32(160)); header.append(nonce)
        header.append(wrapped); header.append(nonce); header.append(0)
        let unwrapped = try crypto.fileKey(from: header, expectedID: 123)
        XCTAssertEqual(unwrapped.key, fileKey)
        XCTAssertEqual(unwrapped.expectedBytes, 160)
        XCTAssertThrowsError(try crypto.fileKey(from: header, expectedID: 456), "A key for another recording")
        var tampered = header; tampered[30] ^= 1
        XCTAssertThrowsError(try crypto.fileKey(from: tampered, expectedID: 123), "A key that doesn't unwrap to the expected prefix")
        crypto.reset(); XCTAssertFalse(crypto.isReady)
        XCTAssertThrowsError(try crypto.completeHandshake(peer.publicKey.x963Representation + Data(repeating: 0, count: 32)))
    }

    func testSimulatorFixturesDecodeThroughTheNativeOpusPath() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let frames = SimulatedSoundcore.frames(seconds: 1)
        XCTAssertGreaterThanOrEqual(frames.count, 49)
        XCTAssertTrue(frames.allSatisfy { $0.count == 160 })
        let decoder = try SoundcoreOpusDecoder(outputURL: url)
        for frame in frames { try decoder.append(frame) }
        try decoder.finish()
        let output = try AudioSlabReader.samples(url: url, from: 0, to: 1)
        XCTAssertGreaterThan(output.count, 15_000)
        let energy = output.reduce(0.0) { $0 + Double($1 * $1) } / Double(output.count)
        XCTAssertGreaterThan(energy, 0.01)
        XCTAssertLessThan(energy, 0.08)
        XCTAssertThrowsError(try decoder.append(Data(repeating: 0, count: 159)), "Only 160-byte packets")
    }

    private func hex(_ string: String) -> Data {
        let chars = Array(string)
        return Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...($0 + 1)]), radix: 16)! })
    }
}

/// Deterministic randomness for the parser fuzz test.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
