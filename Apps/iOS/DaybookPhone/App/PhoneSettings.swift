import Foundation
import Observation

/// The phone's own preferences (Settings › Recording and Storage). Local to this iPhone: nothing
/// here syncs. Library settings that do sync (templates, vocabulary, recorder ownership) live in
/// `LibraryController.metadata`.
@MainActor
@Observable
final class PhoneSettings {
    /// Each recording asks a Mac to transcribe it (a `ProcessingRequest`, mode `.newAudio`).
    var requestsTranscription: Bool { didSet { defaults.set(requestsTranscription, forKey: Keys.requestsTranscription) } }
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

    var captionLocale: Locale { captionLocaleIdentifier.map(Locale.init(identifier:)) ?? .current }

    @ObservationIgnored private let defaults: UserDefaults

    /// Choices offered in Settings › Storage.
    static let budgetChoices: [UInt64] = [250_000_000, 500_000_000, 1_000_000_000, 2_000_000_000, 5_000_000_000]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        requestsTranscription = defaults.object(forKey: Keys.requestsTranscription) as? Bool ?? true
        showsLiveActivity = defaults.object(forKey: Keys.showsLiveActivity) as? Bool ?? true
        acceptsMacRecordRequests = defaults.object(forKey: Keys.acceptsMacRecordRequests) as? Bool ?? true
        let stored = (defaults.object(forKey: Keys.audioCacheBudget) as? NSNumber)?.int64Value ?? 0
        audioCacheBudget = stored > 0 ? UInt64(stored) : 1_000_000_000
        liveCaptions = defaults.object(forKey: Keys.liveCaptions) as? Bool ?? true
        captionLocaleIdentifier = defaults.string(forKey: Keys.captionLocale)
        handsRecorderBackToMac = defaults.object(forKey: Keys.handsRecorderBackToMac) as? Bool ?? false
    }

    enum Keys {
        static let requestsTranscription = "phone.requestsTranscription"
        static let showsLiveActivity = "phone.showsLiveActivity"
        static let acceptsMacRecordRequests = "phone.acceptsMacRecordRequests"
        static let audioCacheBudget = "phone.audioCacheBudget"
        static let liveCaptions = "phone.liveCaptions"
        static let captionLocale = "phone.captionLocale"
        static let handsRecorderBackToMac = "phone.handsRecorderBackToMac"
    }
}
