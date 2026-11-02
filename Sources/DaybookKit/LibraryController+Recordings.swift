import DaybookCore
import Foundation

/// Taking a recording out of a conversation, from Info › Audio on both apps: Remove Recording… and Move to New
/// Conversation. A recording dropped on the wrong page, or joined by a wrong match, can come out again. Recordings
/// are originals that sync without ever being deleted, so neither deletes anything: the recording keeps its place in
/// the conversation's folder with a mark on its track (`RecordingRemoval`), its transcript leaves the conversation's
/// at once (`realign`), and Version History says what happened. A removed recording can be put back (Info lists it,
/// and Undo does it); a moved one is in its own conversation, with its transcript, speakers, names, corrections, and
/// bookmarks. The app summarizes again afterwards, where its summaries run.
extension LibraryController {
    /// Remove Recording…: takes the recording (with the copies that share its audio) out of the conversation.
    /// Returns whether anything was removed.
    @discardableResult
    public func removeRecording(_ trackID: UUID, from id: UUID, phoneName: String? = nil, undoManager: UndoManager?,
                                at now: Date = Date()) -> Bool {
        guard let meeting = meeting(id), let track = meeting.tracks.first(where: { $0.id == trackID }), !track.isRemoved else { return false }
        let group = meeting.recordingGroup(of: trackID).map(\.id)
        let words = RecordingWords.inSentence(track, in: meeting, phoneName: phoneName)
        update(id) { meeting in
            for index in meeting.tracks.indices where group.contains(meeting.tracks[index].id) {
                meeting.tracks[index].removal = RecordingRemoval(removedAt: now)
            }
            meeting.revisions.append(MeetingRevision(date: now, field: "source:\(trackID.uuidString):removed", oldValue: "",
                                                     newValue: "Removed \(words)"))
        }
        Task { await realign(id) }
        undoManager?.registerUndo(withTarget: self) { controller in
            controller.putBackRecording(trackID, in: id, phoneName: phoneName, undoManager: undoManager)
        }
        undoManager?.setActionName("Remove Recording")
        return true
    }

    /// Puts a removed recording back in its conversation. Returns whether it was put back.
    @discardableResult
    public func putBackRecording(_ trackID: UUID, in id: UUID, phoneName: String? = nil, undoManager: UndoManager?,
                                 at now: Date = Date()) -> Bool {
        guard let meeting = meeting(id), let track = meeting.tracks.first(where: { $0.id == trackID }), track.isRemoved,
              track.removal?.movedTo == nil else { return false }
        let group = meeting.recordingGroup(of: trackID).map(\.id)
        let words = RecordingWords.inSentence(track, in: meeting, phoneName: phoneName)
        update(id) { meeting in
            for index in meeting.tracks.indices where group.contains(meeting.tracks[index].id) { meeting.tracks[index].removal = nil }
            meeting.revisions.append(MeetingRevision(date: now, field: "source:\(trackID.uuidString):put-back", oldValue: "",
                                                     newValue: "Put back \(words)"))
        }
        Task { await realign(id) }
        undoManager?.registerUndo(withTarget: self) { controller in
            controller.removeRecording(trackID, from: id, phoneName: phoneName, undoManager: undoManager)
        }
        undoManager?.setActionName("Put Back Recording")
        return true
    }

    /// Move to New Conversation: copies the recording (with the copies that share its audio) into a conversation of
    /// its own, in the same folder and place, with its transcript (so it isn't transcribed again), the speakers heard
    /// in it with their names, the corrections made to its passages, and the bookmarks on it; then takes it out of
    /// this one. `audio` finds each recording's file (on the iPhone it may download it). Returns the new
    /// conversation's ID. Undo puts the recording back and moves the new conversation to the Trash.
    public func moveRecordingToNewConversation(_ trackID: UUID, from id: UUID, phoneName: String? = nil,
                                               audio: (RecordingTrack) async throws -> URL,
                                               undoManager: UndoManager?, at now: Date = Date()) async throws -> UUID {
        guard let source = meeting(id), let track = source.tracks.first(where: { $0.id == trackID }), !track.isRemoved else {
            throw DaybookError.libraryUnavailable
        }
        let group = source.recordingGroup(of: trackID)
        // Every file first: nothing changes until the audio is here.
        var files: [(track: RecordingTrack, url: URL)] = []
        for member in group { files.append((member, try await audio(member))) }

        let title = RecordingWords.conversationTitle(group.first ?? track, phoneName: phoneName)
        let newID = newMeeting(title: title, date: (group.first ?? track).startedAt ?? (group.first ?? track).createdAt,
                               folderID: source.folderID, placement: source.placement)
        var mapping: [UUID: UUID] = [:]
        do {
            await acquireLock()
            defer { releaseLock() }
            for file in files {
                let ingested = try await ingest(file.url, into: newID, provenance: .file(source: file.track.source, device: file.track.device,
                                                                                         duration: file.track.duration))
                guard let copy = ingested.track else { throw DaybookError.libraryUnavailable }
                mapping[file.track.id] = copy.id
            }
        } catch {
            _ = try? await moveToTrash(newID)
            throw error
        }
        let carried = Self.carried(from: source, group: Set(group.map(\.id)), mapping: mapping)
        update(newID) { meeting in
            for original in group {
                guard let copyID = mapping[original.id], let index = meeting.tracks.firstIndex(where: { $0.id == copyID }) else { continue }
                // The copy is the same recording: what made it, when, how it was captured, and what it was made from.
                meeting.tracks[index].source = original.source
                meeting.tracks[index].device = original.device
                meeting.tracks[index].createdAt = original.createdAt
                meeting.tracks[index].startedAt = original.startedAt
                meeting.tracks[index].duration = original.duration ?? meeting.tracks[index].duration
                meeting.tracks[index].capture = original.capture
                meeting.tracks[index].backgroundAudio = original.backgroundAudio
                meeting.tracks[index].derivedFrom = original.derivedFrom.flatMap { mapping[$0] }
                meeting.tracks[index].processing = original.processing
                meeting.tracks[index].offset = original.derivedFrom == nil ? 0 : nil
            }
            meeting.transcripts = carried.transcripts
            meeting.speakers = carried.speakers
            meeting.speakerIdentities = carried.identities.isEmpty ? nil : carried.identities
            meeting.highlights = carried.highlights
            // The passages as they read here, so fusing the new conversation finds the corrections made to them.
            meeting.unifiedTranscript = carried.passages
            meeting.revisions = carried.revisions + [MeetingRevision(date: now, field: "source:\(trackID.uuidString):moved-from", oldValue: "",
                                                                     newValue: "Moved from “\(source.title)”")]
            meeting.kind = source.kind
            meeting.status = carried.transcripts.isEmpty ? .imported : .ready
        }
        let words = RecordingWords.inSentence(track, in: source, phoneName: phoneName)
        update(id) { meeting in
            for index in meeting.tracks.indices where mapping[meeting.tracks[index].id] != nil {
                meeting.tracks[index].removal = RecordingRemoval(removedAt: now, movedTo: newID)
            }
            meeting.revisions.append(MeetingRevision(date: now, field: "source:\(trackID.uuidString):moved", oldValue: "",
                                                     newValue: "Moved \(words) to “\(title)”"))
        }
        await realign(newID)
        await realign(id)
        undoManager?.registerUndo(withTarget: self) { controller in
            Task { await controller.takeBackMove(trackID, from: id, to: newID) }
        }
        undoManager?.setActionName("Move to New Conversation")
        return newID
    }

    /// Undoes a move: the recording is back where it was, and the conversation made for it goes to the Trash.
    func takeBackMove(_ trackID: UUID, from id: UUID, to newID: UUID, at now: Date = Date()) async {
        guard let meeting = meeting(id), let track = meeting.tracks.first(where: { $0.id == trackID }) else { return }
        let group = meeting.recordingGroup(of: trackID).map(\.id)
        let words = RecordingWords.inSentence(track, in: meeting)
        update(id) { meeting in
            for index in meeting.tracks.indices where group.contains(meeting.tracks[index].id) && meeting.tracks[index].removal?.movedTo == newID {
                meeting.tracks[index].removal = nil
            }
            meeting.revisions.append(MeetingRevision(date: now, field: "source:\(trackID.uuidString):put-back", oldValue: "",
                                                     newValue: "Put back \(words)"))
        }
        await realign(id)
        _ = try? await moveToTrash(newID)
    }

    /// What goes with a recording into a conversation of its own.
    struct Carried {
        var transcripts: [TrackTranscript] = []
        var speakers: [Speaker] = []
        var identities: [SpeakerIdentity] = []
        var highlights: [Highlight] = []
        var passages: [TranscriptSegment] = []
        var revisions: [MeetingRevision] = []
    }

    /// The recording's transcripts (on its new track IDs), the speakers heard in them with who they are, the
    /// conversation's passages drawn from them with the corrections made to those passages, the names the person
    /// gave those speakers, and the bookmarks on the recording.
    nonisolated static func carried(from source: Meeting, group: Set<UUID>, mapping: [UUID: UUID]) -> Carried {
        var carried = Carried()
        carried.transcripts = source.transcripts.filter { group.contains($0.trackID) }.map { run in
            var copy = run
            copy.trackID = mapping[run.trackID] ?? run.trackID
            copy.segments = run.segments.map { segment in
                var moved = segment
                moved.trackID = mapping[segment.trackID] ?? segment.trackID
                return moved
            }
            return copy
        }
        let heard = Set(carried.transcripts.flatMap(\.segments).compactMap(\.speakerID))
        carried.speakers = source.speakers.filter { heard.contains($0.id) || $0.sourceTrackID.map(group.contains) == true }.map { speaker in
            var copy = speaker
            copy.sourceTrackID = speaker.sourceTrackID.flatMap { mapping[$0] }
            return copy
        }
        let speakerIDs = Set(carried.speakers.map(\.id))
        carried.identities = (source.speakerIdentities ?? []).filter { speakerIDs.contains($0.speakerID) }
        carried.highlights = source.highlights.compactMap { mark in
            guard let track = mark.trackID, let copy = mapping[track] else { return nil }
            var moved = mark
            moved.trackID = copy
            return moved
        }
        let raw = Set(source.transcripts.filter { group.contains($0.trackID) }.flatMap(\.segments).map(\.id))
        carried.passages = source.unifiedTranscript.filter { passage in
            raw.contains(passage.id) || passage.provenance.contains { raw.contains($0.segmentID) }
        }.map { passage in
            var moved = passage
            moved.trackID = mapping[passage.trackID] ?? passage.trackID
            moved.provenance = passage.provenance.filter { raw.contains($0.segmentID) }.map { cited in
                var copy = cited
                copy.trackID = mapping[cited.trackID] ?? cited.trackID
                return copy
            }
            return moved
        }
        let passageIDs = Set(carried.passages.map { $0.id.uuidString })
        carried.revisions = source.revisions.filter { revision in
            let parts = revision.field.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return false }
            switch parts[0] {
            case "speaker": return speakerIDs.contains(parts[1])
            case "segment": return passageIDs.contains(parts[1])
            default: return false
            }
        }
        return carried
    }
}
