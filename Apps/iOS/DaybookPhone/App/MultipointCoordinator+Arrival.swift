import DaybookKit
import DaybookLink
import Foundation

/// A recording of this iPhone's that a Mac waits for (docs/multipoint.md, "Mac first"), from Stop until it's on its way
/// through sync: each connected Mac that hears it is told where it stands (`recording.arrival`), and the conversation's
/// page here says it too.
struct OutgoingRecording: Equatable {
    var conversationID: UUID
    /// The recording's own ID, which its track carries.
    var recordingID: String?
    var phase: LinkRecordingArrival.Phase
    /// When it was filed; nil while it's being saved.
    var filedAt: Date?
    /// When it was first owed, for letting go of one that never got anywhere.
    var since: Date
}

extension MultipointCoordinator {
    /// An outgoing recording not on its way after this long is let go of here (the Mac stops waiting after two days).
    static let outgoingLifetime: TimeInterval = 2 * 86_400

    /// Stop began filing a recording a Mac waits for (`join` placed it with one).
    func outgoingFiling(_ conversationID: UUID, recordingID: String?) {
        outgoing[conversationID] = OutgoingRecording(conversationID: conversationID, recordingID: recordingID, phase: .filing, filedAt: nil,
                                                     since: Date())
        report(conversationID)
    }

    /// It's filed (into `conversationID`, which may differ from the one it was being saved into), or it couldn't be (nil).
    func outgoingFiled(_ recordingConversation: UUID, into conversationID: UUID?) {
        guard var entry = outgoing.removeValue(forKey: recordingConversation) else { return }
        guard let conversationID else { return }
        entry.conversationID = conversationID
        entry.filedAt = Date()
        entry.phase = .sending
        outgoing[conversationID] = entry
        report(conversationID)
        refreshOutgoing()
    }

    /// Where each outgoing recording stands, from sync: held back (iCloud storage full, the library's key not here), on
    /// its way until a pass after filing left nothing to upload (or the courier sent it), then sent, and let go of.
    func refreshOutgoing(now: Date = Date()) {
        guard !outgoing.isEmpty, let sync = app?.sync else { return }
        for (id, entry) in outgoing {
            guard let filedAt = entry.filedAt else { continue }
            var phase: LinkRecordingArrival.Phase = .sending
            if sync.isStorageFull { phase = .storageFull }
            else if sync.encryption == .waitingForKey { phase = .waitingForKey }
            else if let synced = sync.lastSynced, synced > filedAt,
                    sync.pendingUploads == 0 || (sync.courier.availability == .available && sync.courier.waitingToSend == 0) {
                phase = .sent
            }
            if phase == .sent || now.timeIntervalSince(entry.since) > Self.outgoingLifetime {
                outgoing[id] = nil
                report(OutgoingRecording(conversationID: id, recordingID: entry.recordingID, phase: .sent, filedAt: filedAt, since: entry.since))
            } else if phase != entry.phase {
                outgoing[id]?.phase = phase
                report(id)
            }
        }
    }

    /// Tells the Macs that hear it (or one, as it connects) where every outgoing recording stands.
    func reportOutgoing(to macID: UUID? = nil) {
        for id in outgoing.keys { report(id, to: macID) }
    }

    private func report(_ id: UUID, to macID: UUID? = nil) {
        guard let entry = outgoing[id] else { return }
        report(entry, to: macID)
    }

    private func report(_ entry: OutgoingRecording, to macID: UUID? = nil) {
        link.sendArrival(LinkRecordingArrival(conversationID: entry.conversationID, recordingID: entry.recordingID, phase: entry.phase),
                         to: macID)
    }

    /// The conversation's own recording a Mac waits for, as its page here says it (`ConversationStatusPresentation.Inputs.unsent`).
    func unsent(_ conversationID: UUID) -> ArrivalStatus? {
        guard let entry = outgoing[conversationID] else { return nil }
        switch entry.phase {
        case .filing: return .filing
        case .storageFull: return .storageFull
        case .waitingForKey: return .waitingForKey
        case .sending: return .sending(nil)
        default: return nil
        }
    }
}
