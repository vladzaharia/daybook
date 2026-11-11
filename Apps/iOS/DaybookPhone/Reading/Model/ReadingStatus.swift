import DaybookKit
import Foundation

/// When a Mac was last heard from, for "Last seen 2 h ago" (`ConversationStatusPresentation.MacStanding.phone`). The
/// library carries the evidence: a Mac's claim heartbeats and finished requests, and the transcripts and summaries it
/// wrote. The local link, which knows sooner, can inject its own through `\.macSighting`.
struct MacSighting: Equatable {
    var name: String?
    var date: Date

    /// The latest sign of a Mac at work in any conversation, other than this device's own: its requests, the summaries
    /// it made, and the transcripts of the recordings it `owns`, which it transcribes itself or a Mac does through a
    /// request whose claim says so. An iPhone that transcribed alone has seen no Mac.
    static func latest(in meetings: [Meeting], excluding deviceID: String?,
                       owns: (RecordingTrack) -> Bool = { _ in false }) -> MacSighting? {
        var best: MacSighting?
        func consider(_ date: Date, _ name: String?) {
            if best == nil || date > best!.date { best = MacSighting(name: name, date: date) }
        }
        for meeting in meetings {
            for request in meeting.processingRequests ?? [] {
                if let claim = request.claim, claim.device.id != deviceID { consider(claim.heartbeat, claim.device.name) }
                if let outcome = request.outcome, outcome.device.id != deviceID { consider(outcome.finishedAt, outcome.device.name) }
            }
            for run in meeting.transcripts where !(meeting.tracks.first { $0.id == run.trackID }.map(owns) ?? false) {
                consider(run.createdAt, nil)
            }
            if let summary = meeting.summary, deviceID == nil || summary.origin.deviceID != deviceID { consider(summary.createdAt, nil) }
        }
        return best
    }
}

// MARK: - The page's inputs

extension ConversationStatusPresentation.MacStanding {
    /// Whether a Mac is around for this iPhone, one way wherever it shows: the link first (connected, and whether that
    /// Mac records or works on another conversation), then sync presence, then the library's own evidence of a Mac at
    /// work (`MacSighting`), whichever is later. `override` (the demo's) says a sighting is the whole story.
    static func phone(presence: MacPresence?, sighting: MacSighting?, override: Bool = false, connected: [PhoneLink.Mac],
                      liveProgress: [UUID: LiveProgress], meetingID: UUID, now: Date = Date()) -> Self {
        let seen = sighting.map { Self.seen(name: $0.name, at: $0.date) }
        if override, let seen { return seen }
        switch presence {
        case .connected(let name)?:
            if connected.first(where: { $0.name == name })?.isRecording == true { return .recording(name) }
            if liveProgress.values.contains(where: { $0.macName == name && !$0.isFinished && $0.meetingID != meetingID }) { return .busy(name) }
            return .connected(name)
        case .recording(let name, _)?: return .recording(name)
        case .notProcessing(let name, _)?: return .notProcessing(name)
        case .seen(let name, let date)?:
            if let sighting, sighting.date > date { return .seen(name: sighting.name ?? name, at: sighting.date) }
            return .seen(name: name, at: date)
        case .unavailable?: return .needsICloud
        case .noMac?: return seen ?? .noMac
        case .checking?, .olderMac?: return seen ?? .checking
        case nil: return seen ?? .noMac
        }
    }
}

extension ConversationStatusPresentation.LinkWork {
    /// A Mac's live progress over the link, as the page reads it.
    init(live: LiveProgress) {
        self.init(phase: live.phase, fraction: live.fraction, device: live.macName, countdownUntil: live.countdownUntil,
                  cloudModel: live.cloudModel, placementActions: live.placementActions)
    }
}

extension ProcessingWords.PauseReason {
    /// Why this iPhone's processing waits.
    init(phone pause: PhoneProcessor.Pause) {
        switch pause {
        case .recording: self = .recording
        // Locked, nothing shows it; unlocked, it goes on at once (or with Daybook open, as background work does).
        case .background, .locked: self = .background
        case .heat: self = .heat
        case .lowPowerMode: self = .lowPowerMode
        case .lowBattery: self = .lowBattery
        }
    }
}
