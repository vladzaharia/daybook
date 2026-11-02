import AVFoundation
import DaybookKit
import DaybookLink
import Foundation
import Observation

/// Daybook on iPhone, from this Mac's side, as state: the recordings this Mac makes because a phone asked, whose word
/// is stopping this Mac's recording, conversations an iPhone recording moved out of or whose transcript is being
/// checked, the live progress sent to phones, and the notes kept in step with the phones recording along.
/// `AppState+Phone.swift` and `AppState+SharedNotes.swift` drive it; what they share goes through here rather than
/// through each other's properties.
@MainActor
@Observable
final class PhoneCoordinator {
    /// Recordings this Mac is making because a phone asked, by conversation.
    var leads: [UUID: CompanionLead] = [:]
    /// The device whose word is stopping this Mac's recording now (a phone that stopped, or asked this Mac to stop), by
    /// session ID: it isn't asked to stop in turn.
    var stopCause: String?
    /// A recorder whose own button is starting this Mac's recording, by session ID.
    var pendingRecorderLead: String?
    /// Conversations an iPhone recording moved out of, on their way to the Trash: not processed.
    var movedRecordings: Set<UUID> = []
    /// Conversations of an iPhone's own queued only to check where its recording belongs (`phoneTranscriptArrived`):
    /// phones aren't told, since this Mac doesn't summarize them (the iPhone does, or its countdown goes on).
    var checkingTranscripts: Set<UUID> = []
    /// The last live progress sent to phones, and when; sends go out one after another, in order.
    @ObservationIgnored var lastProgress: (message: LinkProcessingProgress, at: Date)?
    @ObservationIgnored var progressSend: Task<Void, Never>?
    /// Notes and bookmarks of this Mac's recording, kept in step with the phones recording it too.
    let sharedNotes = SharedNotesTracker()
    @ObservationIgnored var sharedNotesWatch: ObservationWatch?
    @ObservationIgnored var sharedNotesSend: Task<Void, Never>?
    /// Starts and stops this Mac's capture when a phone asks. Tests replace it: no microphone.
    @ObservationIgnored var capture = PhoneCapture()
    /// Whether this Mac may use the microphone without asking. Tests replace it.
    @ObservationIgnored var microphoneAccess: () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) }

    /// This Mac's recording of `id` is over: no phone leads it any more.
    func recordingEnded(_ id: UUID) { leads[id] = nil }
}
