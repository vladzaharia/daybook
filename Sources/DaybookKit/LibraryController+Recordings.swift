import DaybookCore
import Foundation

/// Taking a recording out of a conversation, from Info › Audio on both apps: Remove Recording… and Move to New
/// Conversation. A recording dropped on the wrong page, or joined by a wrong match, can come out again. Recordings
/// are originals that sync without ever being deleted, so neither deletes anything: the recording keeps its place in
/// the conversation's folder with a mark on its track (`RecordingRemoval`), its transcript leaves the conversation's
/// at once (`realign`), and Version History says what happened. A removed recording can be put back (Info lists it,
/// and Undo does it); a moved one is in its own conversation, with its transcript, speakers, names, corrections, and
/// bookmarks. `changed` hears of each conversation whose recordings changed (also on undo and redo) with what it
/// needs now (`processing(after:hadSummary:)`), for the app to ask for it where that runs.
extension LibraryController {
    /// What a conversation whose recordings changed needs: a recording not yet transcribed is transcribed; otherwise
    /// its summary is written again from the transcript it has now, only where it had one (`hadSummary`), so a
    /// summary that was stopped, or never written, waits to be asked for. Nil when nothing does.
    nonisolated static func processing(after meeting: Meeting, hadSummary: Bool) -> ProcessingRequest.Mode? {
        guard !meeting.presentTracks.isEmpty else { return nil }
        if meeting.hasUntranscribedAudio { return .newAudio }
        return hadSummary && !meeting.unifiedTranscript.isEmpty ? .summaryOnly : nil
    }

    /// Tells `changed` what the conversation needs now, if anything. `hadSummary` defaults to whether it has one.
    private func recordingsChanged(_ id: UUID, hadSummary: Bool? = nil, _ changed: (@MainActor (UUID, ProcessingRequest.Mode) -> Void)?) {
        guard let changed, let meeting = meeting(id),
              let mode = Self.processing(after: meeting, hadSummary: hadSummary ?? (meeting.summary != nil)) else { return }
        changed(id, mode)
    }

    /// Remove Recording…: takes the recording (with the copies that share its audio) out of the conversation.
    /// Returns whether anything was removed.
    @discardableResult
    public func removeRecording(_ trackID: UUID, from id: UUID, phoneName: String? = nil, undoManager: UndoManager?,
                                at now: Date = Date(), changed: (@MainActor (UUID, ProcessingRequest.Mode) -> Void)? = nil) -> Bool {
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
        Task { await realign(id); recordingsChanged(id, changed) }
        undoManager?.registerUndo(withTarget: self) { controller in
            controller.putBackRecording(trackID, in: id, phoneName: phoneName, undoManager: undoManager, changed: changed)
        }
        undoManager?.setActionName("Remove Recording")
        return true
    }

    /// Puts a removed recording back in its conversation. Returns whether it was put back.
    @discardableResult
    public func putBackRecording(_ trackID: UUID, in id: UUID, phoneName: String? = nil, undoManager: UndoManager?,
                                 at now: Date = Date(), changed: (@MainActor (UUID, ProcessingRequest.Mode) -> Void)? = nil) -> Bool {
        guard let meeting = meeting(id), let track = meeting.tracks.first(where: { $0.id == trackID }), track.isRemoved,
              track.removal?.movedTo == nil else { return false }
        let group = meeting.recordingGroup(of: trackID).map(\.id)
        let words = RecordingWords.inSentence(track, in: meeting, phoneName: phoneName)
        update(id) { meeting in
            for index in meeting.tracks.indices where group.contains(meeting.tracks[index].id) { meeting.tracks[index].removal = nil }
            meeting.revisions.append(MeetingRevision(date: now, field: "source:\(trackID.uuidString):put-back", oldValue: "",
                                                     newValue: "Put back \(words)"))
        }
        Task { await realign(id); recordingsChanged(id, changed) }
        undoManager?.registerUndo(withTarget: self) { controller in
            controller.removeRecording(trackID, from: id, phoneName: phoneName, undoManager: undoManager, changed: changed)
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
                                               undoManager: UndoManager?, at now: Date = Date(),
                                               changed: (@MainActor (UUID, ProcessingRequest.Mode) -> Void)? = nil) async throws -> UUID {
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
            // The voice clips of what moves go with it, at the same paths (LibraryController+VoiceClips).
            try copyVoiceClipFiles(source.voiceClipsCarried(mapping), from: id, to: newID)
        } catch {
            _ = try? await moveToTrash(newID)
            throw error
        }
        // What the conversation holds now (a sync pass may have changed it while the files were read).
        let current = meeting(id) ?? source
        let carried = Self.carried(from: current, group: Set(group.map(\.id)), mapping: mapping)
        // Voiceprints still name the conversation the recording left: its clips are carried from there, on the copy.
        let clips = current.voiceClipsCarried(mapping)
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
                // A compressed recording is still known by its original's bytes (as a merge keeps it), so its voice clip,
                // cut from that original, is still current.
                meeting.tracks[index].encoding = original.encoding
            }
            meeting.transcripts = carried.transcripts
            meeting.speakers = carried.speakers
            meeting.speakerIdentities = carried.identities.isEmpty ? nil : carried.identities
            meeting.highlights = carried.highlights
            meeting.transcriptFlagDismissals = carried.dismissals.isEmpty ? nil : carried.dismissals
            // The passages as they read here, so fusing the new conversation finds the corrections made to them.
            meeting.unifiedTranscript = carried.passages
            // Named by the copy: the person filed it here (`wasMovedHere`), so it's never matched back.
            meeting.revisions = carried.revisions + [MeetingRevision(date: now, field: RecordingRemoval.movedHereField(mapping[trackID] ?? trackID),
                                                                     oldValue: "", newValue: "Moved from “\(source.title)”")]
            meeting.kind = source.kind
            meeting.status = carried.transcripts.isEmpty ? .imported : .ready
            if !clips.isEmpty { meeting.voiceClips = clips.sorted { $0.id < $1.id } }
        }
        let words = RecordingWords.inSentence(track, in: source, phoneName: phoneName)
        var left: [VoiceClip] = []
        update(id) { meeting in
            for index in meeting.tracks.indices where mapping[meeting.tracks[index].id] != nil {
                meeting.tracks[index].removal = RecordingRemoval(removedAt: now, movedTo: newID)
            }
            // Its clips went with it (its file here goes a day later, once the new conversation's is held whole).
            let moved = Set(clips.map(\.id))
            if meeting.voiceClipsAreReadable, let named = meeting.voiceClips {
                let kept = named.filter { clip in clip.unread != nil || !moved.contains(clip.carried(from: meeting.id, to: clip.trackID).id) }
                left = named.filter { clip in !kept.contains(clip) }
                meeting.voiceClips = kept.isEmpty ? nil : kept
            }
            meeting.revisions.append(MeetingRevision(date: now, field: "source:\(trackID.uuidString):moved", oldValue: "",
                                                     newValue: "Moved \(words) to “\(title)”"))
        }
        await realign(newID)
        await realign(id)
        recordingsChanged(id, changed)
        // Its own conversation is summarized where the one it left was.
        recordingsChanged(newID, hadSummary: source.summary != nil, changed)
        undoManager?.registerUndo(withTarget: self) { [left] controller in
            Task {
                await controller.takeBackMove(trackID, from: id, to: newID, clips: left)
                controller.recordingsChanged(id, changed)
            }
        }
        undoManager?.setActionName("Move to New Conversation")
        return newID
    }

    /// Undoes a move: the recording is back where it was with the voice clips that went with it (`clips`, as this
    /// conversation named them), and the conversation made for it goes to the Trash.
    func takeBackMove(_ trackID: UUID, from id: UUID, to newID: UUID, clips: [VoiceClip] = [], at now: Date = Date()) async {
        guard let meeting = meeting(id), let track = meeting.tracks.first(where: { $0.id == trackID }) else { return }
        let group = meeting.recordingGroup(of: trackID).map(\.id)
        let words = RecordingWords.inSentence(track, in: meeting)
        update(id) { meeting in
            for index in meeting.tracks.indices where group.contains(meeting.tracks[index].id) && meeting.tracks[index].removal?.movedTo == newID {
                meeting.tracks[index].removal = nil
            }
            if meeting.voiceClipsAreReadable {
                let named = Set((meeting.voiceClips ?? []).map { $0.source(in: meeting.id).key })
                let back = clips.filter { !named.contains($0.source(in: meeting.id).key) }
                if !back.isEmpty { meeting.voiceClips = ((meeting.voiceClips ?? []) + back).sorted { $0.id < $1.id } }
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
        var dismissals: [TranscriptFlagDismissal] = []
    }

    /// The recording's transcripts (on its new track IDs), the speakers heard in them with who they are, the
    /// conversation's passages drawn from them with the corrections made to those passages, the names the person
    /// gave those speakers, the bookmarks on the recording, and the person's answers to its unsure words.
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
        carried.dismissals = (source.transcriptFlagDismissals ?? []).compactMap { answer in
            guard let copy = mapping[answer.trackID] else { return nil }
            var moved = answer
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
