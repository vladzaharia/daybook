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
    /// After iOS says it joined, how long to wait for it to be on the recorder's network with an address there.
    public var addressWait: Duration = .seconds(20)
    /// iOS names the Wi‑Fi this iPhone is on (`NEHotspotNetwork.fetchCurrent`) only to an app with the Access Wi‑Fi
    /// Information entitlement (`com.apple.developer.networking.wifi-info`); without it every answer is nil. So the
    /// name is checked only in a build that has it, which says so in its Info.plist (`readsNetworkNameKey`, added
    /// with the entitlement). Otherwise an address on the recorder's subnet is the check, and only where this iPhone
    /// had none there before joining (`SoundcoreWiFi.canCheckJoin`).
    public let readsNetworkName: Bool
    /// Whether this iPhone had an address on the recorder's subnet just before joining it, keyed by the SSID joined.
    private var sharedSubnetBeforeJoining: [String: Bool] = [:]

    /// Info.plist's Boolean that this build has the Access Wi‑Fi Information entitlement.
    public static let readsNetworkNameKey = "DaybookReadsWiFiName"

    public init(readsNetworkName: Bool = Bundle.main.object(forInfoDictionaryKey: SystemSoundcoreHotspot.readsNetworkNameKey) as? Bool == true) {
        self.readsNetworkName = readsNetworkName
    }

    public func canCheckJoin(recorder host: String) -> Bool {
        SoundcoreWiFi.canCheckJoin(readsName: readsNetworkName, sharedSubnetBeforeJoining: Self.sharesSubnet(with: host))
    }

    public func join(ssid: String, password: String, recorder host: String) async throws {
        // Before iOS asks: on a network with the recorder's addresses already, and no name to tell them apart, a
        // join couldn't be checked. Nothing is joined, and the transfer stays on Bluetooth.
        let sharedBefore = Self.sharesSubnet(with: host)
        sharedSubnetBeforeJoining[ssid] = sharedBefore
        guard SoundcoreWiFi.canCheckJoin(readsName: readsNetworkName, sharedSubnetBeforeJoining: sharedBefore) else {
            throw SoundcoreHotspotError.notJoined
        }
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
        // `apply` succeeding doesn't promise the join: wait until this iPhone is on the recorder's network.
        let deadline = ContinuousClock.now.advanced(by: addressWait)
        while await !isJoined(to: ssid, recorder: host) {
            guard ContinuousClock.now < deadline else { throw SoundcoreHotspotError.failed("This iPhone isn’t on its network.") }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    /// An address on the recorder's subnet and, where this build can read it, iOS naming `ssid` as the Wi‑Fi this
    /// iPhone is on: with the entitlement, `fetchCurrent` names a network the app configured, as the recorder's is.
    /// Without it, the address counts only if this iPhone had none there before joining; a network it didn't join
    /// here has no before, so the address alone never counts for it.
    public func isJoined(to ssid: String, recorder host: String) async -> Bool {
        var current: String?
        if readsNetworkName { current = await Self.currentNetworkName() }
        return SoundcoreWiFi.isOnRecorderNetwork(ssid, currentName: current, readsName: readsNetworkName,
                                                 sharesSubnet: Self.sharesSubnet(with: host),
                                                 sharedSubnetBeforeJoining: sharedSubnetBeforeJoining[ssid] ?? true)
    }

    private static func currentNetworkName() async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            NEHotspotNetwork.fetchCurrent { network in continuation.resume(returning: network?.ssid) }
        }
    }

    public func leave(ssid: String) {
        sharedSubnetBeforeJoining[ssid] = nil
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
