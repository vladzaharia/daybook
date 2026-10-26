@testable import DaybookLink
import Foundation
@preconcurrency import Network
import XCTest

final class LinkLocalNetworkTests: XCTestCase {
    private func local(_ text: String, subnets: [LinkLocalNetwork.Subnet] = []) -> Bool {
        LinkLocalNetwork.isLocal(.hostPort(host: NWEndpoint.Host(text), port: 4242), subnets: subnets)
    }

    private func subnet(_ address: String, _ mask: String) -> LinkLocalNetwork.Subnet {
        let parse = { (text: String) -> [UInt8] in
            if let v4 = IPv4Address(text) { return [UInt8](v4.rawValue) }
            return [UInt8](IPv6Address(text)!.rawValue)
        }
        return LinkLocalNetwork.Subnet(address: parse(address), mask: parse(mask))
    }

    func testPrivateLinkLocalAndLoopbackIPv4AreLocal() {
        for address in ["127.0.0.1", "127.1.2.3", "10.0.0.1", "10.255.1.2", "172.16.0.1", "172.31.255.254",
                        "192.168.1.20", "169.254.10.10"] {
            XCTAssertTrue(local(address), address)
        }
        for address in ["8.8.8.8", "172.15.0.1", "172.32.0.1", "192.169.0.1", "100.64.0.1", "203.0.113.7", "0.0.0.0"] {
            XCTAssertFalse(local(address), address)
        }
    }

    func testLoopbackLinkLocalAndUniqueLocalIPv6AreLocal() {
        for address in ["::1", "fe80::1", "fe80::1c2a:3bff:fe4d:5e6f", "febf::1", "fc00::1", "fd12:3456:789a::1",
                        "::ffff:192.168.1.2"] {
            XCTAssertTrue(local(address), address)
        }
        for address in ["2001:db8::1", "fec0::1", "ff02::1", "::", "::ffff:8.8.8.8", "2606:4700::1111"] {
            XCTAssertFalse(local(address), address)
        }
    }

    func testAddressesOnAnAttachedSubnetAreLocal() {
        let attached = [subnet("203.0.113.40", "255.255.255.0"), subnet("2001:db8:0:1::10", "ffff:ffff:ffff:ffff::")]
        XCTAssertTrue(local("203.0.113.7", subnets: attached))
        XCTAssertFalse(local("203.0.114.7", subnets: attached))
        XCTAssertTrue(local("2001:db8:0:1:abcd::7", subnets: attached))
        XCTAssertFalse(local("2001:db8:0:2::7", subnets: attached))
        // An IPv4 subnet never matches an IPv6 address, and the other way round.
        XCTAssertFalse(local("::ffff:203.0.114.7", subnets: attached))
        XCTAssertTrue(local("::ffff:203.0.113.9", subnets: attached))
    }

    func testOnlyAddressedEndpointsCanBeLocal() {
        XCTAssertFalse(LinkLocalNetwork.isLocal(.hostPort(host: "studio-mac.local", port: 4242), subnets: []))
        XCTAssertFalse(LinkLocalNetwork.isLocal(.service(name: "Studio Mac", type: "_daybook-link._tcp", domain: "local.", interface: nil),
                                                subnets: []))
        XCTAssertTrue(LinkLocalNetwork.isLocal(.hostPort(host: .ipv4(IPv4Address("192.168.0.9")!), port: 1), subnets: []))
    }

    func testAttachedSubnetsAreWellFormed() {
        for subnet in LinkLocalNetwork.attachedSubnets() {
            XCTAssertTrue(subnet.address.count == 4 || subnet.address.count == 16)
            XCTAssertEqual(subnet.mask.count, subnet.address.count)
            XCTAssertTrue(subnet.mask.contains { $0 != 0 })
        }
    }

    /// The listener drops a connection from outside the local network before TLS: the phone can't
    /// even start pairing, and the Mac counts no attempt.
    func testServiceDropsConnectionsFromOutsideTheLocalNetwork() async throws {
        var configuration = LinkConfiguration.loopback()
        configuration.isLocalEndpoint = { _ in false }
        let service = LinkService(identity: Fixture.mac(), keyStore: MemoryLinkKeyStore(), configuration: configuration)
        let events = EventRecorder(service.events())
        addTeardownBlock { await service.stop() }
        try await service.start()
        let port = try await XCTUnwrapAsync(await service.port)
        await service.beginPairing()
        let client = LinkClient(identity: Fixture.phone(), keyStore: MemoryLinkKeyStore(), configuration: .loopback())
        do {
            _ = try await client.pair(with: LinkEndpoint(host: "127.0.0.1", port: port), code: "123456")
            XCTFail("paired from outside the local network")
        } catch let error as LinkPairingError {
            guard case .connectionFailed = error else { return XCTFail("\(error)") }
        }
        XCTAssertNil(events.all.compactMap(\.pairingFailure).first, "the Mac never saw an attempt")
        await service.stop()
    }
}
