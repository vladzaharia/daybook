#if os(iOS)
import Darwin
import Foundation
import NetworkExtension

/// The iPhone joining the recorder's network for Fast Transfer: `NEHotspotConfiguration`, once
/// (`joinOnce`), which iOS asks the person about each time and keeps only while Daybook is in the
/// foreground. It needs the Hotspot Configuration entitlement
/// (`com.apple.developer.networking.HotspotConfiguration`); without it iOS fails the join at once
/// ("internal error"), which is `.unavailable`, and transfers stay on Bluetooth.
@MainActor
public final class SystemSoundcoreHotspot: SoundcoreHotspot {
    /// After iOS says it joined, how long to wait for an address on the recorder's network.
    public var addressWait: Duration = .seconds(20)

    public init() {}

    public func join(ssid: String, password: String, recorder host: String) async throws {
        let configuration = NEHotspotConfiguration(ssid: ssid, passphrase: password, isWEP: false)
        configuration.joinOnce = true
        do {
            try await NEHotspotConfigurationManager.shared.apply(configuration)
        } catch let error as NSError where error.domain == NEHotspotConfigurationErrorDomain {
            switch NEHotspotConfigurationError(rawValue: error.code) {
            case .alreadyAssociated?: break
            case .userDenied?, .userUnauthorized?: throw SoundcoreHotspotError.declined
            case .internal?: throw SoundcoreHotspotError.unavailable
            default: throw SoundcoreHotspotError.failed(error.localizedDescription)
            }
        }
        // `apply` succeeding doesn't promise the join: wait for an address on the recorder's subnet.
        let deadline = ContinuousClock.now.advanced(by: addressWait)
        while !Self.sharesSubnet(with: host) {
            guard ContinuousClock.now < deadline else { throw SoundcoreHotspotError.failed("This iPhone has no address on its network.") }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    public func leave(ssid: String) {
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
    }

    /// An IPv4 interface (not loopback) is on the same subnet as `host`.
    static func sharesSubnet(with host: String) -> Bool {
        var target = in_addr()
        guard inet_pton(AF_INET, host, &target) == 1 else { return false }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = entry.pointee
            guard let address = interface.ifa_addr, let mask = interface.ifa_netmask, address.pointee.sa_family == UInt8(AF_INET),
                  interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0, interface.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            let local = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            if netmask != 0, local & netmask == target.s_addr & netmask { return true }
        }
        return false
    }
}
#endif
