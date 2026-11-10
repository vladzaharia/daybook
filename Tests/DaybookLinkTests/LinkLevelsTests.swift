@testable import DaybookLink
import Foundation
import XCTest

/// Input levels during a shared recording (docs/link.md, "Shared recordings"): `levels` both ways, an iPhone's to a Mac
/// and a Mac's to an iPhone, each only to a device that lists `liveLevels`; `sharesLevels` says a device sends its own,
/// so an iPhone gives a Mac a meter only when it lists it; how readings are gathered to send (`LevelShare`) and played
/// back as they arrive (`LevelPlayback`).
final class LinkLevelsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000.5)

    private func capabilities(_ deviceClass: LinkDeviceClass, _ features: [String]) -> LinkCapabilities {
        LinkCapabilities(deviceClass: deviceClass, name: deviceClass == .mac ? "Studio Mac" : "Pocket iPhone", appVersion: "1.0",
                         libraryID: nil, canProcess: false, features: features)
    }

    // MARK: The features

    /// Each device sends its level only to one that draws it, and draws a Mac only when the Mac sends: an older iPhone
    /// is never sent a Mac's level, and an older Mac, which draws iPhones' but sends none, gets no meter on an iPhone.
    func testBehaviorEachWayGoesOnlyToADeviceThatDrawsItAndAMeterOnlyForOneThatSends() throws {
        let phone = capabilities(.iPhone, [LinkCapabilities.liveCaptionsFeature, LinkCapabilities.liveLevelsFeature,
                                           LinkCapabilities.sharesLevelsFeature])
        XCTAssertTrue(phone.showsLevels, "a Mac sends this iPhone its level")
        XCTAssertTrue(phone.sharesLevels)
        let olderPhone = capabilities(.iPhone, [LinkCapabilities.liveCaptionsFeature])
        XCTAssertFalse(olderPhone.showsLevels, "an older iPhone is never sent a Mac's level")

        let mac = capabilities(.mac, [LinkCapabilities.liveLevelsFeature, LinkCapabilities.sharesLevelsFeature])
        XCTAssertTrue(mac.showsLevels, "an iPhone sends this Mac its level")
        XCTAssertTrue(mac.sharesLevels, "and draws this Mac's")
        let olderMac = capabilities(.mac, [LinkCapabilities.liveLevelsFeature])
        XCTAssertTrue(olderMac.showsLevels, "an older Mac still draws an iPhone's level")
        XCTAssertFalse(olderMac.sharesLevels, "but sends none, so an iPhone gives it no meter")

        // On the wire the features are plain strings: one a build doesn't know is carried, never a reason to refuse.
        let frame = try LinkWire.encode(.capabilities(mac), version: 1)
        let json = String(decoding: frame, as: UTF8.self)
        XCTAssertTrue(json.contains(#""sharesLevels""#), json)
        let later = json.replacingOccurrences(of: #""sharesLevels""#, with: #""sharesLevels","fromALaterBuild""#)
        guard case .capabilities(let read) = try LinkWire.decode(Data(later.utf8)).message else { return XCTFail(later) }
        XCTAssertTrue(read.sharesLevels)
        XCTAssertTrue(read.features.contains("fromALaterBuild"))
    }

    /// The same message carries a Mac's level as an iPhone's: the louder of its microphone and computer audio each tick.
    func testBehaviorAMacsLevelRoundTripsAsAnIPhonesDoes() throws {
        let id = UUID()
        let fromMac = LinkLevels(conversationID: id, values: [0.08, 0.61, 0.33], interval: 1.0 / 15, sentAt: t0)
        let frame = try LinkWire.encode(.app(.levels(fromMac)), version: 1)
        XCTAssertTrue(String(decoding: frame, as: UTF8.self).contains(#""type":"levels""#))
        XCTAssertEqual(try LinkWire.decode(frame).message, .app(.levels(fromMac)))
    }

    /// Over a session both ways: the iPhone's level reaches the Mac and the Mac's the iPhone, each side seeing the
    /// other's features; an older build's session carries on past a message type it doesn't know.
    func testBehaviorLevelsTravelBothWaysOverASession() async throws {
        let mac = LinkIdentity(deviceID: UUID(), name: "Studio Mac", deviceClass: .mac, appVersion: "2.0", libraryID: Fixture.libraryID,
                               canProcess: true, features: [LinkCapabilities.liveLevelsFeature, LinkCapabilities.sharesLevelsFeature])
        let phone = LinkIdentity(deviceID: UUID(), name: "Pocket iPhone", deviceClass: .iPhone, appVersion: "2.0", libraryID: Fixture.libraryID,
                                 features: [LinkCapabilities.liveLevelsFeature, LinkCapabilities.sharesLevelsFeature])
        let stores = Fixture.pairedStores(mac: mac, phone: phone)
        let service = LinkService(identity: mac, keyStore: stores.mac, configuration: .testLoopback())
        let client = LinkClient(identity: phone, keyStore: stores.phone, configuration: .testLoopback())
        let macEvents = EventRecorder(service.events()), phoneEvents = EventRecorder(client.events())
        try await service.start()
        let port = try await XCTUnwrapAsync(await service.port)
        addTeardownBlock {
            await client.disconnect(from: mac.deviceID)
            await service.stop()
        }
        try await client.connect(to: mac.deviceID, via: LinkEndpoint(host: "127.0.0.1", port: port))
        let macSide = try await macEvents.next("the phone, on the Mac") { $0.connected }
        let phoneSide = try await phoneEvents.next("the Mac, on the phone") { $0.connected }
        XCTAssertTrue(macSide.capabilities.showsLevels, "the Mac may send this iPhone its level")
        XCTAssertTrue(phoneSide.capabilities.sharesLevels, "the iPhone meters this Mac")

        let conversation = UUID()
        let up = LinkLevels(conversationID: conversation, values: [0.2, 0.4], sentAt: t0)
        try await client.send(.levels(up))
        let (atMac, from) = try await macEvents.next("the iPhone's level") { $0.received }
        XCTAssertEqual(atMac, .levels(up))
        XCTAssertEqual(from, phone.deviceID)

        let down = LinkLevels(conversationID: conversation, values: [0.7, 0.5, 0.1], sentAt: t0)
        try await service.send(.levels(down), to: phone.deviceID)
        let (atPhone, sender) = try await phoneEvents.next("the Mac's level") { $0.received }
        XCTAssertEqual(atPhone, .levels(down))
        XCTAssertEqual(sender, mac.deviceID)

        // A build that doesn't know a type ignores it and reads the next.
        var frame = String(decoding: try LinkWire.encode(.app(.levels(down)), version: 1), as: UTF8.self)
        frame = frame.replacingOccurrences(of: #""type":"levels""#, with: #""type":"levels.from-a-later-build""#)
        XCTAssertEqual(try LinkWire.decode(Data(frame.utf8)).message, .unknown("levels.from-a-later-build"))
    }

    // MARK: Gathering readings to send

    /// Readings gather as the meter takes them and go a few at a time, about five times a second, to two places, as a
    /// meter shows them.
    func testBehaviorLevelsGoAFewReadingsAtATime() {
        var share = LevelShare()
        XCTAssertEqual(share.add(0.123, at: t0), [0.12], "the first at once")
        var sent: [[Double]] = []
        for tick in 1...15 {
            if let values = share.add(1.4, at: t0.addingTimeInterval(Double(tick) / 15)) { sent.append(values) }
        }
        XCTAssertTrue((4...5).contains(sent.count), "about five times a second: \(sent.count)")
        XCTAssertTrue(sent.allSatisfy { $0.count >= 2 && $0.count <= 4 }, "a few readings each: \(sent)")
        XCTAssertEqual(Set(sent.joined()), [1], "kept to 0…1")
        XCTAssertEqual(share.add(.nan, at: t0.addingTimeInterval(1.5)), [0], "a reading that isn't a number is silence")
        for tick in 0..<(LinkLevels.maximumValues + 10) { _ = share.add(0.5, at: t0.addingTimeInterval(1.6 + Double(tick) * 0.001)) }
        XCTAssertLessThanOrEqual(share.pending.count, LinkLevels.maximumValues, "never more than one message carries")
    }

    // MARK: Playing them back

    /// A reading a tick as they arrive, fading between messages, only for the recording they were sent for, and none
    /// once a device has been quiet for 1.5 s; a backlog never grows past a second's, so the meter keeps up.
    func testBehaviorLevelsPlayBackAReadingATickAndDropAfterASilence() {
        var playback = LevelPlayback()
        let device = UUID(), conversation = UUID()
        XCTAssertNil(playback.next(device, conversation: conversation, at: t0), "nothing sent: no level")
        playback.receive(LinkLevels(conversationID: conversation, values: [0.2, 0.4, 0.6]), from: device, at: t0)
        XCTAssertEqual(playback.last(device, conversation: conversation, at: t0), 0.6, "the newest, leaving the queue")
        XCTAssertEqual(playback.next(device, conversation: conversation, at: t0), 0.2)
        XCTAssertEqual(playback.next(device, conversation: conversation, at: t0), 0.4)
        XCTAssertEqual(playback.next(device, conversation: conversation, at: t0), 0.6)
        XCTAssertEqual(playback.next(device, conversation: conversation, at: t0) ?? 0, 0.48, accuracy: 0.001, "between messages it fades")
        XCTAssertNil(playback.next(device, conversation: UUID(), at: t0), "only for the recording it was sent for")
        XCTAssertNotNil(playback.next(device, conversation: conversation, at: t0.addingTimeInterval(LevelPlayback.lifetime - 0.01)))
        XCTAssertNil(playback.next(device, conversation: conversation, at: t0.addingTimeInterval(LevelPlayback.lifetime)),
                     "a device quiet for 1.5 s has no level: its meter rests")
        XCTAssertNil(playback.last(device, conversation: conversation, at: t0.addingTimeInterval(LevelPlayback.lifetime)))

        playback.receive(LinkLevels(conversationID: conversation, values: Array(repeating: 0.1, count: 20) + [0.9]), from: device, at: t0)
        for _ in 0..<(LevelPlayback.backlog - 1) { _ = playback.next(device, conversation: conversation, at: t0) }
        XCTAssertEqual(playback.next(device, conversation: conversation, at: t0), 0.9, "the oldest go first")

        // Another recording's levels start a new feed; reset drops every one.
        let next = UUID()
        playback.receive(LinkLevels(conversationID: next, values: [0.3]), from: device, at: t0)
        XCTAssertNil(playback.next(device, conversation: conversation, at: t0))
        XCTAssertEqual(playback.next(device, conversation: next, at: t0), 0.3)
        playback.reset()
        XCTAssertNil(playback.next(device, conversation: next, at: t0))
    }
}
