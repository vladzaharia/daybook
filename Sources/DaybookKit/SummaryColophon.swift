import DaybookCore
import Foundation

/// The line at the foot of a summary's page, the same on both apps (docs/interface.md, "Facts, not slogans"): where
/// it ran, the model that made it when it ran on a device, and when, with the glyph for where it ran.
///
/// - "Summarized on this Mac · Gemma 4 E4B · 31 Oct, 10:02" (the Mac's glyph by its name: a MacBook's laptop)
/// - "Summarized on Alex’s iPhone · Gemma 4 E2B · 31 Oct, 10:02" (an iPhone)
/// - "Summarized with Claude Sonnet 5.5 · 31 Oct, 10:02" (the cloud)
///
/// The colophon shows only once there's a summary: a transcript without one says "Not summarized yet" in its status.
public struct SummaryColophon: Equatable, Sendable {
    public var line: String
    public var symbol: String

    public init(line: String, symbol: String) { self.line = line; self.symbol = symbol }

    /// `summary`'s colophon as `words` would say it on the device whose sync ID is `thisDeviceID`. `deviceClass` is
    /// what the device that ran it says it is (its presence record), when this device knows; otherwise its name
    /// says. `catalog` names the local model (the Mac's includes the models people added).
    public init(_ summary: MeetingSummary, thisDeviceID: String, words: DeviceWords, catalog: ModelCatalog = .builtIn,
                deviceClass: SyncDeviceClass? = nil) {
        let origin = summary.origin
        var parts = [origin.colophon(thisDeviceID: thisDeviceID, thisDevice: words.here, unknown: words.unknown)]
        if origin.cloudModel == nil, let model = Self.modelName(summary, catalog: catalog) { parts.append(model) }
        parts.append(Self.date(summary.createdAt))
        line = parts.joined(separator: " · ")
        symbol = Self.symbol(origin, thisDeviceID: thisDeviceID, words: words, deviceClass: deviceClass)
    }

    /// The local model's name, as the interface names it; nil when the summary doesn't say.
    static func modelName(_ summary: MeetingSummary, catalog: ModelCatalog) -> String? {
        let provenance = summary.processingSettings?.model
        guard provenance != nil || !summary.modelID.isEmpty else { return nil }
        let name = catalog.name(for: summary.modelID, provenance: provenance)
        return name.isEmpty ? nil : name
    }

    /// "31 Oct, 10:02", in the reader's locale.
    public static func date(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    /// One glyph rule: the cloud's; this device's own; another device by what it says it is, else what its name
    /// says ("Alex’s iPhone", "Studio Mac"); a summary from before devices were recorded was made on a Mac.
    public static func symbol(_ origin: SummaryOrigin, thisDeviceID: String, words: DeviceWords,
                              deviceClass: SyncDeviceClass? = nil) -> String {
        if origin.cloudModel != nil { return "cloud" }
        guard let deviceID = origin.deviceID else {
            return words.unknown == words.here ? words.symbol : SettingsWords.deviceSymbol(.mac)
        }
        if deviceID == thisDeviceID { return words.symbol }
        guard let kind = deviceClass ?? inferredClass(origin.deviceName) else { return "macbook.and.iphone" }
        return SettingsWords.deviceSymbol(kind, name: origin.deviceName)
    }

    /// What a device's name says it is, for a device this one has no presence record of.
    static func inferredClass(_ name: String?) -> SyncDeviceClass? {
        guard let name else { return nil }
        if name.range(of: "iPhone", options: .caseInsensitive) != nil || name.range(of: "iPad", options: .caseInsensitive) != nil {
            return .phone
        }
        if name.range(of: "Mac", options: .caseInsensitive) != nil { return .mac }
        return nil
    }
}
