import Foundation
import Observation

/// The phone's own preferences (Settings › Recording and Storage). Local to this iPhone: nothing
/// here syncs. Library settings that do sync (templates, vocabulary, recorder ownership) live in
/// `LibraryController.metadata`.
@MainActor
@Observable
final class PhoneSettings {
    /// Each recording asks to be transcribed (a `ProcessingRequest`, mode `.newAudio`): here, when this
    /// iPhone has the models and transcribes on it, else by a Mac.
    var requestsTranscription: Bool { didSet { defaults.set(requestsTranscription, forKey: Keys.requestsTranscription) } }
    /// This iPhone transcribes its own recordings, and summarizes them where it can, with its own models
    /// once they're downloaded (docs/iphone.md, "Processing on this iPhone"). On by default; off, they
    /// wait for a Mac as before.
    var processesOnThisIPhone: Bool { didSet { defaults.set(processesOnThisIPhone, forKey: Keys.processesOnThisIPhone) } }
    /// Recording shows on the Lock Screen and in the Dynamic Island. When the system starts a
    /// recording from the background (an intent, a Mac's request) it needs one, so it's shown then
    /// whatever this says.
    var showsLiveActivity: Bool { didSet { defaults.set(showsLiveActivity, forKey: Keys.showsLiveActivity) } }
    /// A paired Mac may start and stop recording here ("Record on iPhone too").
    var acceptsMacRecordRequests: Bool { didSet { defaults.set(acceptsMacRecordRequests, forKey: Keys.acceptsMacRecordRequests) } }
    /// How much downloaded audio to keep for playback before the least recently played goes back to iCloud.
    var audioCacheBudget: UInt64 { didSet { defaults.set(Int64(clamping: audioCacheBudget), forKey: Keys.audioCacheBudget) } }
    /// Tentative captions on the recording screen, made on this iPhone (Speech framework).
    var liveCaptions: Bool { didSet { defaults.set(liveCaptions, forKey: Keys.liveCaptions) } }
    /// The captions' language; nil follows the iPhone's.
    var captionLocaleIdentifier: String? { didSet { defaults.set(captionLocaleIdentifier, forKey: Keys.captionLocale) } }
    /// Off by default: a recorder this iPhone took from a Mac goes back to that Mac when it connects
    /// over Wi‑Fi and the recorder is idle here (docs/devices.md, "Hand back").
    var handsRecorderBackToMac: Bool { didSet { defaults.set(handsRecorderBackToMac, forKey: Keys.handsRecorderBackToMac) } }
    /// The library goes into iPhone backups (Settings › Storage). Copies Daybook can rebuild never do
    /// (`BackupExclusion`).
    var includesLibraryInBackups: Bool { didSet { defaults.set(includesLibraryInBackups, forKey: Keys.includesLibraryInBackups) } }
    /// The same choice for an encrypted library, off unless turned on there: its conversations stay out of backups
    /// (`BackupExclusion`).
    var includesEncryptedLibraryInBackups: Bool {
        didSet { defaults.set(includesEncryptedLibraryInBackups, forKey: Keys.includesEncryptedLibraryInBackups) }
    }
    /// Encrypting the library's history here may download recordings over cellular too (Settings › iCloud, while this
    /// iPhone encrypts it). Off: it waits for Wi‑Fi, as model downloads do unless allowed.
    var encryptsOverCellular: Bool { didSet { defaults.set(encryptsOverCellular, forKey: Keys.encryptsOverCellular) } }

    var captionLocale: Locale { captionLocaleIdentifier.map(Locale.init(identifier:)) ?? .current }

    /// Whether each paired Mac may start recording here: on when a Mac is paired (recording on one
    /// device starts every device connected to it, docs/multipoint.md), and switchable in that Mac's row
    /// in Settings › Macs (Can Start Recording). A choice belongs to one pairing (by its date), so pairing
    /// again turns it on again.
    private var macRecordDecisions: [String: MacRecordDecision] {
        didSet { defaults.set(try? JSONEncoder().encode(macRecordDecisions), forKey: Keys.macRecordDecisions) }
    }
    /// When this iPhone first kept these choices (earlier builds asked after pairing).
    @ObservationIgnored let macRecordDecisionsSince: Date

    struct MacRecordDecision: Codable, Equatable {
        var allowed: Bool
        var pairedAt: Date
    }

    /// May this Mac (paired at `pairedAt`) start recording on this iPhone? Yes unless the person turned
    /// it off for this pairing.
    func macMayStartRecording(_ macID: UUID, pairedAt: Date) -> Bool {
        if let decision = macRecordDecisions[macID.uuidString], abs(decision.pairedAt.timeIntervalSince(pairedAt)) < 0.001 {
            return decision.allowed
        }
        return true
    }

    func setMacMayStartRecording(_ allowed: Bool, for macID: UUID, pairedAt: Date) {
        macRecordDecisions[macID.uuidString] = MacRecordDecision(allowed: allowed, pairedAt: pairedAt)
    }

    func forgetMacRecordDecision(_ macID: UUID) { macRecordDecisions[macID.uuidString] = nil }

    @ObservationIgnored private let defaults: UserDefaults

    /// Choices offered in Settings › Storage.
    static let budgetChoices: [UInt64] = [250_000_000, 500_000_000, 1_000_000_000, 2_000_000_000, 5_000_000_000]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        requestsTranscription = defaults.object(forKey: Keys.requestsTranscription) as? Bool ?? true
        processesOnThisIPhone = defaults.object(forKey: Keys.processesOnThisIPhone) as? Bool ?? true
        showsLiveActivity = defaults.object(forKey: Keys.showsLiveActivity) as? Bool ?? true
        acceptsMacRecordRequests = defaults.object(forKey: Keys.acceptsMacRecordRequests) as? Bool ?? true
        let stored = (defaults.object(forKey: Keys.audioCacheBudget) as? NSNumber)?.int64Value ?? 0
        audioCacheBudget = stored > 0 ? UInt64(stored) : 1_000_000_000
        liveCaptions = defaults.object(forKey: Keys.liveCaptions) as? Bool ?? true
        captionLocaleIdentifier = defaults.string(forKey: Keys.captionLocale)
        handsRecorderBackToMac = defaults.object(forKey: Keys.handsRecorderBackToMac) as? Bool ?? false
        includesLibraryInBackups = defaults.object(forKey: Keys.includesLibraryInBackups) as? Bool ?? true
        includesEncryptedLibraryInBackups = defaults.object(forKey: Keys.includesEncryptedLibraryInBackups) as? Bool ?? false
        encryptsOverCellular = defaults.bool(forKey: Keys.encryptsOverCellular)
        macRecordDecisions = defaults.data(forKey: Keys.macRecordDecisions)
            .flatMap { try? JSONDecoder().decode([String: MacRecordDecision].self, from: $0) } ?? [:]
        if let since = defaults.object(forKey: Keys.macRecordDecisionsSince) as? Date {
            macRecordDecisionsSince = since
        } else {
            let now = Date()
            defaults.set(now, forKey: Keys.macRecordDecisionsSince)
            macRecordDecisionsSince = now
        }
    }

    enum Keys {
        static let requestsTranscription = "phone.requestsTranscription"
        static let processesOnThisIPhone = "phone.processesOnThisIPhone"
        static let showsLiveActivity = "phone.showsLiveActivity"
        static let acceptsMacRecordRequests = "phone.acceptsMacRecordRequests"
        static let audioCacheBudget = "phone.audioCacheBudget"
        static let liveCaptions = "phone.liveCaptions"
        static let captionLocale = "phone.captionLocale"
        static let handsRecorderBackToMac = "phone.handsRecorderBackToMac"
        static let includesLibraryInBackups = "phone.includesLibraryInBackups"
        static let includesEncryptedLibraryInBackups = "phone.includesEncryptedLibraryInBackups"
        static let encryptsOverCellular = "phone.encryptsOverCellular"
        static let macRecordDecisions = "phone.macRecordDecisions"
        static let macRecordDecisionsSince = "phone.macRecordDecisionsSince"
    }
}
