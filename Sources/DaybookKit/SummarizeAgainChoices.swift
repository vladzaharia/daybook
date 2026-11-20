import DaybookCore
import Foundation

/// One way a conversation's summary can be made again now: on this device with a model, or in the cloud.
public struct SummarizeAgainChoice: Equatable, Identifiable, Sendable {
    public enum Place: Equatable, Sendable {
        /// This device, with the catalog model `model` (nil: the one it has, an iPhone's).
        case thisDevice(model: String?)
        /// The cloud model Settings › Cloud chose.
        case cloud(modelID: String)
    }

    public var place: Place
    /// "With Gemma 4 E4B", "With Claude Sonnet 5.5".
    public var title: String

    /// Whether `other` is in the same group of the menu (this device's, the cloud's), which has a divider between.
    public func sharesGroup(with other: SummarizeAgainChoice) -> Bool {
        switch (place, other.place) {
        case (.thisDevice, .thisDevice), (.cloud, .cloud): return true
        default: return false
        }
    }

    public var id: String {
        switch place {
        case .thisDevice(let model): return "device/\(model ?? "")"
        case .cloud(let modelID): return "cloud/\(modelID)"
        }
    }
}

/// What Summarize Again offers (docs/cloud.md, "When the cloud is chosen"), the same on both apps: every way this
/// conversation's summary can be redone now, in order: this device's usable models (the one a plain Summarize Again
/// uses first), then the cloud's model. A way that isn't there now is
/// absent, never dimmed. Pure: each app says what it has.
public enum SummarizeAgainChoices {
    /// A summary model installed and usable on this device now.
    public struct LocalModel: Equatable, Sendable {
        public var id: String
        public var name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }

    /// - Parameters:
    ///   - local: The summary models usable on this device now (installed, and the memory for them).
    ///   - defaultLocal: The one a plain Summarize Again runs, first in its group.
    ///   - cloud: The model Settings › Cloud resolves to; nil without the person's own key. It's offered only while the
    ///     policy isn't Never and this device's switch for the conversation's placement is on (`allowsCloud`), which
    ///     the code that sends checks again.
    public static func rows(for meeting: Meeting, local: [LocalModel], defaultLocal: String?, cloud: CloudModel?,
                            preferences: CloudSummaryPreferences) -> [SummarizeAgainChoice] {
        let ordered = local.filter { $0.id == defaultLocal } + local.filter { $0.id != defaultLocal }.sorted { $0.name < $1.name }
        var rows = ordered.map { SummarizeAgainChoice(place: .thisDevice(model: $0.id), title: "With \($0.name)") }
        if let cloud, preferences.allowsCloud(for: meeting) {
            rows.append(SummarizeAgainChoice(place: .cloud(modelID: cloud.id), title: "With \(cloud.name)"))
        }
        return rows
    }
}
