@testable import DaybookLink
import Foundation
@preconcurrency import Network
import XCTest

/// Finding Macs (Local Network refused, a Mac of another library), a pairing that can't be read on a
/// running Mac, and the pairing timeout's error.
final class LinkDiscoveryTests: XCTestCase {
    func testBehaviorAPairingTimeoutIsTypedNotWorded() {
        XCTAssertEqual(LinkService.error(for: .timedOut), .timedOut)
        XCTAssertEqual(LinkService.error(for: .unexpected("timed out")), .protocolViolation("timed out"),
                       "rewording a reason never turns it into a timeout")
        XCTAssertEqual(LinkService.error(for: nil), .connectionFailed("closed"))
    }

    // MARK: A damaged pairing

    func testBehaviorAMacWithADamagedPairingStillListensListsItAndUnpairsIt() async throws {
        let mac = Fixture.mac(), phone = Fixture.phone()
        let stores = Fixture.pairedStores(mac: mac, phone: phone)
        let damagedID = UUID()
        let macStore = MemoryLinkKeyStore(try stores.mac.records(),
                                          damaged: [LinkPairedDevice(deviceID: damagedID, name: "Spare iPhone", deviceClass: .iPhone, pairedAt: Date())])
        let service = LinkService(identity: mac, keyStore: macStore, configuration: .testLoopback())
        try await service.start()
        addTeardownBlock { await service.stop() }
        let paired = try await service.pairedDevices()
        XCTAssertEqual(paired.map(\.deviceID), [phone.deviceID, damagedID])
        XCTAssertEqual(paired.map(\.isDamaged), [false, true])

        // The readable pairing connects as ever.
        let port = try await XCTUnwrapAsync(await service.port)
        let client = LinkClient(identity: phone, keyStore: stores.phone, configuration: .testLoopback())
        let events = EventRecorder(client.events())
        try await client.connect(to: mac.deviceID, via: LinkEndpoint(host: "127.0.0.1", port: port))
        _ = try await events.next("connected") { $0.connected }
        await client.disconnect(from: mac.deviceID)

        try await service.unpair(damagedID)
        let after = try await service.pairedDevices()
        XCTAssertEqual(after.map(\.deviceID), [phone.deviceID])
    }

    // MARK: Finding Macs

    func testBehaviorLocalNetworkRefusedIsADiscoveryState() {
        XCTAssertEqual(LinkClient.discovery(for: .waiting(.dns(LinkClient.policyDenied))), .localNetworkDenied)
        XCTAssertEqual(LinkClient.discovery(for: .failed(.dns(LinkClient.policyDenied))), .localNetworkDenied)
        XCTAssertEqual(LinkClient.discovery(for: .ready), .searching)
        XCTAssertNil(LinkClient.discovery(for: .waiting(.posix(.ENETDOWN))), "any other wait says nothing new")
        XCTAssertNil(LinkClient.discovery(for: .setup))
    }

    func testBehaviorAMacWithAnotherLibraryIsShownButNotOffered() async throws {
        let library = UUID(), paired = Fixture.mac(), other = UUID(), same = UUID(), none = UUID()
        let phone = LinkIdentity(deviceID: UUID(), name: "Pocket iPhone", deviceClass: .iPhone, appVersion: "2.0", libraryID: library)
        let stores = Fixture.pairedStores(mac: paired, phone: phone)
        let client = LinkClient(identity: phone, keyStore: stores.phone, configuration: .testLoopback())
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 9)
        let advertised: [(name: String, endpoint: NWEndpoint, advertisement: LinkAdvertisement)] = [
            ("Office iMac", endpoint, LinkAdvertisement(libraryID: library, deviceID: same, versions: 1...1, isPairing: true)),
            ("Home Mac", endpoint, LinkAdvertisement(libraryID: UUID(), deviceID: other, versions: 1...1, isPairing: true)),
            ("Studio Mac", endpoint, LinkAdvertisement(libraryID: UUID(), deviceID: paired.deviceID, versions: 1...1, isPairing: false)),
            ("New Mac", endpoint, LinkAdvertisement(libraryID: nil, deviceID: none, versions: 1...1, isPairing: true))
        ]
        await client.browsed(advertised)
        let found = await client.discoveredMacs
        XCTAssertEqual(found.map(\.serviceName), ["Home Mac", "New Mac", "Office iMac", "Studio Mac"], "every Mac on the network is shown")
        XCTAssertEqual(found.first { $0.serviceName == "Home Mac" }?.usesAnotherLibrary, true)
        XCTAssertEqual(found.first { $0.serviceName == "Office iMac" }?.usesAnotherLibrary, false)
        XCTAssertEqual(found.first { $0.serviceName == "New Mac" }?.usesAnotherLibrary, false, "a Mac with no library yet is offered")
        let studio = try XCTUnwrap(found.first { $0.serviceName == "Studio Mac" })
        XCTAssertEqual(studio.pairedDeviceID, paired.deviceID)
        XCTAssertFalse(studio.usesAnotherLibrary, "a paired Mac is always offered, whatever library it has open now")
    }
}
