import Foundation

// What Settings › Models shows on both apps, as plain values (docs/models.md, "The model manager"): a model's state, a
// role's choice and what it says about it, the space a download needs, and what removing a model does. The Mac's
// `ModelManagerSnapshot` and the iPhone's `PhoneModels` make them; DaybookUI's model rows draw them.

// MARK: - Status

/// A model's state on this device, as its rows, menus, and details show it.
public enum ModelStatus: Equatable, Sendable {
    /// This build or this device can't run it ("Needs a newer Daybook", "Needs an iPhone with more memory").
    case unavailable(String)
    case notDownloaded
    /// Files went missing or changed size since they were checked.
    case damaged
    /// In the download queue, after the one downloading now.
    case waiting
    /// Asked for, waiting for Wi‑Fi because downloads may not use cellular data.
    case waitingForWiFi
    case downloading(Double)
    /// The last download stopped, in the system's words.
    case failed(String)
    case updateAvailable
    case downloaded
    case inUse
    /// Provided by the system: nothing to download.
    case builtIn

    /// "Not downloaded", "Downloading · 40%", "Included with macOS".
    public var label: String {
        switch self {
        case .unavailable(let reason): return reason
        case .notDownloaded: return "Not downloaded"
        case .damaged: return "Needs downloading again"
        case .waiting: return "Waiting to download"
        case .waitingForWiFi: return "Waiting for Wi‑Fi"
        case .downloading(let fraction): return "Downloading · \(Self.percent(fraction))%"
        case .failed(let reason): return reason
        case .updateAvailable: return "Update available"
        case .downloaded: return "Downloaded"
        case .inUse: return "In use"
        case .builtIn:
            #if os(iOS)
            return "Included with iOS"
            #else
            return "Included with macOS"
            #endif
        }
    }

    /// Whole percents, rounded down, as every progress says them.
    public static func percent(_ fraction: Double) -> Int {
        Int((min(max(fraction.isFinite ? fraction : 0, 0), 1) * 100).rounded(.down))
    }

    /// It can run now.
    public var isReady: Bool { [.downloaded, .inUse, .updateAvailable, .builtIn].contains(self) }
    public var isAvailable: Bool { if case .unavailable = self { return false }; return true }
    /// Downloading, or waiting its turn or for Wi‑Fi.
    public var isTransferring: Bool {
        switch self {
        case .downloading, .waiting, .waitingForWiFi: return true
        default: return false
        }
    }
    /// Download is what to do next.
    public var canDownload: Bool {
        switch self {
        case .notDownloaded, .damaged, .failed: return true
        default: return false
        }
    }
    /// A download just finished: the row turns its bar into a checkmark for a moment. A download that was cancelled or
    /// failed, or a ready model chosen for a role, isn't one.
    public static func finishedDownloading(from old: ModelStatus?, to new: ModelStatus?) -> Bool {
        old?.isTransferring == true && new?.isReady == true
    }

    /// Said in the warning ink: it needs the person.
    public var needsAttention: Bool {
        switch self {
        case .damaged, .unavailable, .failed: return true
        default: return false
        }
    }
}

// MARK: - Choices

/// One choice in a role's menu.
public struct ModelOption: Identifiable, Equatable, Sendable {
    public let key: String
    public let name: String
    /// "Downloaded", "1.6 GB", "Needs a newer Daybook", with " · Non-commercial" where it applies.
    public let detail: String
    public let isEnabled: Bool
    public var id: String { key }

    public init(key: String, name: String, detail: String, isEnabled: Bool) {
        self.key = key; self.name = name; self.detail = detail; self.isEnabled = isEnabled
    }

    /// A menu item's detail: the state ("Downloaded", its download size, why it can't run here), then "Non-commercial"
    /// where it applies.
    public static func detail(for model: CatalogModel, status: ModelStatus) -> String {
        let state: String
        switch status {
        case .downloaded, .inUse, .updateAvailable: state = "Downloaded"
        case .notDownloaded, .damaged, .failed: state = ByteSize.format(model.approximateBytes)
        default: state = status.label
        }
        return ([state] + ModelLabels.of(model).filter { $0 == ModelLabels.nonCommercial }).joined(separator: " · ")
    }
}

/// A role's choice: what's selected, what else it could be, how the selected model stands, and the space its
/// download needs.
public struct ModelRoleChoice: Identifiable, Equatable, Sendable {
    public let role: ModelRole
    public let selection: String?
    public let options: [ModelOption]
    public let selectedModel: CatalogModel?
    public let status: ModelStatus?
    /// What downloading the selected model still takes: its size, less what an unfinished download already fetched.
    public let downloadBytes: Int64
    public var id: String { role.rawValue }
    public var title: String { role.displayName }

    public init(role: ModelRole, selection: String?, options: [ModelOption], selectedModel: CatalogModel?, status: ModelStatus?,
                downloadBytes: Int64? = nil) {
        self.role = role; self.selection = selection; self.options = options; self.selectedModel = selectedModel; self.status = status
        self.downloadBytes = max(0, downloadBytes ?? selectedModel?.approximateBytes ?? 0)
    }

    /// The selected model's name, or what the role has instead.
    public var selectionName: String {
        selectedModel?.name ?? options.first { $0.key == selection }?.name ?? "Choose a Model"
    }

    /// What its row says under the role: nothing while the chosen model is ready; otherwise its state, what to
    /// download ("Not downloaded · 632 MB"), or, when there isn't room for it, how much it needs ("Needs 632 MB · 300 MB
    /// free").
    public func line(space: ModelSpace = .unknown) -> ModelLine? {
        guard let status else {
            return selection == nil ? ModelLine("Choose a model") : ModelLine("No longer available", needsAttention: true)
        }
        switch status {
        case .notDownloaded, .damaged, .failed:
            if let shortfall = space.shortfall(downloadBytes) { return ModelLine(shortfall, needsAttention: true) }
            if status == .notDownloaded { return ModelLine("Not downloaded · \(ByteSize.format(downloadBytes))") }
            return ModelLine(status.label, needsAttention: true)
        case .waiting, .waitingForWiFi, .downloading, .unavailable:
            return ModelLine(status.label, needsAttention: status.needsAttention)
        case .downloaded, .inUse, .updateAvailable, .builtIn:
            return nil
        }
    }

    /// Download is offered: the chosen model isn't here, and there's room for it.
    public func canDownload(space: ModelSpace = .unknown) -> Bool {
        selectedModel != nil && status?.canDownload == true && space.fits(downloadBytes)
    }

    /// Which model is chosen and how it stands: what a role's row watches for its checkmark.
    public struct Standing: Equatable, Sendable {
        public let selection: String?
        public let status: ModelStatus?
    }

    public var standing: Standing { Standing(selection: selection, status: status) }

    /// The chosen model's download just finished. Choosing a model that's already here while another is still on its
    /// way isn't one.
    public static func finishedDownloading(from old: Standing, to new: Standing) -> Bool {
        old.selection == new.selection && ModelStatus.finishedDownloading(from: old.status, to: new.status)
    }
}

/// A row's line: its words, in the warning ink when it needs the person.
public struct ModelLine: Equatable, Sendable {
    public let text: String
    public let needsAttention: Bool
    public init(_ text: String, needsAttention: Bool = false) { self.text = text; self.needsAttention = needsAttention }
}

/// Facts about a model as labels: "Non-commercial" from its license, "Added by you" from where it came from.
public enum ModelLabels {
    public static let nonCommercial = "Non-commercial"
    public static let recommended = "Recommended"

    /// What VoiceOver adds to the recommended preset: the device it's recommended for.
    public static var recommendedHint: String {
        #if os(iOS)
        return "Recommended for this iPhone"
        #else
        return "Recommended for this Mac"
        #endif
    }

    public static func of(_ model: CatalogModel) -> [String] {
        var labels: [String] = []
        if model.license?.allowsCommercialUse != true { labels.append(nonCommercial) }
        if let origin = model.origin.label { labels.append(origin) }
        return labels
    }
}

// MARK: - Space

/// How much room this device has for downloads, and the words when a download won't fit: "Needs 16.5 GB · 12 GB free".
/// A model download that fills the disk stops recordings and sync too, so Download waits until there's room. What's
/// free sets aside what the downloads already under way and waiting will still take (`less`).
public struct ModelSpace: Equatable, Sendable {
    /// Bytes free where models go; nil when the system didn't say, which stops nothing.
    public var free: Int64?

    public init(free: Int64?) { self.free = free }

    public static let unknown = ModelSpace(free: nil)

    /// What's free on the volume holding `url` for things the person asked for (`volumeAvailableCapacityForImportantUsage`).
    public static func available(at url: URL) -> ModelSpace {
        var folder = url
        // The folder may not exist yet: its nearest parent that does is on the same volume.
        while !FileManager.default.fileExists(atPath: folder.path), folder.pathComponents.count > 1 { folder.deleteLastPathComponent() }
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let free = values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map(Int64.init)
        return ModelSpace(free: free)
    }

    public func fits(_ bytes: Int64) -> Bool { free.map { bytes <= $0 } ?? true }

    /// What's left for another download once `bytes` are set aside for the downloads under way and waiting, so two that
    /// each fit but together wouldn't don't both start.
    public func less(_ bytes: Int64) -> ModelSpace { ModelSpace(free: free.map { max(0, $0 - max(0, bytes)) }) }

    /// What a download still takes from what's free: its size, less what it had fetched when the space was read (its
    /// partial files, or its progress where that says more, as while a file is still arriving).
    public static func stillToFetch(_ size: Int64, partial: Int64 = 0, fraction: Double? = nil) -> Int64 {
        let fraction = fraction.map { $0.isFinite ? min(max($0, 0), 1) : 0 } ?? 0
        return max(0, size - max(partial, Int64(Double(size) * fraction)))
    }

    /// "Needs 16.5 GB · 12 GB free", or nil when it fits.
    public func shortfall(_ bytes: Int64) -> String? {
        guard let free, bytes > free else { return nil }
        return "Needs \(ByteSize.format(bytes)) · \(ByteSize.format(max(0, free))) free"
    }
}

// MARK: - Downloading what's chosen

/// The row that downloads everything a section's choices still need: "Not downloaded yet · 852 MB" with Download, then
/// its progress with Cancel.
public enum ModelDownloadSummary: Equatable, Sendable {
    /// Models still to download. `partly`: some of what's chosen is here already, so the names say which aren't.
    case missing(names: [String], bytes: Int64, partly: Bool)
    /// All of it is on its way: so much of the total is here.
    case downloading(done: Int64, total: Int64)

    public var title: String {
        switch self {
        case .missing(_, _, let partly): return partly ? "Partly downloaded" : "Not downloaded yet"
        case .downloading: return "Downloading"
        }
    }

    /// "852 MB", "Parakeet Ultra, Community-1 · 654 MB", "0.4 of 1.6 GB", or what it needs when there isn't room.
    public func line(space: ModelSpace = .unknown) -> ModelLine {
        switch self {
        case .missing(let names, let bytes, let partly):
            if let shortfall = space.shortfall(bytes) { return ModelLine(shortfall, needsAttention: true) }
            return ModelLine(((partly ? [names.joined(separator: ", ")] : []) + [ByteSize.format(bytes)]).joined(separator: " · "))
        case .downloading(let done, let total):
            return ModelLine(ByteSize.progress(done, of: total))
        }
    }

    public var fraction: Double {
        guard case .downloading(let done, let total) = self, total > 0 else { return 0 }
        return min(1, max(0, Double(done) / Double(total)))
    }

    public func canDownload(space: ModelSpace = .unknown) -> Bool {
        guard case .missing(_, let bytes, _) = self else { return false }
        return space.fits(bytes)
    }
}

// MARK: - Removing

/// What removing a model says, the same on both apps: "Remove Whisper Base?", then what it frees and what happens to
/// each role that chose it ("Frees 489 MB. Transcription will use Whisper Small." or "Transcription will wait until
/// you download it again.").
public enum ModelRemovalWords {
    /// What happens to one role that chose the model.
    public enum Change: Equatable, Sendable {
        /// The role moves to another model (`onceDownloaded`: one that isn't here yet).
        case switched(ModelRole, to: String, onceDownloaded: Bool)
        /// The role keeps its choice and waits for it to be downloaded again.
        case waits(ModelRole)
        /// No other model can stand in.
        case needsAnother(ModelRole)
    }

    public static func title(_ name: String, removesEntry: Bool = false) -> String {
        removesEntry ? "Remove \(name) from Daybook?" : "Remove \(name)?"
    }

    public static func message(frees bytes: Int64, changes: [Change], removesEntry: Bool = false) -> String {
        var sentences: [String] = bytes > 0 ? ["Frees \(ByteSize.format(bytes))."] : []
        for change in changes {
            switch change {
            case .switched(let role, let name, let onceDownloaded):
                sentences.append("\(SettingsWords.roleSubject(role)) will use \(name)\(onceDownloaded ? ", once it’s downloaded" : "").")
            case .waits(let role):
                sentences.append("\(SettingsWords.roleSubject(role)) will wait until you download it again.")
            case .needsAnother(let role):
                sentences.append("\(SettingsWords.roleSubject(role)) will need another model.")
            }
        }
        if changes.isEmpty { sentences.append(removesEntry ? "You can add it again later." : "You can download it again at any time.") }
        return sentences.joined(separator: " ")
    }
}

// MARK: - Quality presets

/// One of the qualities a device offers (Quick, Balanced, Detailed), or the person's own mix (Custom): its models, what
/// they take, and whether it's this device's recommendation.
public struct ModelQualityOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    /// Custom: what the choices add up to, never something to choose.
    public let isCustom: Bool
    public let isRecommended: Bool
    public let isCurrent: Bool
    /// The models' short names, the ones that set the presets apart first.
    public let names: [String]
    public let bytes: Int64
    public let memoryGB: Int

    public init(id: String, title: String, isCustom: Bool, isRecommended: Bool, isCurrent: Bool, names: [String], bytes: Int64, memoryGB: Int) {
        self.id = id; self.title = title; self.isCustom = isCustom; self.isRecommended = isRecommended; self.isCurrent = isCurrent
        self.names = names; self.bytes = bytes; self.memoryGB = memoryGB
    }

    /// "32 GB memory".
    public var memory: String { "\(memoryGB) GB memory" }

    /// The order a preset's models are named in: roles whose model differs between presets first (the summary, then
    /// speakers), the ones every preset shares last, so a row cut short still shows what sets it apart.
    public static func ordered(_ roles: [ModelRole], differing: Set<ModelRole>) -> [ModelRole] {
        let priority: [ModelRole] = [.summarization, .diarization, .speakerEmbedding, .smallTasks, .transcription, .imageDescription]
        func rank(_ role: ModelRole) -> Int { priority.firstIndex(of: role) ?? priority.count }
        return roles.sorted { a, b in
            let da = differing.contains(a), db = differing.contains(b)
            if da != db { return da }
            return rank(a) == rank(b) ? a.rawValue < b.rawValue : rank(a) < rank(b)
        }
    }
}
