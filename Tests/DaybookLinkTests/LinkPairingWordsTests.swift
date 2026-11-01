@testable import DaybookLink
import Foundation
import XCTest

/// Pairing's shared words (`PairingWords`) and code grouping, and the side a pair should update.
final class LinkPairingWordsTests: XCTestCase {
    func testBehaviorBothDevicesTitleAndNameTheOtherDevicesControl() {
        XCTAssertEqual(PairingWords.title(on: .mac), "Pair with Your iPhone")
        XCTAssertEqual(PairingWords.title(on: .iPhone), "Pair with Your Mac")
        XCTAssertEqual(PairingWords.onTheMac, "On your Mac, open Daybook › Settings › Devices and click Pair with iPhone.")
        XCTAssertTrue(PairingWords.onTheMac.contains(String(PairingWords.pairWithIPhone.dropLast())), "names the Mac's own button")
        let mac = PairingWords.onTheIPhone(macName: "Vlad’s MacBook Pro")
        XCTAssertTrue(mac.contains(String(PairingWords.pairWithMac.dropLast())), "names the iPhone's own button")
        XCTAssertTrue(mac.contains("“Vlad’s\u{00A0}MacBook\u{00A0}Pro”"), "the Mac's name stays on one line")
        XCTAssertEqual(PairingWords.unpairQuestion("Studio Mac"), "Unpair Studio Mac?")
        XCTAssertFalse(PairingWords.unpairConsequence.contains("—"))
    }

    func testBehaviorARefusalSaysWhichToggleOnWhichDeviceAllowsIt() {
        // Read on the iPhone, refused by the Mac, whose toggle is in sentence case.
        XCTAssertEqual(PairingWords.notAllowedToStart(asker: .iPhone),
                       "It isn’t set to let this iPhone start recording. Turn on Can start recording for this iPhone on the Mac.")
        // Read on the Mac, refused by the iPhone, which title-cases it.
        XCTAssertEqual(PairingWords.notAllowedToStart(asker: .mac),
                       "It isn’t set to let this Mac start recording. Turn on Can Start Recording for this Mac on the iPhone.")
        XCTAssertEqual(PairingWords.notAllowedToStop(asker: .iPhone),
                       "It isn’t set to let this iPhone stop its recording. Turn on Can start recording for this iPhone on the Mac.")
        XCTAssertEqual(PairingWords.declined("Studio Mac", here: PairingWords.here(.iPhone)), "Studio Mac isn’t set to record with this iPhone.")
        for sentence in [PairingWords.notAllowedToStart(asker: .iPhone), PairingWords.unpairConsequence, PairingWords.noMacFound,
                         PairingWords.allowLocalNetwork] {
            XCTAssertFalse(sentence.contains("—"), "no dash asides: \(sentence)")
        }
    }

    func testBehaviorAPairedDevicesPageSaysWhatItsRecordingAndOffersStopOnIt() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let time = start.formatted(date: .omitted, time: .shortened)
        XCTAssertEqual(PairingWords.recordingNow(since: start, paused: false), "Recording now · since \(time)")
        XCTAssertEqual(PairingWords.recordingNow(since: start, paused: true), "Paused · since \(time)")
        XCTAssertEqual(PairingWords.recordingNow(since: nil, paused: false), "Recording now")
        XCTAssertEqual(PairingWords.stop(on: "Studio Mac"), "Stop on Studio Mac")
        XCTAssertEqual(PairingWords.notPaired("Alex’s iPhone", here: PairingWords.here(.mac)), "This Mac isn’t paired with Alex’s iPhone.")
        XCTAssertEqual(PairingWords.unnamed(.iPhone), "iPhone")
        XCTAssertEqual(PairingWords.spoken(LinkPairingCode(value: 482_913, expiresAt: .distantFuture)), "Pairing code 4 8 2 9 1 3")
    }

    func testBehaviorACodeIsGroupedWithOneSeparatorEverywhere() {
        let code = LinkPairingCode(value: 48_213, expiresAt: .distantFuture)
        XCTAssertEqual(code.groups, ["048", "213"])
        XCTAssertEqual(code.formatted, "048 213")
        XCTAssertEqual(code.formatted, code.groups.joined(separator: LinkPairingCode.separator))
        XCTAssertEqual(LinkPairingCode(typed: code.formatted)?.value, code.value, "what's shown types back")
    }

    func testBehaviorAnExpiringCodeSaysItsMinutes() {
        let now = Date()
        XCTAssertEqual(PairingWords.expiry(LinkPairingCode(value: 1, expiresAt: now.addingTimeInterval(270)), now: now), "Expires in 5 minutes")
        XCTAssertEqual(PairingWords.expiry(LinkPairingCode(value: 1, expiresAt: now.addingTimeInterval(40)), now: now), "Expires in about a minute")
    }

    func testBehaviorAVersionMismatchSaysWhichSideToUpdate() {
        XCTAssertEqual(LinkProtocol.olderSide(peer: 1...1, ours: 2...3), .peer)
        XCTAssertEqual(LinkProtocol.olderSide(peer: 4...5, ours: 2...3), .this)
        XCTAssertNil(LinkProtocol.olderSide(peer: nil, ours: 2...3))
        XCTAssertNil(LinkProtocol.olderSide(peer: 3...4, ours: 2...3))
        XCTAssertEqual(PairingWords.update("Studio Mac", here: "this iPhone", peerVersions: 1...1, ours: 2...2),
                       "Update Daybook on Studio Mac to connect.")
        XCTAssertEqual(PairingWords.update("Studio Mac", here: "this iPhone", peerVersions: 3...3, ours: 2...2),
                       "Update Daybook on this iPhone to connect.")
        XCTAssertEqual(PairingWords.update("Studio Mac", here: "this iPhone", peerVersions: nil),
                       "Update Daybook on this iPhone or Studio Mac to connect.")
    }
}
