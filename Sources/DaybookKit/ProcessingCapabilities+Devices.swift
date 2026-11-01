import DaybookCore
import DaybookLink
import Foundation

// What another device does with its models, as the link and presence records carry it, and which Macs a
// device can send a summary to now (docs/multipoint.md, "Where summaries run").

extension ProcessingCapabilities {
    public init(_ link: LinkProcessingCapabilities) {
        self.init(transcribes: link.transcribes, findsSpeakers: link.findsSpeakers, summarizes: link.summarizes, models: link.models)
    }

    public init(_ presence: SyncDeviceCapabilities) {
        self.init(transcribes: presence.transcribes, findsSpeakers: presence.findsSpeakers, summarizes: presence.summarizes,
                  models: presence.models)
    }

    /// As the link carries it.
    public var link: LinkProcessingCapabilities {
        LinkProcessingCapabilities(transcribes: transcribes, findsSpeakers: findsSpeakers, summarizes: summarizes, models: models)
    }

    /// As a presence record carries it.
    public var presence: SyncDeviceCapabilities {
        SyncDeviceCapabilities(transcribes: transcribes, findsSpeakers: findsSpeakers, summarizes: summarizes, models: models)
    }

    /// Nothing at all: a device without models, or one that takes no work from others.
    public static let none = ProcessingCapabilities(transcribes: false, findsSpeakers: false, summarizes: false)
}

/// A Mac another device could send a summary to.
public struct SummarizingMac: Equatable, Sendable {
    /// Its sync replica ID as a UUID (a Mac's link ID is the same).
    public var id: UUID
    public var name: String

    public init(id: UUID, name: String) { self.id = id; self.name = name }

    /// A Mac connected over the link now, as the link knows it.
    public struct Connected: Equatable, Sendable {
        public var id: UUID
        public var syncDeviceID: String?
        public var name: String
        /// From its capabilities; nil from an earlier Daybook, which says only `canProcess`.
        public var capabilities: ProcessingCapabilities?
        public var canProcess: Bool

        public init(id: UUID, syncDeviceID: String? = nil, name: String, capabilities: ProcessingCapabilities?, canProcess: Bool) {
            self.id = id; self.syncDeviceID = syncDeviceID; self.name = name; self.capabilities = capabilities; self.canProcess = canProcess
        }
    }

    /// A presence record seen this recently counts as a Mac that will see a request soon: Macs rewrite
    /// theirs every 10 minutes while they run (`MacPresence.recentlySeen` on the iPhone is the same).
    public static let presenceWindow: TimeInterval = 15 * 60

    /// The Macs that can summarize and are reachable now, connected ones first, each once: connected over the
    /// link, or seen through sync within `presenceWindow`. A Mac summarizes when its capabilities say so, or,
    /// from an earlier Daybook that doesn't say, when it processes (`canProcess` means it has every model).
    public static func reachable(connected: [Connected], presence: [KnownSyncDevice], now: Date = Date()) -> [SummarizingMac] {
        var result: [SummarizingMac] = []
        var seen = Set<String>()
        for mac in connected where mac.capabilities?.summarizes ?? mac.canProcess {
            let key = mac.syncDeviceID ?? mac.id.uuidString
            guard seen.insert(key).inserted else { continue }
            result.append(SummarizingMac(id: UUID(uuidString: key) ?? mac.id, name: mac.name))
        }
        let present = presence.filter { device in
            guard !device.isCurrentDevice, device.deviceClass == .mac, device.supersededBy == nil, let seen = device.lastSeen,
                  now.timeIntervalSince(seen) <= presenceWindow else { return false }
            return device.capabilities?.summarizes ?? (device.canProcess == true)
        }
        .sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
        for device in present {
            guard let id = UUID(uuidString: device.id), seen.insert(device.id).inserted else { continue }
            result.append(SummarizingMac(id: id, name: device.displayName ?? "your Mac"))
        }
        return result
    }
}

extension SummaryOptions {
    public init(thisDeviceCanSummarize: Bool, macs: [SummarizingMac], cloud: CloudModel?) {
        self.init(thisDeviceCanSummarize: thisDeviceCanSummarize, reachableMacs: macs.map { (id: $0.id, name: $0.name) }, cloud: cloud)
    }
}

/// A Mac reachable now, with what it would run for other devices: what an "Upgrade" offer compares a conversation's
/// models with (docs/multipoint.md, "Upgrade"). Reachable as for summaries (`SummarizingMac.reachable`): connected over
/// the link, or seen through sync within `SummarizingMac.presenceWindow`.
public struct ProcessingMac: Equatable, Sendable {
    /// Its sync replica ID, as requests name devices.
    public var id: String
    public var name: String
    public var capabilities: ProcessingCapabilities

    public init(id: String, name: String, capabilities: ProcessingCapabilities) {
        self.id = id; self.name = name; self.capabilities = capabilities
    }

    /// The Macs reachable now that say what they run, connected ones first, each once. One from an earlier Daybook, which
    /// doesn't name its models, offers nothing.
    public static func reachable(connected: [SummarizingMac.Connected], presence: [KnownSyncDevice], now: Date = Date()) -> [ProcessingMac] {
        var result: [ProcessingMac] = []
        var seen = Set<String>()
        for mac in connected {
            guard let capabilities = mac.capabilities, capabilities.models != nil else { continue }
            let key = mac.syncDeviceID ?? mac.id.uuidString
            guard seen.insert(key).inserted else { continue }
            result.append(ProcessingMac(id: key, name: mac.name, capabilities: capabilities))
        }
        let present = presence.filter { device in
            guard !device.isCurrentDevice, device.deviceClass == .mac, device.supersededBy == nil, let seen = device.lastSeen,
                  now.timeIntervalSince(seen) <= SummarizingMac.presenceWindow else { return false }
            return device.capabilities?.models != nil
        }
        .sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
        for device in present {
            guard let capabilities = device.capabilities, seen.insert(device.id).inserted else { continue }
            result.append(ProcessingMac(id: device.id, name: device.displayName ?? "your Mac", capabilities: ProcessingCapabilities(capabilities)))
        }
        return result
    }
}
