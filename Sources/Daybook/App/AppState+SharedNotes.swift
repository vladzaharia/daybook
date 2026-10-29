import Combine
import DaybookCore
import DaybookKit
import DaybookLink
import Foundation

/// Notes and bookmarks while this Mac and a phone record one conversation (docs/multipoint.md, "Notes
/// and bookmarks during a shared recording"): a paragraph written in Floating Notes or a bookmark made
/// here appears on the phone at once, and the phone's appear here, over the local link. Each keeps its
/// ID on both devices, so when the libraries sync later the link's copy and the synced copy are one item.
extension AppState {
    /// This Mac started recording `id`: what its notes and bookmarks hold now isn't sent; what changes
    /// from here on is, to every phone recording it too.
    func startSharingNotes(_ id: UUID) {
        guard let meeting = meetings.first(where: { $0.id == id }) else { return }
        sharedNotes.begin(id, notes: NoteTimeline.anchors(meeting.timedNotes, text: meeting.notes), bookmarks: meeting.highlights)
        sharedNotesWatch = library.$meetings
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] meetings in
                guard let self, let id = self.sharedNotes.conversationID, let meeting = meetings.first(where: { $0.id == id }) else { return }
                self.shareNoteChanges(in: meeting)
            }
    }

    /// The recording ended: what changed last goes out, and sharing stops.
    func stopSharingNotes(_ id: UUID) {
        guard sharedNotes.conversationID == id else { return }
        if let meeting = meetings.first(where: { $0.id == id }) { shareNoteChanges(in: meeting) }
        sharedNotesWatch = nil
        sharedNotes.end()
    }

    /// The phones recording this conversation with this Mac that take shared notes.
    func phonesSharingNotes(_ id: UUID) -> [UUID] {
        phoneLink.peers.values.filter { peer in
            peer.capabilities.sharesNotes && (phoneLeads[id]?.sessionID == peer.deviceID.uuidString || isRecording(id, with: peer.deviceID.uuidString))
        }.map(\.deviceID)
    }

    /// Sends what changed in the notes and bookmarks since they were last shared.
    private func shareNoteChanges(in meeting: Meeting) {
        let now = Date()
        let notes = sharedNotes.notesChanged(NoteTimeline.anchors(meeting.timedNotes, text: meeting.notes), at: now)
        let marks = sharedNotes.bookmarksChanged(meeting.highlights, at: now)
        let phones = phonesSharingNotes(meeting.id)
        guard !phones.isEmpty, !(notes.isEmpty && marks.made.isEmpty && marks.changed.isEmpty && marks.deleted.isEmpty) else { return }
        let start = recordingStartedAt ?? now
        var messages: [LinkMessage] = notes.map { note in
            .note(LinkNote(id: note.id, conversationID: meeting.id, text: note.text, time: note.time,
                           madeAt: note.time.map { start.addingTimeInterval($0) } ?? now, deleted: note.deleted, changedAt: now))
        }
        messages += marks.made.map { mark in
            .bookmark(LinkBookmark(id: mark.id, conversationID: meeting.id, recordingTime: mark.time, createdAt: start.addingTimeInterval(mark.time),
                                   label: mark.text.isEmpty ? nil : mark.text))
        }
        messages += marks.changed.map { .bookmarkChange(LinkBookmarkChange(id: $0.id, conversationID: meeting.id, label: $0.text, changedAt: now)) }
        messages += marks.deleted.map { .bookmarkChange(LinkBookmarkChange(id: $0, conversationID: meeting.id, deleted: true, changedAt: now)) }
        let link = phoneLink, previous = sharedNotesSend
        sharedNotesSend = Task {
            await previous?.value
            for phone in phones {
                for message in messages { try? await link.send(message, to: phone) }
            }
        }
    }

    // MARK: From phones

    /// A bookmark on the phone while this Mac records the same conversation, at this Mac's time. It
    /// keeps the phone's ID, so the phone's own copy, arriving with its recording, is the same bookmark.
    func phoneBookmarked(_ mark: LinkBookmark, from phone: UUID) {
        guard recordingID == mark.conversationID, let start = recordingStartedAt else { return }
        let clock = phoneLink.peers[phone]?.clock
        let when = clock?.localDate(fromPeer: mark.createdAt) ?? mark.createdAt
        let time = max(0, when.timeIntervalSince(start))
        _ = sharedNotes.received(bookmark: Highlight(id: mark.id, time: time, text: mark.label ?? ""), at: Date())
        library.addBookmark(id: mark.id, in: mark.conversationID, at: time)
        if let label = mark.label, !label.isEmpty { library.setBookmarkText(mark.id, text: label, in: mark.conversationID) }
    }

    /// A paragraph written, edited, or deleted on the phone: applied by its ID, at the time the phone
    /// files it, so the copy that syncs later is the same paragraph.
    func phoneWroteNote(_ note: LinkNote, from phone: UUID) {
        guard recordingID == note.conversationID, sharedNotes.conversationID == note.conversationID else { return }
        let changed = phoneLink.peers[phone]?.clock?.localDate(fromPeer: note.changedAt) ?? note.changedAt
        let shared = SharedNote(id: note.id, text: note.text, time: note.time, deleted: note.deleted)
        guard sharedNotes.received(shared, changedAt: changed) else { return }
        library.update(note.conversationID) { $0.applySharedNote(shared) }
    }

    /// A bookmark's label changed on the phone, or it was deleted there.
    func phoneChangedBookmark(_ change: LinkBookmarkChange, from phone: UUID) {
        guard recordingID == change.conversationID else { return }
        let changed = phoneLink.peers[phone]?.clock?.localDate(fromPeer: change.changedAt) ?? change.changedAt
        guard sharedNotes.received(bookmarkChange: change.id, label: change.label, deleted: change.deleted, changedAt: changed) else { return }
        library.update(change.conversationID) { $0.applySharedBookmarkChange(id: change.id, label: change.label, deleted: change.deleted) }
    }
}
