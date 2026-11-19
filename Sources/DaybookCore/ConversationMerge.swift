import Foundation

/// Merge (docs/architecture.md, "Merging conversations"): two or more conversations the person selected become one,
/// processed again as a whole. The earliest by date survives with its ID, title, folder, and history; each other one
/// folds into it in order of date (`fold`) with what it holds: its recordings (their audio copied in by the caller,
/// `LibraryController.mergeConversations`, and marked `RecordingTrack.mergedFrom`), their transcript runs (each run's
/// words too, to compare with the transcript the merged conversation gets), its speakers and who they are, the
/// corrections and names the person gave, bookmarks, photos, notes and their handwriting, and tags. Then the others go
/// to the Trash. A merge is the one change to the library that isn't undone.
///
/// Each folded conversation's timeline lands on the merged one (`placements`):
/// - recorded alongside the survivor (their recordings overlap by the clock, as much as a recording that finds its
///   conversation by time does, `SourceMatcher.Policy`), its recordings wait to be lined up from their sound, from where
///   the clocks put them, as a recording added to a conversation does;
/// - recorded at another time, it starts where what's before it ends, placed as by hand (Adjust Timing), its recordings
///   keeping their places among themselves. Recordings made at different times are never compared by sound;
/// - recorded alongside one of those, its recordings wait by the clocks for the phrases they share, then the clocks
///   alone. Not the sound: what it would be compared with is the survivor's recording, made at another time.
public enum ConversationMerge {
    /// Where a folded conversation's timeline goes on the merged one.
    public struct Placement: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// Recorded alongside the survivor: its recordings wait for the sound, from the clocks.
            case alongside
            /// Recorded alongside a conversation folded in before it that followed the survivor: its recordings wait for
            /// shared phrases, then the clocks, never the sound.
            case alongsideLater
            /// Recorded at another time: right after what's before it, placed as by hand.
            case after
        }
        public var kind: Kind
        /// Seconds from the merged timeline's zero to the folded conversation's own.
        public var shift: TimeInterval
        /// The stretch its own recordings are on in the merged conversation (`RecordingTrack.stretch`): nil, the survivor's
        /// own; the conversation an earlier merge placed after it, recorded alongside that; or its own ID, placed after.
        public var stretch: UUID?
        public init(kind: Kind, shift: TimeInterval, stretch: UUID? = nil) { self.kind = kind; self.shift = shift; self.stretch = stretch }
    }

    /// The conversations in the order they merge: the survivor (the earliest by date) first, then the rest by date.
    public static func ordered(_ meetings: [Meeting]) -> [Meeting] {
        meetings.sorted { $0.date != $1.date ? $0.date < $1.date : $0.id.uuidString < $1.id.uuidString }
    }

    /// The Version History entry a folded conversation leaves in the survivor ("Merged “Weekly sync”"). A merge asked for
    /// again after one that stopped partway finds it, and only finishes moving that conversation to the Trash.
    public static func revisionField(_ foldedID: UUID) -> RevisionField { .source("merged:\(foldedID.uuidString)") }

    /// The ID of the copy a merge makes of a folded conversation's recording in the survivor, the same on every device that
    /// merges them, so two devices (or a retry before sync) make one copy, not two (`MeetingMerge` unions tracks by ID).
    public static func copyID(of trackID: UUID, folded foldedID: UUID, into survivorID: UUID) -> UUID {
        SyncEncoding.uuid("merge-copy:\(survivorID.uuidString):\(foldedID.uuidString):\(trackID.uuidString)")
    }

    /// Whether `foldedID` is folded into `meeting` already.
    public static func hasFolded(_ foldedID: UUID, into meeting: Meeting) -> Bool {
        let field = revisionField(foldedID).rawValue
        return meeting.revisions.contains { $0.field == field }
    }

    /// A stretch of the wall clock a conversation's recordings cover, on the timeline they share: when it was, and when the
    /// timeline's zero was by that clock (a recording placed there starts at its own start less this).
    struct Stretch {
        /// Its recordings' `RecordingTrack.stretch`: nil for the conversation's own.
        var key: UUID?
        var span: DateInterval
        var zero: Date
        /// The conversation's own, with the recordings made alongside it, not a stretch an earlier merge put after it.
        var isOwn: Bool { key == nil }
    }

    /// The stretches a conversation's recordings cover: its own and what was made alongside it as one, and each
    /// conversation an earlier merge placed after it, with what was recorded alongside that, as another (by each
    /// recording's `RecordingTrack.stretch`, never by its timing), each from its recordings' own starts (`startOf`), never
    /// from where they sit on the timeline: the timeline's span isn't the wall clock's.
    static func stretches(of meeting: Meeting, startOf: (RecordingTrack) -> Date?) -> [Stretch] {
        let present = meeting.tracks.filter { !$0.isRemoved }
        var result: [Stretch] = []
        let keys: [UUID?] = [nil] + Set(present.compactMap(\.stretch)).sorted { $0.uuidString < $1.uuidString }
        for key in keys {
            let group = present.filter { $0.stretch == key }
            func place(_ track: RecordingTrack) -> TimeInterval? {
                meeting.clock(of: track.id)?.offset ?? track.alignment?.clockOffset
            }
            let ordered = group.filter { $0.source == .microphone || $0.source == .systemAudio } + group.filter { $0.source != .microphone && $0.source != .systemAudio }
            var known: Date?
            for track in ordered where known == nil {
                if let begin = startOf(track), let offset = place(track) { known = begin.addingTimeInterval(-offset) }
            }
            guard let zero = known else { continue }
            var lower: Date?, upper: Date?
            for track in group {
                guard let begin = startOf(track) ?? place(track).map({ zero.addingTimeInterval($0) }) else { continue }
                let end = begin.addingTimeInterval(max(0, recordedLength(of: track, in: meeting)))
                lower = min(lower ?? begin, begin); upper = max(upper ?? end, end)
            }
            guard let lower, let upper else { continue }
            result.append(Stretch(key: key, span: DateInterval(start: lower, end: upper), zero: zero))
        }
        return result
    }

    /// Where each conversation after the survivor goes, by ID. `startOf` says when a recording started by the wall clock
    /// (the Mac knows more than `startedAt`); a conversation with no recording whose start is known follows what's
    /// before it. A conversation that holds a merge is told apart by stretch: one recorded alongside what an earlier merge
    /// put after the survivor goes alongside that, and one recorded at a time none covers goes after everything.
    public static func placements(_ meetings: [Meeting], policy: SourceMatcher.Policy = .init(),
                                  startOf: (RecordingTrack) -> Date? = { $0.startedAt }) -> [UUID: Placement] {
        let ordered = ordered(meetings)
        guard let survivor = ordered.first else { return [:] }
        // The stretches of the wall clock already on the merged timeline, and whether the survivor's own.
        var stretches = Self.stretches(of: survivor, startOf: startOf)
        var end = timelineEnd(of: survivor, shift: 0) ?? 0
        var result: [UUID: Placement] = [:]
        for folded in ordered.dropFirst() {
            let own = Self.stretches(of: folded, startOf: startOf)
            let primary = own.first { $0.isOwn }
            var best: (index: Int, overlap: TimeInterval)?
            if let primary {
                for index in stretches.indices {
                    guard let overlap = sharedTime(stretches[index].span, primary.span, policy: policy), overlap > best?.overlap ?? 0 else { continue }
                    best = (index, overlap)
                }
            }
            let placement: Placement
            if let best, let primary {
                let stretch = stretches[best.index]
                placement = Placement(kind: stretch.isOwn ? .alongside : .alongsideLater, shift: primary.zero.timeIntervalSince(stretch.zero),
                                      stretch: stretch.key)
                stretches[best.index].span = DateInterval(start: min(stretch.span.start, primary.span.start), end: max(stretch.span.end, primary.span.end))
                for other in own where !other.isOwn {
                    stretches.append(Stretch(key: other.key, span: other.span, zero: other.zero.addingTimeInterval(-placement.shift)))
                }
            } else {
                // Its earliest recording (one that began before its timeline's zero too) starts where what's before it ends.
                let earliest = folded.tracks.filter { !$0.isMovedOut }.compactMap { folded.clock(of: $0.id)?.offset }.min() ?? 0
                placement = Placement(kind: .after, shift: end - min(0, earliest), stretch: folded.id)
                for stretch in own {
                    stretches.append(Stretch(key: stretch.key ?? folded.id, span: stretch.span, zero: stretch.zero.addingTimeInterval(-placement.shift)))
                }
            }
            result[folded.id] = placement
            if let folds = timelineEnd(of: folded, shift: placement.shift) { end = max(end, folds) }
        }
        return result
    }

    /// Where a conversation's recordings end on the merged timeline with its own zero at `shift`; nil without one placed
    /// or waiting with the clocks' estimate.
    static func timelineEnd(of meeting: Meeting, shift: TimeInterval) -> TimeInterval? {
        meeting.tracks.filter { !$0.isMovedOut }.compactMap { track -> TimeInterval? in
            let clock = meeting.clock(of: track.id)
            guard let start = clock?.offset ?? track.alignment?.clockOffset, start.isFinite else { return nil }
            return shift + start + (clock?.rate ?? 1) * recordedLength(of: track, in: meeting)
        }.max()
    }

    /// How long a recording is: as measured, else as far as its transcripts heard.
    static func recordedLength(of track: RecordingTrack, in meeting: Meeting) -> TimeInterval {
        if let duration = track.duration, duration.isFinite, duration > 0 { return duration }
        let heard = meeting.transcripts.filter { $0.trackID == track.id }
            .flatMap { $0.segments.map(\.end) + ($0.words ?? []).map(\.end) }.filter(\.isFinite)
        return heard.max() ?? 0
    }

    /// How long two stretches of the wall clock overlap, when it's as much as a recording that joins a conversation by
    /// time shares with it.
    private static func sharedTime(_ a: DateInterval, _ b: DateInterval, policy: SourceMatcher.Policy) -> TimeInterval? {
        let overlap = min(a.end, b.end).timeIntervalSince(max(a.start, b.start))
        let shorter = max(1, min(a.duration, b.duration))
        guard overlap > 0, overlap >= min(policy.minimumOverlap, shorter), overlap / shorter >= policy.minimumShare else { return nil }
        return overlap
    }

    // MARK: Folding

    /// Folds `folded` into `merged` (the survivor, with what was folded into it so far) at `placement`. Its recordings
    /// are in `merged` already as `copies` maps them (the caller copied their audio in); `fresh` are the copies this merge
    /// made, which take the recording's details and its place on the merged timeline, while a copy that was there
    /// before (the same audio was in both) keeps its own. A recording moved out of `folded` before is in the conversation
    /// it moved to, and isn't carried. `photos` are its photos as stored in `merged`'s folder, by ID, and `pageFiles` the IDs of its pages whose drawing
    /// files are copied there (paths stay the same: page IDs are global; a page without them isn't carried). `profiles` says
    /// which voice profile a merged profile stands for. `restoring` are copies that were this conversation's moved out of
    /// `merged` (Move to New Conversation) and are back with it: they're put back, as Info puts one back, with the words
    /// Version History says it in. Everything it makes is the same whichever device folds it (IDs and dates come from
    /// the conversations, `now` only dates the Version History entries), so two devices that merge the same conversations
    /// end with one result. Does nothing when it's folded in already.
    public static func fold(_ folded: Meeting, into merged: inout Meeting, placement: Placement, copies: [UUID: UUID],
                            fresh: Set<UUID>, restoring: [UUID: String] = [:], photos: [UUID: MeetingPhoto] = [:],
                            pageFiles: Set<UUID> = [], profiles: SpeakerProfileMerges? = nil, at now: Date = Date()) {
        guard !hasFolded(folded.id, into: merged) else { return }
        let shift = placement.shift
        var putBack: [MeetingRevision] = []
        for (trackID, words) in restoring.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard let index = merged.tracks.firstIndex(where: { $0.id == trackID }), merged.tracks[index].removal?.movedTo == folded.id else { continue }
            merged.tracks[index].removal = nil
            putBack.append(MeetingRevision(id: SyncEncoding.uuid("merge-put-back:\(merged.id.uuidString):\(folded.id.uuidString):\(trackID.uuidString)"),
                                           date: now, field: "source:\(trackID.uuidString):put-back", oldValue: "", newValue: "Put back \(words)"))
        }
        let carried = folded.tracks.filter { !$0.isMovedOut && copies[$0.id] != nil }
        func copy(_ id: UUID) -> UUID? { copies[id] }

        // Notes, bookmarks, and photos timed by the folded conversation's own clock. Waiting to be lined up, they're held
        // by its lead recording and follow it to where the sound puts it; placed after, they move with the timeline.
        let lead = placement.kind == .after ? nil : leadRecording(of: folded, among: carried)
        let leadCopy = lead.flatMap { copy($0.track.id) }
        func onLead(_ time: TimeInterval) -> (trackID: UUID, time: TimeInterval)? {
            guard let lead, let leadCopy, lead.clock.rate > 0 else { return nil }
            let local = (time - lead.clock.offset) / lead.clock.rate
            return local.isFinite && local >= 0 ? (leadCopy, local) : nil
        }
        let foldedAnchors = folded.timedNotes == nil && folded.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? [] : settled(NoteTimeline.anchors(folded.timedNotes, text: folded.notes), saved: folded.timedNotes, owner: folded.id)
        let heldByRecordings = Set(folded.tracks.flatMap { $0.alignment?.heldNoteIDs ?? [] })
        let heldByLead = lead == nil ? [] : foldedAnchors.filter { $0.time != nil && !heldByRecordings.contains($0.id) }.map(\.id)

        // Recordings: details from the original, and a place on the merged timeline.
        let clockID = SyncEncoding.uuid("merge:\(folded.id.uuidString)")
        for track in carried {
            guard let copyID = copy(track.id), fresh.contains(copyID), let index = merged.tracks.firstIndex(where: { $0.id == copyID }) else { continue }
            var moved = track
            moved.id = copyID
            moved.relativePath = merged.tracks[index].relativePath
            moved.sha256 = merged.tracks[index].sha256
            moved.duration = track.duration ?? merged.tracks[index].duration
            moved.derivedFrom = track.derivedFrom.flatMap(copy)
            moved.removal = track.removal.map { RecordingRemoval(removedAt: $0.removedAt) }
            moved.mergedFrom = track.mergedFrom ?? folded.id
            // On a stretch of its own already (an earlier merge put it after the rest of the conversation it comes from), it
            // stays on it; otherwise it joins the stretch its conversation joins.
            moved.stretch = track.stretch ?? placement.stretch
            let own = folded.clock(of: track.id)
            // Placed after the rest, or already after the rest of the conversation it comes from (an earlier merge): at another
            // time than what it's compared with, so its place is kept, never taken from the sound.
            if let own, placement.kind == .after || track.stretch != nil {
                moved.alignment = SourceAlignment(method: .manual, offset: shift + own.offset, rate: own.rate, date: folded.date)
                moved.offset = shift + own.offset
            } else {
                let isLead = lead?.track.id == track.id
                let held = (track.alignment?.heldNoteIDs ?? []) + (isLead ? heldByLead : [])
                let capture = isLead ? lead.map { shift + $0.clock.offset } : track.alignment?.captureOffset.map { shift + $0 }
                moved.alignment = SourceAlignment(method: .pending, clockOffset: own.map { shift + $0.offset } ?? track.alignment?.clockOffset.map { shift + $0 },
                                                  clockID: clockID, audioChecked: placement.kind == .alongside ? nil : true,
                                                  heldNoteIDs: held.isEmpty ? nil : held, captureOffset: held.isEmpty ? nil : capture, date: folded.date)
                moved.offset = nil
            }
            merged.tracks[index] = moved
        }

        // Speakers: one person is one speaker, whichever conversation named them.
        let speakerMap = speakerIDs(of: folded, into: merged, profiles: profiles)
        let before = Dictionary(merged.speakers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let unified = Set(folded.speakers.filter { speaker in before[speakerMap[speaker.id] ?? speaker.id] != nil }.map(\.id))
        func speaker(_ id: String?) -> String? { id.map { speakerMap[$0] ?? $0 } }
        // What history says of a speaker folded into one already here stays only where it still reads true of that one:
        // the same name. Otherwise it's kept under an ID no speaker has.
        func historyID(_ id: String) -> String {
            guard let own = folded.speakers.first(where: { $0.id == id }) else { return "\(folded.id.uuidString):\(id)" }
            guard unified.contains(id) else { return speakerMap[id] ?? id }
            let target = speakerMap[id] ?? id
            return personName(own) != nil && personName(own) == before[target].flatMap(personName) ? target : "\(folded.id.uuidString):\(id)"
        }

        // Transcript runs, each on its recording's copy: every run is kept, the latest is the one fused.
        let knownRuns = Set(merged.transcripts.map(\.id))
        var runs: [TrackTranscript] = []
        for run in folded.transcripts where !knownRuns.contains(run.id) {
            guard let trackID = copy(run.trackID) else { continue }
            var moved = run
            moved.trackID = trackID
            moved.segments = run.segments.map { segment in
                var copied = segment
                copied.trackID = copy(segment.trackID) ?? trackID
                copied.speakerID = speaker(segment.speakerID)
                copied.provenance = segment.provenance.map { cited in
                    var copied = cited
                    copied.trackID = copy(cited.trackID) ?? cited.trackID
                    return copied
                }
                return copied
            }
            let placed = merged.tracks.first { $0.id == trackID }?.alignment
            moved.knownOffset = fresh.contains(trackID) ? (placed?.isPlaced == true ? placed?.offset : nil)
                : merged.transcripts.last { $0.trackID == trackID }?.knownOffset ?? run.knownOffset
            runs.append(moved)
        }
        merged.transcripts += runs

        // The conversation's passages as they read there, corrections and all, on the merged timeline, so fusing the
        // merged conversation (and transcribing it again) carries the corrections over (`CorrectionTransfer`).
        func moved(_ passage: TranscriptSegment, shifting: Bool) -> TranscriptSegment {
            var copied = passage
            copied.trackID = copy(passage.trackID) ?? passage.trackID
            if shifting { copied.start += shift; copied.end += shift }
            copied.speakerID = speaker(passage.speakerID)
            copied.provenance = passage.provenance.map { cited in
                var copied = cited
                copied.trackID = copy(cited.trackID) ?? cited.trackID
                return copied
            }
            return copied
        }
        let knownPassages = Set(merged.unifiedTranscript.map(\.id))
        let passages = folded.unifiedTranscript.filter { !knownPassages.contains($0.id) }.map { moved($0, shifting: true) }
        if !passages.isEmpty {
            merged.unifiedTranscript = (merged.unifiedTranscript + passages)
                .sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
        }
        let knownIssues = Set((merged.correctionTransferIssues ?? []).map(\.id))
        let issues = (folded.correctionTransferIssues ?? []).filter { !knownIssues.contains($0.id) }.map { issue in
            var copied = issue
            copied.originalSegment = moved(issue.originalSegment, shifting: true)
            return copied
        }
        if !issues.isEmpty { merged.correctionTransferIssues = (merged.correctionTransferIssues ?? []) + issues }

        // The speakers heard in what came, or recorded on its recordings, with who they are.
        let heard = Set(runs.flatMap(\.segments).compactMap(\.speakerID) + passages.compactMap(\.speakerID))
        for original in folded.speakers {
            let target = speakerMap[original.id] ?? original.id
            guard heard.contains(target) || original.sourceTrackID.flatMap(copy) != nil else { continue }
            if let existing = merged.speakers.firstIndex(where: { $0.id == target }) {
                // The same person: the name here stands. A voice it lacks comes along, so the person is recognized in
                // the recordings that came too when they're transcribed again.
                if merged.speakers[existing].embedding == nil, original.embedding != nil {
                    merged.speakers[existing].embedding = original.embedding
                    merged.speakers[existing].embeddingModelID = original.embeddingModelID
                    merged.speakers[existing].analysisSettings = original.analysisSettings
                }
                continue
            }
            var copied = original
            copied.id = target
            copied.sourceTrackID = original.sourceTrackID.flatMap(copy)
            // A number Daybook gave goes on from the speakers here ("Speaker 4"), so two aren't called the same.
            if SpeakerProfile.isPlaceholder(original.name), !folded.renamedSpeakerIDs.contains(original.id) {
                var number = merged.speakers.count + 1
                while merged.speakers.contains(where: { $0.name == "Speaker \(number)" }) { number += 1 }
                copied.name = "Speaker \(number)"
            }
            merged.speakers.append(copied)
        }
        let carriedSpeakers = Set(merged.speakers.map(\.id))
        for identity in folded.speakerIdentities ?? [] {
            let target = historyID(identity.speakerID)
            guard carriedSpeakers.contains(target), merged.speakerIdentity(target) == nil else { continue }
            var copied = identity
            copied.speakerID = target
            merged.setSpeakerIdentity(copied, for: target)
        }
        let knownMatches = Set((merged.speakerMatches ?? []).map(\.id))
        let matches = (folded.speakerMatches ?? []).compactMap { match -> SpeakerMatch? in
            var copied = match
            copied.sourceSpeakerID = speaker(match.sourceSpeakerID) ?? match.sourceSpeakerID
            copied.targetSpeakerID = speaker(match.targetSpeakerID)
            copied.candidateSpeakerID = speaker(match.candidateSpeakerID)
            return knownMatches.contains(copied.id) || copied.targetSpeakerID == copied.sourceSpeakerID ? nil : copied
        }
        if !matches.isEmpty { merged.speakerMatches = (merged.speakerMatches ?? []) + matches }

        // Bookmarks: on a recording, on its copy; on the conversation's own clock, moved as the timeline is.
        func movedBookmark(_ mark: Highlight) -> Highlight? {
            var copied = mark
            if let track = mark.trackID {
                // On a recording moved out before: it went with that recording.
                guard let trackID = copy(track) else { return nil }
                copied.trackID = trackID
            } else if let held = onLead(mark.time) {
                copied.trackID = held.trackID
                copied.time = held.time
            } else {
                // Before the merged timeline's zero a bookmark has no time to keep (the library refuses a negative one), so
                // it sits at zero; a note keeps its negative time, and a photo goes by when it was taken.
                copied.time = max(0, mark.time + shift)
            }
            return copied
        }
        let knownMarks = Set(merged.highlights.map(\.id))
        merged.highlights += folded.highlights.filter { !knownMarks.contains($0.id) }.compactMap(movedBookmark)

        // Answers to unsure words, each on its recording's copy. An answer is about words at a time in its recording, so
        // it still answers them when the merged conversation is transcribed again (`TranscriptFlags.answered`).
        let knownAnswers = Set((merged.transcriptFlagDismissals ?? []).map(\.id))
        let answers = (folded.transcriptFlagDismissals ?? []).filter { !knownAnswers.contains($0.id) }.compactMap { answer -> TranscriptFlagDismissal? in
            guard let trackID = copy(answer.trackID) else { return nil }
            var moved = answer
            moved.trackID = trackID
            return moved
        }
        if !answers.isEmpty { merged.transcriptFlagDismissals = (merged.transcriptFlagDismissals ?? []) + answers }

        // Photos, each as stored in the merged conversation's folder.
        let knownPhotos = Set((merged.photos ?? []).map(\.id))
        let carriedPhotos = (folded.photos ?? []).compactMap { photo -> MeetingPhoto? in
            guard let stored = photos[photo.id], stored.id == photo.id, !knownPhotos.contains(photo.id) else { return nil }
            var copied = photo
            copied.relativePath = stored.relativePath
            if let track = photo.trackID {
                copied.trackID = copy(track)
                if copied.trackID == nil { copied.time = nil }
            } else if let time = photo.time {
                if let held = onLead(time) { copied.trackID = held.trackID; copied.time = held.time } else { copied.time = time + shift >= 0 ? time + shift : nil }
            }
            return copied
        }
        if !carriedPhotos.isEmpty { merged.photos = (merged.photos ?? []) + carriedPhotos }

        // Notes after the survivor's, a blank line between, each paragraph keeping its anchor (and its handwriting) and its
        // time on the merged timeline.
        if !foldedAnchors.isEmpty || !folded.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let anchors = merged.timedNotes != nil || folded.timedNotes != nil
                ? settled(NoteTimeline.anchors(merged.timedNotes, text: merged.notes), saved: merged.timedNotes, owner: merged.id) + foldedAnchors.map { note in
                    TimedNote(id: note.id, time: note.time.map { $0 + shift }, text: note.text)
                } : nil
            var text = merged.notes
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = "" } else {
                while text.hasSuffix("\n") { text.removeLast() }
                text += "\n\n"
            }
            merged.notes = text + folded.notes
            merged.timedNotes = anchors
        }
        // Pages after the survivor's, each with its drawing files in the merged conversation's folder; what was read from a
        // page follows the timeline as photos do.
        let knownPages = Set((merged.pages ?? []).map(\.id))
        let firstOrder = merged.nextPageOrder
        let carriedPages = (folded.pages ?? []).filter { !knownPages.contains($0.id) && pageFiles.contains($0.id) }
            .sorted(by: NotebookPage.precedes).enumerated().map { position, page -> NotebookPage in
                var copied = page
                copied.order = firstOrder + Double(position)
                for index in copied.reading?.passages.indices ?? 0..<0 {
                    guard var passage = copied.reading?.passages[index] else { continue }
                    if let track = passage.trackID {
                        passage.trackID = copy(track)
                        if passage.trackID == nil { passage.time = nil }
                    } else if let time = passage.time {
                        if let held = onLead(time) { passage.trackID = held.trackID; passage.time = held.time } else { passage.time = time + shift >= 0 ? time + shift : nil }
                    }
                    copied.reading?.passages[index] = passage
                }
                return copied
            }
        if !carriedPages.isEmpty { merged.pages = (merged.pages ?? []) + carriedPages }
        let knownInk = Set((merged.ink ?? []).map(\.id))
        let ink = (folded.ink ?? []).filter { !knownInk.contains($0.id) }
        if !ink.isEmpty { merged.ink = (merged.ink ?? []) + ink }

        var tags = merged.tags ?? []
        for tag in folded.tags ?? [] where !tags.contains(where: { $0.lowercased() == tag.lowercased() }) { tags.append(tag) }
        if tags != (merged.tags ?? []) { merged.tags = tags }
        merged.includesBackgroundAudio = merged.includesBackgroundAudio ?? folded.includesBackgroundAudio

        // Sound alignments measured between its recordings still hold between their copies.
        let knownAlignments = Set((merged.audioAlignments ?? []).map(\.id))
        let alignments = (folded.audioAlignments ?? []).compactMap { record -> TrackAudioAlignment? in
            guard let trackID = copy(record.trackID), let referenceID = copy(record.referenceTrackID) else { return nil }
            var copied = record
            copied.trackID = trackID; copied.referenceTrackID = referenceID
            return knownAlignments.contains(copied.id) ? nil : copied
        }
        if !alignments.isEmpty { merged.audioAlignments = (merged.audioAlignments ?? []) + alignments }
        // Recorders asked to record alongside it, when it was recorded alongside the survivor: by the wall clock, a
        // recording of theirs that still arrives belongs on the merged timeline as theirs do. Recorded at another time,
        // the merged timeline isn't its wall clock, so they stay with it in the Trash.
        if placement.kind != .after {
            let knownLinks = Set((merged.companions ?? []).map(\.id))
            let links = (folded.companions ?? []).filter { !knownLinks.contains($0.id) }.map { link in
                var copied = link
                copied.trackID = link.trackID.flatMap(copy)
                return copied
            }
            if !links.isEmpty { merged.companions = (merged.companions ?? []) + links }
        }
        // A suggestion that a recording here belongs with the folded conversation is answered.
        if var suggestions = merged.sourceSuggestions {
            for index in suggestions.indices { suggestions[index].candidateMeetingIDs.removeAll { $0 == folded.id } }
            suggestions.removeAll { $0.candidateMeetingIDs.isEmpty }
            merged.sourceSuggestions = suggestions.isEmpty ? nil : suggestions
        }

        // Version History: the names and corrections the person gave there, and what was done to its bookmarks, photos, and pages,
        // on what they're about here; then the merge itself.
        let knownRevisions = Set(merged.revisions.map(\.id))
        let carriedPhotoIDs = Set(carriedPhotos.map(\.id))
        let carriedPageIDs = Set(carriedPages.map(\.id))
        let carriedPassageIDs = Set(carriedPages.flatMap { page in page.passages.map(\.id) + (page.corrections ?? []).map(\.passageID) })
        let revisions = folded.revisions.filter { !knownRevisions.contains($0.id) }.compactMap { revision -> MeetingRevision? in
            var copied = revision
            switch revision.kind {
            case .speaker(let id): copied.kind = .speaker(historyID(id))
            case .segment, .correctionTransfer: break
            case .photo(let id), .photoCaption(let id): guard carriedPhotoIDs.contains(id) else { return nil }
            case .page(let id): guard carriedPageIDs.contains(id) else { return nil }
            case .passage(let id): guard carriedPassageIDs.contains(id) else { return nil }
            case .bookmark:
                func movedValue(_ value: String) -> String? {
                    guard value != MeetingRevision.bookmarkRemoved else { return value }
                    return MeetingRevision.bookmark(from: value).flatMap(movedBookmark).map { SyncEncoding.string($0) }
                }
                guard let old = movedValue(revision.oldValue), let new = movedValue(revision.newValue) else { return nil }
                copied.oldValue = old; copied.newValue = new
            case .notes, .summary, .source, .sync, .unknown: return nil
            }
            return copied
        }
        let title = folded.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = MeetingRevision(id: SyncEncoding.uuid("merge-entry:\(merged.id.uuidString):\(folded.id.uuidString)"), date: now,
                                    kind: revisionField(folded.id), oldValue: "",
                                    newValue: title.isEmpty ? "Merged a conversation" : "Merged “\(title)”")
        merged.revisions = (merged.revisions + putBack + revisions + [entry]).enumerated()
            .sorted { $0.element.date != $1.element.date ? $0.element.date < $1.element.date : $0.offset < $1.offset }.map(\.element)
        merged.updatedAt = now
    }

    /// A note's anchors with an ID no saved anchor has (made up while reading plain notes) replaced by one that comes from
    /// whose notes they are, their place, and their words, so every device that reads them makes the same ones.
    private static func settled(_ anchors: [TimedNote], saved: [TimedNote]?, owner: UUID) -> [TimedNote] {
        let known = Set((saved ?? []).map(\.id))
        return anchors.enumerated().map { index, note in
            known.contains(note.id) ? note : TimedNote(id: SyncEncoding.uuid("merge-note:\(owner.uuidString):\(index):\(note.text)"), time: note.time, text: note.text)
        }
    }

    /// The recording that holds what the conversation timed by its own clock while its recordings wait to be lined up:
    /// the one another recording would be lined up against there (`Meeting.alignmentReference`), else its first placed one.
    static func leadRecording(of meeting: Meeting, among carried: [RecordingTrack]) -> (track: RecordingTrack, clock: TimelineClock)? {
        let present = carried.filter { !$0.isRemoved }
        let ids = Set(present.map(\.id))
        let candidates = [meeting.alignmentReference()].compactMap { $0 }.filter { ids.contains($0.id) }
            + present.filter { $0.derivedFrom == nil } + present
        for track in candidates { if let clock = meeting.clock(of: track.id) { return (track, clock) } }
        return nil
    }

    /// Which speaker each of `folded`'s is once it's folded into `merged`: the owner ("Me") is one person, the survivor's
    /// (its name stands); a speaker with the name of one already here, or the same voice profile (named, confirmed, or
    /// recognized), is that one; any other keeps its ID, or takes one of its own when another speaker has that ID.
    static func speakerIDs(of folded: Meeting, into merged: Meeting, profiles: SpeakerProfileMerges?) -> [String: String] {
        let owner = FusionOptions().ownerSpeakerID
        func profile(_ meeting: Meeting, _ id: String) -> UUID? {
            guard let identity = meeting.speakerIdentity(id), identity.$source.isKnown,
                  identity.source.isPersonChosen || identity.source == .recognized, let stored = identity.profileID else { return nil }
            return profiles?.resolve(stored) ?? stored
        }
        var result: [String: String] = [:]
        var taken = Set(merged.speakers.map(\.id))
        for speaker in folded.speakers {
            let same: Speaker?
            if speaker.id == owner, let theirs = merged.speakers.first(where: { $0.id == owner }) {
                same = theirs
            } else if let wanted = profile(folded, speaker.id), let match = merged.speakers.first(where: { profile(merged, $0.id) == wanted }) {
                same = match
            } else if let name = personName(speaker), let match = merged.speakers.first(where: { personName($0) == name }) {
                same = match
            } else {
                same = nil
            }
            if let same {
                result[speaker.id] = same.id
            } else if taken.contains(speaker.id) {
                var own = "\(folded.id.uuidString):\(speaker.id)"
                while taken.contains(own) { own += "+" }
                result[speaker.id] = own
                taken.insert(own)
            } else {
                taken.insert(speaker.id)
            }
        }
        return result
    }

    /// A speaker's name as a person's, compared as names are (`SpeakerProfile.normalizedName`); nil for "Speaker 3".
    private static func personName(_ speaker: Speaker) -> String? {
        SpeakerProfile.isPlaceholder(speaker.name) ? nil : SpeakerProfile.normalizedName(speaker.name)
    }
}
