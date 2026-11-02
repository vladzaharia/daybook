import AVFoundation
import DaybookCaptions
import DaybookKit
import DaybookLive
import DaybookUI
import Foundation
import Observation

/// Live captions for the recording in progress, from a DaybookCaptions captioner fed by the
/// recorder's tap, saved phone-locally and never synced. They're feedback that the audio is being
/// heard and something to read until a transcript arrives; they're never the transcript.
///
/// What the Mac does too (the captioner, saving every few seconds and at Stop, a recorder's lines added
/// by `received` without repeating this iPhone's, finishing with what stands kept as heard) is the
/// shared `LiveCaptionSession`; this adds the iPhone's own: filing the captions with their recording
/// (`attach`) and labelling their speakers afterwards (`waitingForSpeakers`, `saveLabelled`).
///
/// The recording never depends on them: the captioner runs on its own tasks and drops audio when
/// it falls behind; a captioner that fails only changes `state`.
@MainActor
@Observable
final class LiveCaptionsController {
    /// The recording's captioner, what it's heard, and its saving.
    let session: LiveCaptionSession
    /// Makes the captioner for a recording; nil when captions are off or can't run in this build.
    @ObservationIgnored var makeCaptioner: () -> (any LiveCaptioning)?

    init(store: LiveCaptionStore, makeCaptioner: @escaping () -> (any LiveCaptioning)?) {
        session = LiveCaptionSession(store: store)
        self.makeCaptioner = makeCaptioner
    }

    /// Where the captioner stands; off between recordings.
    var state: LiveCaptionState { session.states[.microphone] ?? .off }
    /// This iPhone's captions with a recorder's added, in time order.
    var segments: [LiveCaptionSegment] { session.segments }
    /// Other devices' names by source (raw value), for their lines' labels.
    var sourceNames: [String: String] { session.sourceNames }
    var meetingID: UUID? { session.meetingID }
    var localeIdentifier: String { session.localeIdentifier }
    /// When captions were last written to the store, so pages showing saved captions read them again.
    var lastSave: Date? { session.lastSave }
    var store: LiveCaptionStore { session.store }

    /// The most recent segments, oldest first, for the recording screen.
    func recent(_ count: Int) -> [LiveCaptionSegment] { session.recent(count) }

    /// Whether the recording screen shows captions. When they can't run here (a language without
    /// captions, no Speech support) the screen stays quiet and Settings says why.
    var isShowing: Bool {
        switch state {
        case .off, .unavailable, .finished: return false
        default: return true
        }
    }

    /// Recording into this conversation now.
    var activeMeetingID: UUID? { session.isActive ? session.meetingID : nil }

    // MARK: A recording

    /// Before the recorder starts: makes the captioner and returns the tap to give the recorder.
    func prepare(meetingID: UUID) -> (@Sendable (AVAudioPCMBuffer, TimeInterval) -> Void)? {
        let captioner = makeCaptioner()
        guard session.begin(meetingID: meetingID, captioners: captioner.map { [(.microphone, $0)] } ?? []), let captioner else { return nil }
        // The recorder's host time (seconds) becomes the buffer's time on the recording's timeline.
        return { buffer, host in
            captioner.append(buffer, at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: host)))
        }
    }

    /// The recorder is running: listen in `locale`. Returns once the captioner has started (or said why not).
    func start(locale: Locale) async {
        await session.start(locale: locale)
    }

    /// The recording stopped: finish captioning, keep what stands as heard, and save. Returns once saved.
    func finish() async {
        await session.finish()
    }

    // MARK: Recorders

    /// A recorder recording along captioned its live audio (all it has heard); `offset` moves its times
    /// onto this recording's. Ignored unless this iPhone is captioning a recording.
    func received(_ segments: [LiveCaptionSegment], from source: LiveCaptionSource, name: String, offset: TimeInterval) {
        session.received(segments, from: source, name: name, offset: offset)
    }

    /// The recording was filed: the captions belong to its phone track. Returns once that's saved, so
    /// they're waiting for their speakers (`waitingForSpeakers`) as soon as it does.
    func attach(trackID: UUID, meetingID: UUID) async {
        let filed = try? await store.update(meetingID) { captions in
            captions.trackID = trackID
            captions.updatedAt = Date()
            return true
        }
        if let filed { session.savedElsewhere(at: filed.updatedAt) }
    }

    // MARK: Speakers afterwards

    /// Saved captions with stretches the live speaker model didn't hear (`LiveSpeakerPass`), filed
    /// with their recording, other than the recording in progress.
    func waitingForSpeakers() -> [LiveCaptions] {
        store.conversations().compactMap { id -> LiveCaptions? in
            guard id != activeMeetingID, let captions = store.captions(for: id), captions.trackID != nil,
                  LiveSpeakerPass.isNeeded(captions) else { return nil }
            return captions
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    /// Keeps captions labelled afterwards, unless they changed since the pass read them.
    func saveLabelled(_ labelled: LiveCaptions) {
        guard labelled.meetingID != activeMeetingID else { return }
        let store = self.store
        Task { [weak self] in
            let saved = try? await store.update(labelled.meetingID) { current in
                guard current.segments.map(\.id) == labelled.segments.map(\.id), current.trackID == labelled.trackID else { return false }
                current = labelled
                return true
            }
            if let saved { self?.session.savedElsewhere(at: saved.updatedAt) }
        }
    }

    /// Removes the captions transcripts replaced, and those of conversations in the Trash (`trashed`), off
    /// the main actor (`LiveCaptionStore.prune`). The recording in progress keeps its own, and so does a
    /// recording that isn't filed yet, whose conversation the library doesn't have: one stopped a moment
    /// ago, or one a crash left for recovery.
    func prune(meetings: [Meeting], trashed: [UUID]) {
        let store = self.store, keeping = activeMeetingID, trashed = Set(trashed)
        Task { await store.prune(meetings: meetings, keeping: keeping, trashed: trashed) }
    }
}
