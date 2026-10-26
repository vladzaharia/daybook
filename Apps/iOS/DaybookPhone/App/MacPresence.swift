import DaybookKit
import DaybookLink
import Foundation

/// Whether a Mac that transcribes is around, for "Waiting for your Mac · last seen 2 h ago"
/// (docs/iphone.md, "Processing on the Mac"). `PhoneAppModel.macPresence` combines the local link
/// (a paired Mac connected now) with sync presence (`Devices/` records in the library). The phone
/// never fakes it: with no Mac seen, it says so.
///
/// For the reading UI: show `waitingLine()` under a conversation whose `ProcessingStatus` is
/// `.requested(.device)`, and `summary` in Settings. Both are complete sentences.
enum MacPresence: Equatable, Sendable {
    /// Sync hasn't connected or listed the library's devices yet.
    case checking
    /// Sync can't run (no iCloud, signed out, unsigned build). The reason, in a sentence.
    case unavailable(String)
    /// A paired Mac that processes is connected over the local link right now.
    case connected(name: String)
    /// A Mac that processes last synced at `lastSeen`, by its presence record.
    case seen(name: String, lastSeen: Date)
    /// A Mac's presence says it's recording now (and that hasn't expired), with no word over the link.
    case recording(name: String, lastSeen: Date)
    /// A Mac syncs this library but doesn't process: it has no models yet, or doesn't transcribe
    /// synced recordings. Its presence record says which Mac, not why.
    case notProcessing(name: String, lastSeen: Date)
    /// A Mac running an older Daybook (no presence records) syncs this library; when isn't known.
    case olderMac
    /// No Mac has synced this library yet.
    case noMac

    /// A Mac seen within this long reads as present ("Waiting for Studio Mac") rather than "last seen".
    static let recentlySeen: TimeInterval = 15 * 60

    /// Combines the link (live) with sync presence (`KnownSyncDevice`s from `knownDevices()`).
    static func resolve(connectedMac: String?, devices: [KnownSyncDevice], syncAvailable: Bool,
                        syncReason: String?, devicesListed: Bool, now: Date = Date()) -> MacPresence {
        if let connectedMac { return .connected(name: connectedMac) }
        if let reason = syncReason, !syncAvailable { return .unavailable(reason) }
        guard devicesListed else { return .checking }
        // A recording Mac keeps its presence fresh, so this is also the Mac seen last.
        if let mac = devices.recordingMac(at: now) {
            return .recording(name: mac.displayName ?? "your Mac", lastSeen: mac.lastSeen ?? now)
        }
        if let mac = devices.latestProcessor, let seen = mac.lastSeen {
            return .seen(name: mac.displayName ?? "your Mac", lastSeen: seen)
        }
        // A Mac that checked in without processing is still this library's Mac; only with none at all
        // can a device seen only in the journal be an earlier Daybook.
        if let mac = devices.filter({ !$0.isCurrentDevice && $0.deviceClass == .mac && $0.lastSeen != nil })
            .max(by: { ($0.lastSeen ?? .distantPast) < ($1.lastSeen ?? .distantPast) }), let seen = mac.lastSeen {
            return .notProcessing(name: mac.displayName ?? "your Mac", lastSeen: seen)
        }
        return devices.hasPeersWithoutPresence ? .olderMac : .noMac
    }

    /// "Studio Mac is recording", while a Mac's presence says it's recording (and hasn't expired), for the places
    /// that show presence; nil otherwise. A recording Mac keeps its presence fresh, so it also reads as just seen.
    static func recordingLine(devices: [KnownSyncDevice], now: Date = Date()) -> String? {
        devices.recordingMac(at: now).map { "\($0.displayName ?? "Your Mac") is recording" }
    }

    var macName: String? {
        switch self {
        case .connected(let name), .seen(let name, _), .recording(let name, _), .notProcessing(let name, _): return name
        default: return nil
        }
    }

    /// Whether a request can expect a Mac soon.
    var isMacAround: Bool {
        switch self {
        case .connected, .recording: return true
        case .seen(_, let date): return Date().timeIntervalSince(date) < Self.recentlySeen
        default: return false
        }
    }

    /// The line under a conversation that waits for a Mac: "Waiting for your Mac · last seen 2 h ago".
    func waitingLine(now: Date = Date()) -> String {
        switch self {
        case .checking: return "Waiting for your Mac"
        case .unavailable: return "Waiting for iCloud"
        case .connected(let name): return "Waiting for \(name)"
        case .seen(let name, let date):
            let age = now.timeIntervalSince(date)
            if age < Self.recentlySeen { return "Waiting for \(name)" }
            return "Waiting for your Mac · last seen \(Self.age(age))"
        case .recording(let name, _): return "Waiting for \(name), which is recording"
        case .notProcessing(let name, _): return "Waiting for \(name) to transcribe"
        case .olderMac: return "Waiting for your Mac"
        case .noMac: return "No Mac has synced this library yet"
        }
    }

    /// One sentence for Settings.
    func summary(now: Date = Date()) -> String {
        switch self {
        case .checking: return "Looking for your Mac…"
        case .unavailable(let reason): return reason
        case .connected(let name): return "\(name) is connected."
        case .seen(let name, let date):
            let age = now.timeIntervalSince(date)
            return age < Self.recentlySeen ? "\(name) synced just now." : "\(name) last synced \(Self.age(age))."
        case .recording(let name, _): return "\(name) is recording."
        case .notProcessing(let name, _):
            return "\(name) isn’t set up to transcribe. Finish in Daybook › Settings on \(name)."
        case .olderMac: return "A Mac with an earlier Daybook syncs this library."
        case .noMac: return "No Mac has synced this library yet. Open Daybook on your Mac."
        }
    }

    /// "2 h ago", "3 min ago", "yesterday", "4 days ago".
    static func age(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        switch s {
        case ..<60: return "just now"
        case ..<3_600: return "\(Int(s / 60)) min ago"
        case ..<86_400: return "\(Int(s / 3_600)) h ago"
        case ..<172_800: return "yesterday"
        default: return "\(Int(s / 86_400)) days ago"
        }
    }
}

/// A Mac's live progress on one conversation, from the local link (`processing.progress`). Finer and
/// faster than the coarse progress a claim carries through sync; when both exist, show this one.
///
/// For the reading UI: `model.liveProgress[meeting.id]?.line` gives "Transcribing on Studio Mac · 40%".
/// Entries go away when the Mac finishes (sync then brings the result) or after `staleAfter` without word.
struct LiveProgress: Equatable, Sendable {
    var meetingID: UUID
    var phase: LinkProcessingProgress.Phase
    /// 0...1 within the phase, when the Mac reports one.
    var fraction: Double?
    var macName: String
    /// The Mac's own words (failures in particular).
    var detail: String?
    var receivedAt: Date

    static let staleAfter: TimeInterval = 120

    init(_ progress: LinkProcessingProgress, receivedAt: Date = Date()) {
        meetingID = progress.meetingID
        phase = progress.phase
        fraction = progress.fraction.map { min(1, max(0, $0)) }
        macName = progress.macName
        detail = progress.detail
        self.receivedAt = receivedAt
    }

    var isFinished: Bool { phase == .finished || phase == .failed }

    /// The verb for the phase: "Transcribing", "Summarizing".
    var activity: String {
        switch phase {
        case .queued: return "Waiting"
        case .aligning: return "Lining up recordings"
        case .transcribing: return "Transcribing"
        case .identifyingSpeakers: return "Identifying speakers"
        case .summarizing: return "Summarizing"
        case .paused: return "Paused"
        case .waitingForModels: return "Waiting for models"
        case .finished: return "Finished"
        case .failed: return "Couldn’t finish"
        default: return "Working"
        }
    }

    /// "Transcribing on Studio Mac · 40%".
    var line: String {
        switch phase {
        case .queued: return detail.map { "In line on \(macName) · \($0)" } ?? "In line on \(macName)"
        case .waitingForModels: return "Waiting for models on \(macName)"
        case .paused: return "Paused on \(macName)"
        case .finished: return "Finished on \(macName)"
        // The Mac's own words (`detail`) stay behind Details.
        case .failed: return "\(macName) couldn’t finish"
        default:
            let percent = fraction.map { " · \(Int(($0 * 100).rounded(.down)))%" } ?? ""
            return "\(activity) on \(macName)\(percent)"
        }
    }
}
