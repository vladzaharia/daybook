import AVFoundation
import AudioToolbox
import CryptoKit
import DaybookIntelligence
import DaybookTestSupport
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

    // MARK: Wi‑Fi Fast Transfer

    func testAccessPointRequestAndReply() throws {
        let request = try SoundcoreWiFi.accessPointRequest(ssid: "WiFi-1730000000000", password: "4815162342108")
        XCTAssertEqual([UInt8](request.prefix(1)), [18])
        XCTAssertEqual(String(decoding: request.dropFirst().prefix(18), as: UTF8.self), "WiFi-1730000000000")
        XCTAssertEqual(request[request.startIndex + 19], 13)
        XCTAssertEqual(String(decoding: request.suffix(13), as: UTF8.self), "4815162342108")
        XCTAssertEqual(SoundcoreWiFi.credentials(inRequest: request)?.ssid, "WiFi-1730000000000")
        XCTAssertEqual(SoundcoreWiFi.credentials(inRequest: request)?.password, "4815162342108")
        XCTAssertThrowsError(try SoundcoreWiFi.accessPointRequest(ssid: "", password: "4815162342108"))
        XCTAssertThrowsError(try SoundcoreWiFi.accessPointRequest(ssid: "WiFi-1", password: "short"))

        // The reply's address is in reverse byte order, its port little-endian (full frame offsets 9–14).
        let frame = SoundcorePacket.frame(type: 0x1a, command: 0x05, payload: Data([1, 4, 168, 192, 0xbb, 0x01]))
        XCTAssertEqual(frame.count, 16)
        XCTAssertEqual([UInt8](frame[9..<15]), [1, 4, 168, 192, 0xbb, 0x01])
        let packet = SoundcorePacket(type: 0x1a, command: 0x05, status: 1, payload: Data([1, 4, 168, 192, 0xbb, 0x01]))
        let endpoint = try SoundcoreWiFi.endpoint(from: packet)
        XCTAssertEqual(endpoint.host, "192.168.4.1")
        XCTAssertEqual(endpoint.port, 443)
        XCTAssertEqual(SoundcoreWiFi.endpointPayload(address: [192, 168, 4, 1], port: 443), packet.payload)
        XCTAssertThrowsError(try SoundcoreWiFi.endpoint(from: SoundcorePacket(type: 0x1a, command: 0x05, status: 0, payload: packet.payload)))
        XCTAssertThrowsError(try SoundcoreWiFi.endpoint(from: SoundcorePacket(type: 0x1a, command: 0x05, status: 1, payload: Data([1, 2]))))

        let credentials = SoundcoreWiFi.credentials(at: Date(timeIntervalSince1970: 1_730_000_000.25))
        XCTAssertEqual(credentials.ssid, "WiFi-1730000000250")
        XCTAssertEqual(credentials.password.count, 13)
        XCTAssertTrue(credentials.password.allSatisfy(\.isNumber))
        XCTAssertNoThrow(try SoundcoreWiFi.accessPointRequest(ssid: credentials.ssid, password: credentials.password))
    }

    func testFileRequestOverWiFiIsEighteenBytesOfHexText() throws {
        let text = SoundcoreWiFi.fileRequest(recordingID: 0x6720_1a2b, offset: 160)
        XCTAssertEqual(text, "08ee0000001a071200" + "a0000000" + "2b1a2067" + "1b")
        XCTAssertEqual(SoundcoreWiFi.bytes(hex: text)?.count, 18)
        let parsed = try XCTUnwrap(SoundcoreWiFi.parseFileRequest(text))
        XCTAssertEqual(parsed.recordingID, 0x6720_1a2b)
        XCTAssertEqual(parsed.offset, 160)
        XCTAssertNil(SoundcoreWiFi.parseFileRequest("FINISH"))
        XCTAssertNil(SoundcoreWiFi.parseFileRequest(String(text.dropLast(2)) + "00"))
        XCTAssertNil(SoundcoreWiFi.bytes(hex: "0g"))
        XCTAssertEqual(SoundcoreWiFi.bytes(hex: "09 ff"), Data([9, 255]))
    }

    func testWebSocketFramesRoundTripMaskedAndAtEveryLengthForm() throws {
        for count in [0, 5, 125, 126, 65_535, 65_536, 70_000] {
            let payload = Data((0..<count).map { UInt8($0 & 255) })
            for mask in [nil, [UInt8]([1, 2, 3, 4])] {
                var buffer = WebSocketFrame.encode(opcode: WebSocketFrame.binary, payload: payload, mask: mask)
                buffer.append(contentsOf: [0x81])
                let frame = try XCTUnwrap(WebSocketFrame.decode(&buffer), "\(count)")
                XCTAssertTrue(frame.fin)
                XCTAssertEqual(frame.opcode, WebSocketFrame.binary)
                XCTAssertEqual(frame.masked, mask != nil)
                XCTAssertEqual(frame.payload, payload)
                XCTAssertEqual(buffer, Data([0x81]), "only the next frame's start is left")
            }
        }
        // Partial frames wait; a frame claiming more than the limit is refused.
        var partial = WebSocketFrame.encode(opcode: WebSocketFrame.text, payload: Data("FINISH".utf8)).dropLast()
        var data = Data(partial)
        XCTAssertNil(try WebSocketFrame.decode(&data))
        partial = Data([0x82, 127, 0, 0, 0, 0, 0x7f, 0xff, 0xff, 0xff])
        data = Data(partial)
        XCTAssertThrowsError(try WebSocketFrame.decode(&data))
        // RFC 6455's example key.
        XCTAssertEqual(WebSocketFrame.accept(for: "dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    func testBehaviorAFragmentedMessageIsPutBackTogetherAndRefusedPastItsLimit() throws {
        var messages = WebSocketMessages(limit: 10)
        XCTAssertNil(try messages.add(fin: false, opcode: WebSocketFrame.binary, payload: Data([1, 2, 3])))
        XCTAssertNil(try messages.add(fin: false, opcode: 0, payload: Data([4, 5, 6])))
        let whole = try XCTUnwrap(messages.add(fin: true, opcode: 0, payload: Data([7, 8, 9, 10])))
        XCTAssertEqual(whole.opcode, WebSocketFrame.binary)
        XCTAssertEqual(whole.payload, Data(1...10), "exactly the limit is whole")
        let text = try XCTUnwrap(messages.add(fin: true, opcode: WebSocketFrame.text, payload: Data("OK".utf8)))
        XCTAssertEqual(text.payload, Data("OK".utf8))

        // Each frame small, the message without end: refused once it passes the limit, not kept growing.
        var flood = WebSocketMessages(limit: 10)
        XCTAssertNil(try flood.add(fin: false, opcode: WebSocketFrame.binary, payload: Data(count: 4)))
        XCTAssertNil(try flood.add(fin: false, opcode: 0, payload: Data(count: 4)))
        XCTAssertThrowsError(try flood.add(fin: false, opcode: 0, payload: Data(count: 4))) { error in
            XCTAssertEqual(error as? WebSocketError, .protocolError("A message was too large."))
        }
        var single = WebSocketMessages(limit: 10)
        XCTAssertThrowsError(try single.add(fin: true, opcode: WebSocketFrame.binary, payload: Data(count: 11)))
        var orphan = WebSocketMessages()
        XCTAssertThrowsError(try orphan.add(fin: true, opcode: 0, payload: Data([1])), "nothing to continue")
        XCTAssertEqual(orphan.limit, WebSocketFrame.maximumPayload, "a message may be as large as a frame")
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

    // MARK: Tolerant list pages

    private let listNow = Date(timeIntervalSince1970: 1_790_000_000)

    private func listPacket(_ type: UInt8, count: Int, entries: [(id: UInt32, end: UInt32, size: UInt32)], trailer: Data = Data(repeating: 0, count: 8),
                            extra: Data = Data()) -> SoundcorePacket {
        var payload = Data([UInt8(count & 255), UInt8(count >> 8)])
        for entry in entries {
            payload.append(littleEndian32(entry.id))
            if type == 0x1b { payload.append(littleEndian32(entry.end)) }
            payload.append(littleEndian32(entry.size))
        }
        return SoundcorePacket(type: type, command: 0x0e, status: 1, payload: payload + trailer + extra)
    }

    func testBehaviorAPageSmallerThanTenBytesWithNoEntriesIsAnEmptyList() {
        for trailer in [8, 4, 0] {
            let page = SoundcoreRecording.read(listPacket(0x1b, count: 0, entries: [], trailer: Data(repeating: 0, count: trailer)), now: listNow)
            XCTAssertTrue(page.isValid, "trailer \(trailer)")
            XCTAssertTrue(page.recordings.isEmpty)
            XCTAssertEqual(page.trailerBytes, trailer)
            XCTAssertEqual(page.isOdd, trailer != 8)
        }
        XCTAssertFalse(SoundcoreRecording.read(SoundcorePacket(type: 0x1b, command: 0x0e, status: 1, payload: Data([0])), now: listNow).isValid)
        XCTAssertFalse(SoundcoreRecording.read(SoundcorePacket(type: 0x1b, command: 0x0e, status: 1, payload: Data()), now: listNow).isValid)
    }

    func testBehaviorOnlyWholeEntriesAreReadWhateverTheCountSays() {
        let entries = (0..<3).map { (id: 1_780_000_000 + UInt32($0) * 100, end: 1_780_000_050 + UInt32($0) * 100, size: UInt32(8_000)) }
        // The count is the total across pages: 40 declared, 3 carried.
        let total = SoundcoreRecording.read(listPacket(0x1b, count: 40, entries: entries, trailer: littleEndian32(1_780_000_900) + Data(count: 4)), now: listNow)
        XCTAssertTrue(total.isValid)
        XCTAssertEqual(total.declared, 40)
        XCTAssertEqual(total.parsed, 3)
        XCTAssertEqual(total.recordings.count, 3)
        XCTAssertEqual(total.active, 1_780_000_900)
        XCTAssertTrue(total.isOdd)

        // Cut inside the last entry: two whole entries, and no active ID from the leftover bytes.
        let whole = listPacket(0x1b, count: 3, entries: entries, trailer: Data())
        let cut = SoundcoreRecording.read(SoundcorePacket(type: 0x1b, command: 0x0e, status: 1, payload: whole.payload.prefix(whole.payload.count - 5)), now: listNow)
        XCTAssertTrue(cut.isValid)
        XCTAssertEqual(cut.parsed, 2)
        XCTAssertEqual(cut.trailerBytes, 7)
        XCTAssertNotNil(cut.active, "four bytes remain, so they're read; implausible ones aren't")
        XCTAssertNil(SoundcoreRecording.read(SoundcorePacket(type: 0x1b, command: 0x0e, status: 1, payload: whole.payload.prefix(whole.payload.count - 9)), now: listNow).active, "three bytes remain")

        // A short trailer: no active ID. A long one: the rest is ignored.
        XCTAssertNil(SoundcoreRecording.read(listPacket(0x1b, count: 3, entries: entries, trailer: Data(count: 3)), now: listNow).active)
        let long = SoundcoreRecording.read(listPacket(0x1b, count: 3, entries: entries, trailer: littleEndian32(1_780_000_900) + Data(count: 4), extra: Data(repeating: 9, count: 20)), now: listNow)
        XCTAssertEqual(long.active, 1_780_000_900)
        XCTAssertEqual(long.recordings.count, 3)

        // The same pages read as before in both layouts.
        let eight = SoundcoreRecording.read(listPacket(0x1a, count: 3, entries: entries), now: listNow)
        XCTAssertEqual(eight.recordings.map(\.id), entries.map(\.id))
        XCTAssertEqual(eight.stride, 8)
        XCTAssertFalse(eight.isOdd)
        XCTAssertEqual(total.stride, 12)
    }

    func testBehaviorImplausibleEntriesAreDroppedOrTheWholePageIsDifferentProtocol() {
        let good = (id: UInt32(1_780_000_000), end: UInt32(1_780_000_050), size: UInt32(8_000))
        let old = (id: UInt32(1_300_000_000), end: UInt32(1_300_000_050), size: UInt32(8_000))
        let future = (id: UInt32(1_790_000_000 + 200_000), end: UInt32(0), size: UInt32(8_000))
        let backwards = (id: UInt32(1_780_000_100), end: UInt32(1_780_000_000), size: UInt32(8_000))
        let open = (id: UInt32(1_780_000_200), end: UInt32(0), size: UInt32(8_000))
        let zero = (id: UInt32(0), end: UInt32(0), size: UInt32(0))

        let mixed = SoundcoreRecording.read(listPacket(0x1b, count: 4, entries: [good, old, future, zero]), now: listNow)
        XCTAssertTrue(mixed.isValid)
        XCTAssertEqual(mixed.recordings.map(\.id), [good.id])
        XCTAssertEqual(mixed.droppedImplausible, 2, "zero IDs aren't counted")
        XCTAssertTrue(mixed.isOdd)

        let allWrong = SoundcoreRecording.read(listPacket(0x1b, count: 3, entries: [old, future, backwards]), now: listNow)
        XCTAssertFalse(allWrong.isValid)
        XCTAssertThrowsError(try SoundcoreRecording.page(listPacket(0x1b, count: 2, entries: [old, old]))) {
            XCTAssertEqual($0 as? SoundcoreError, .invalidPacket)
        }
        XCTAssertFalse(SoundcoreRecording.read(listPacket(0x1b, count: 2, entries: [backwards, backwards]), now: listNow).isValid,
                       "every end time before its start")
        XCTAssertTrue(SoundcoreRecording.read(listPacket(0x1b, count: 2, entries: [good, backwards]), now: listNow).isValid)
        XCTAssertEqual(SoundcoreRecording.read(listPacket(0x1b, count: 1, entries: [open]), now: listNow).recordings.count, 1, "an open recording has no end yet")
        XCTAssertTrue(SoundcoreRecording.read(listPacket(0x1b, count: 1, entries: [zero]), now: listNow).isValid, "only zero IDs: an empty page")
        // The 8-byte layout has no end time to check.
        XCTAssertTrue(SoundcoreRecording.read(listPacket(0x1a, count: 1, entries: [backwards]), now: listNow).isValid)
        XCTAssertFalse(SoundcoreRecording.read(listPacket(0x1a, count: 1, entries: [old]), now: listNow).isValid)
    }

    func testBehaviorTheListDiagnosticNamesTheShapeAndTheFirstBytes() {
        let packet = listPacket(0x1b, count: 7, entries: [(id: 1_780_000_000, end: 1_780_000_050, size: 8_000)], trailer: Data([1, 2, 3, 4]))
        let page = SoundcoreRecording.read(packet, now: listNow)
        XCTAssertEqual(page.shape, "reply 1B 0E, 18 bytes, declared 7, read 1 of 12 bytes, trailer 4, dropped 0, first bytes 07 00 "
                       + [hex(1_780_000_000), hex(1_780_000_050), hex(8_000), "01 02 03 04"].joined(separator: " "))
        let long = SoundcoreRecording.read(listPacket(0x1b, count: 0, entries: [], extra: Data(repeating: 0xEE, count: 60)), now: listNow)
        XCTAssertEqual(long.head.split(separator: " ").count, 32)
        let garbage = SoundcoreRecording.read(SoundcorePacket(type: 0x1a, command: 0x0e, status: 1, payload: Data([0xAB])), now: listNow)
        XCTAssertEqual(garbage.shape, "unreadable reply 1A 0E, 1 bytes, first bytes AB")
    }

    private func hex(_ value: UInt32) -> String { littleEndian32(value).map { String(format: "%02X", $0) }.joined(separator: " ") }

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
        var garbage = SoundcorePacketBuffer()
        XCTAssertTrue(garbage.append(Data(repeating: 0, count: 1_048_577)).isEmpty, "A megabyte of garbage is skipped")
    }

    /// However much arrives at once (a Wi‑Fi message can carry megabytes of frames), it's reassembled 64 KB at a time:
    /// nothing is dropped for its size, frames across a piece's edge come out whole, and the link's own message limit is
    /// the only one.
    func testBehaviorALargeDeliveryIsReassembledInPiecesWithNothingDropped() {
        var buffer = SoundcorePacketBuffer()
        let frame = SoundcorePacket.frame(type: 0x1a, command: 0x08, payload: Data(repeating: 3, count: 498))
        let delivery = Data((0..<4_000).flatMap { _ in frame })
        XCTAssertGreaterThan(delivery.count, 2_000_000)
        let packets = buffer.append(delivery)
        XCTAssertEqual(packets.count, 4_000)
        XCTAssertEqual(buffer.rejectedFrames, 0)
        XCTAssertTrue(packets.allSatisfy { $0.payload.count == 498 })
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
        let url = makeTemporaryFolder("SoundcoreOpus").appendingPathComponent("decoded.wav")
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
