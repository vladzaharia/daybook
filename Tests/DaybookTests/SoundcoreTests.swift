import AVFoundation
import AudioToolbox
import CryptoKit
import XCTest
@testable import Daybook

final class SoundcoreTests: XCTestCase {
    func testKnownStatusCommandAndFragmentedRecovery() throws {
        XCTAssertEqual(try SoundcorePacket.command(type: 1, id: 1), Data([8,238,0,0,0,1,1,10,0,2]))
        let response = rx(type: 1, id: 3, payload: Data([0,9]))
        var broken = response; broken[broken.count - 1] ^= 1
        var parser = SoundcorePacketBuffer()
        XCTAssertTrue(parser.append(Data([5,6,9])).isEmpty)
        XCTAssertTrue(parser.append(Data(response.prefix(7))).isEmpty)
        let frames = parser.append(Data(response.dropFirst(7)) + broken + response)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames.first?.payload, Data([0,9]))
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

    func testFileListAndSliceBounds() throws {
        var payload = Data([1,0]); payload.append(littleEndian32(1_780_000_000))
        payload.append(littleEndian32(1_780_000_020)); payload.append(littleEndian32(160))
        payload.append(Data(repeating: 0, count: 8))
        let packet = SoundcorePacket(type: 0x1b, command: 0x0e, status: 1, payload: payload)
        let files = try SoundcoreRecording.parseList(packet)
        XCTAssertEqual(files.count, 1); XCTAssertEqual(files[0].size, 160)
        XCTAssertEqual(files[0].endTimestamp, 1_780_000_020)
        var slice = littleEndian32(42); slice.append(0); slice.append(Data(repeating: 5, count: 160))
        XCTAssertEqual(try SoundcoreAudioSlice.parse(slice).first?.sequence, 42)
        slice.append(0)
        XCTAssertEqual(try SoundcoreAudioSlice.parse(slice + slice).count, 2)
        XCTAssertThrowsError(try SoundcoreAudioSlice.parse(slice.dropLast(2)))
    }

    func testAESCTRMatchesNISTVector() throws {
        let key = hex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4")
        let iv = hex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
        let plaintext = hex("6bc1bee22e409f96e93d7e117393172a")
        let encrypted = try SoundcoreCrypto.crypt(plaintext, key: key, iv: iv)
        XCTAssertEqual(encrypted, hex("601ec313775789a5b7a7f504bbf3d228"))
        XCTAssertEqual(try SoundcoreCrypto.crypt(encrypted, key: key, iv: iv), plaintext)
    }

    func testVerifiedEphemeralExchangeAndFileKey() throws {
        let crypto = SoundcoreCrypto()
        let peer = P256.KeyAgreement.PrivateKey()
        let appPublic = try P256.KeyAgreement.PublicKey(x963Representation: crypto.publicKey)
        let secret = try peer.sharedSecretFromKeyAgreement(with: appPublic)
        let secretData = secret.withUnsafeBytes { Data($0) }
        try crypto.completeHandshake(peer.publicKey.x963Representation + secretData)
        XCTAssertTrue(crypto.isReady)
        let session = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data([1,2,3]),
            sharedInfo: Data([1,2,3]), outputByteCount: 32).withUnsafeBytes { Data($0) }
        let fileKey = Data(repeating: 7, count: 32), nonce = Data(repeating: 9, count: 16)
        let wrapped = try SoundcoreCrypto.crypt(Data("soundcored3200".utf8) + fileKey, key: session, iv: nonce)
        var header = littleEndian32(123); header.append(littleEndian32(160)); header.append(nonce)
        header.append(wrapped); header.append(nonce); header.append(0)
        let unwrapped = try crypto.fileKey(from: header, expectedID: 123)
        XCTAssertEqual(unwrapped.key, fileKey)
        XCTAssertThrowsError(try crypto.fileKey(from: header, expectedID: 456))
        crypto.reset(); XCTAssertFalse(crypto.isReady)
        XCTAssertThrowsError(try crypto.completeHandshake(peer.publicKey.x963Representation + Data(repeating: 0, count: 32)))
    }

    func testNativeOpusRoundTripFromGeneratedTone() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let pcm = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatOpus,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 960, mBytesPerFrame: 0,
            mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        let opus = try XCTUnwrap(AVAudioFormat(streamDescription: &description))
        let encoder = try XCTUnwrap(AVAudioConverter(from: pcm, to: opus)); encoder.bitRate = 32_000
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 48_000)); input.frameLength = 48_000
        for index in 0..<48_000 { input.floatChannelData![0][index] = sin(Float(index) * 2 * .pi * 440 / 48_000) * 0.25 }
        let decoder = try SoundcoreOpusDecoder(outputURL: url)
        var supplied = false, packets = 0
        for _ in 0..<10 {
            let compressed = AVAudioCompressedBuffer(format: opus, packetCapacity: 60, maximumPacketSize: 1_275)
            var error: NSError?
            let status = encoder.convert(to: compressed, error: &error) { _, state in
                if supplied { state.pointee = .endOfStream; return nil }
                supplied = true; state.pointee = .haveData; return input
            }
            if let error { throw error }
            let descriptions = try XCTUnwrap(compressed.packetDescriptions)
            for index in 0..<Int(compressed.packetCount) {
                let packet = descriptions[index]
                XCTAssertLessThanOrEqual(packet.mDataByteSize, 160)
                guard packet.mDataByteSize <= 160 else { continue }
                var data = Data(bytes: compressed.data.advanced(by: Int(packet.mStartOffset)), count: Int(packet.mDataByteSize))
                data.append(Data(repeating: 0, count: 160 - data.count))
                try decoder.append(data); packets += 1
            }
            if status == .endOfStream { break }
        }
        try decoder.finish()
        XCTAssertGreaterThanOrEqual(packets, 49)
        let output = try AudioSlabReader.samples(url: url, from: 0, to: 1)
        XCTAssertGreaterThan(output.count, 15_000)
        let energy = output.reduce(0.0) { $0 + Double($1 * $1) } / Double(output.count)
        XCTAssertGreaterThan(energy, 0.01)
        XCTAssertLessThan(energy, 0.08)
    }

    private func rx(type: UInt8, id: UInt8, payload: Data) -> Data {
        let size = payload.count + 10
        var frame = Data([9,255,0,0,1,type,id,UInt8(size & 255),UInt8(size >> 8)])
        frame.append(payload); frame.append(frame.reduce(UInt8(0), &+)); return frame
    }

    private func hex(_ string: String) -> Data {
        let chars = Array(string)
        return Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...($0 + 1)]), radix: 16)! })
    }
}
