import AVFoundation
import DaybookCore
import DaybookKit
import Foundation

/// Where a recording that arrives without a chosen conversation goes. Decided before the import.
struct SourceArrivalPlan {
    struct Suggestion {
        var candidates: [UUID]
        var reason: SourceSuggestion.Reason
        var confidence: Double?
        var clockOffsets: [UUID: TimeInterval]
    }

    var arrival: SourceArrival
    var attachTo: UUID?
    /// The multipoint link it fulfils.
    var companion: (meetingID: UUID, companionID: UUID)?
    /// Its place on the target's timeline, when the sound already settled it.
    var placement: SourceAlignment?
    /// For the conversation it gets on its own, when it might belong elsewhere.
    var suggestion: Suggestion?
}

/// Several recordings of one conversation: multipoint recording with a recorder, recordings that
/// arrive later and find their conversation, and enhancing a conversation with each new source.
/// See docs/multipoint.md.
extension AppState {
    /// Connects the recorders that record alongside this Mac to the library. Call once from `init`.
    func wireSources() {
        let recorders = sources.recorders
        recorders.sessions = { [weak self] in self?.devices.sessions ?? [] }
        recorders.links = { [weak self] id in self?.meetings.first { $0.id == id }?.companions ?? [] }
        recorders.write = { [weak self] id, change in
            self?.update(id) { meeting in
                var links = meeting.companions ?? []
                change(&links)
                meeting.companions = links.isEmpty ? nil : links
            }
        }
    }

    // MARK: Arrivals

    /// Decides where a recording goes when no conversation was chosen: the conversation a multipoint
    /// link reserved for it; one it overlaps in time and that sounds the same; or its own, with a
    /// suggestion when it might belong elsewhere. Nil keeps the behaviour from before multipoint
    /// (files imported by hand, unless the person turned matching on).
    /// `start` overrides reading it from the file (a synced recording carries its own), and
    /// `excluding` leaves out conversations it can't join (the one it's in already).
    func planArrival(url: URL, duration: TimeInterval, device: DeviceRecordingIdentity?,
                     start known: (date: Date?, reliable: Bool)? = nil, excluding: Set<UUID> = []) async -> SourceArrivalPlan? {
        guard device != nil || sources.matchesImportedFiles else { return nil }
        let start: (date: Date?, reliable: Bool)
        if let known { start = known } else { start = await recordingStart(url: url, device: device) }
        let arrival = SourceArrival(start: start.date, duration: duration, device: device, startIsReliable: start.reliable)
        var plan = SourceArrivalPlan(arrival: arrival)
        let others = excluding.isEmpty ? meetings : meetings.filter { !excluding.contains($0.id) }
        if let device, let link = SourceMatcher.linked(Self.fullRecording(device), start: start.date, in: others, policy: sources.policy) {
            plan.attachTo = link.meetingID
            plan.companion = link
            return plan
        }
        var live: [UUID: DateInterval] = [:]
        if let recordingID, let since = recordingStartedAt { live[recordingID] = DateInterval(start: since, end: max(since, Date())) }
        let candidates = SourceMatcher.candidates(for: arrival, in: meetings, live: live, excluding: excluding, startOf: trackStart, policy: sources.policy)
        let offsets = start.reliable ? Dictionary(candidates.map { ($0.meetingID, $0.clockOffset) }, uniquingKeysWith: { first, _ in first }) : [:]
        var decision = SourceMatcher.decide(candidates)
        if case .compareSound(let candidate) = decision {
            var found: SourceAlignment?
            if case .match(let placement) = await compareSound(of: url, duration: duration, in: candidate.meetingID,
                                                                clockOffset: candidate.clockOffset, reliableClock: start.reliable) {
                found = placement
            }
            // The sound's verdict, on the candidate's timeline like the clocks' estimate.
            let sound = found.flatMap { placed in placed.offset.map { AudioAlignment(offset: $0, rate: placed.rate, confidence: placed.confidence ?? 0) } }
            decision = SourceMatcher.decide(candidate, sound: sound, startIsReliable: start.reliable, policy: sources.policy)
            if case .attach = decision {
                plan.placement = found
                if !start.reliable { plan.placement?.clockOffset = nil }
            }
        }
        switch decision {
        case .attach(let id): plan.attachTo = id
        case .suggest(let ids, let reason, let confidence):
            plan.suggestion = .init(candidates: ids, reason: reason, confidence: confidence, clockOffsets: offsets)
        case .standalone, .compareSound: break
        }
        return plan
    }

    enum SoundComparison {
        /// Nothing placed to compare with yet, or its audio is missing.
        case unavailable
        /// Compared; the aligner found no match.
        case noMatch
        /// The comparison couldn't run (a recording unreadable, or the work cancelled): nothing was
        /// learned, so it's tried again later rather than counted as no match.
        case failed(String)
        /// The recording's placement on the conversation's timeline, with the aligner's confidence.
        case match(SourceAlignment)
    }

    /// Compares a recording's sound with a conversation's best placed recording.
    func compareSound(of url: URL, duration: TimeInterval?, in meetingID: UUID, clockOffset: TimeInterval?,
                      reliableClock: Bool, excluding: Set<UUID> = []) async -> SoundComparison {
        guard let meeting = meetings.first(where: { $0.id == meetingID }),
              let reference = meeting.alignmentReference(excluding: excluding),
              let placement = meeting.timelinePlacement(of: reference.id),
              let referenceURL = await audioURL(for: reference, meetingID: meetingID) else { return .unavailable }
        let expected = SourcePlacement.expectedOffset(clockOffset: clockOffset, reference: placement)
        let radius = reliableClock && expected != nil ? sources.policy.clockSearchRadius
            : max(sources.policy.fileSearchRadius, duration ?? 0, reference.duration ?? 0)
        let align = sources.alignAudio
        let result: AudioAlignment?
        do { result = try await detachedWork(priority: .userInitiated) { try align(url, referenceURL, expected, radius) } }
        catch { return .failed(error.localizedDescription) }
        guard let sound = result, sound.offset.isFinite, sound.rate.isFinite, sound.rate > 0, sound.confidence.isFinite else { return .noMatch }
        let composed = SourcePlacement.compose(sound, onto: placement)
        return .match(SourceAlignment(method: .audio, offset: composed.offset, rate: composed.rate, confidence: sound.confidence,
                                      referenceTrackID: reference.id, clockOffset: clockOffset))
    }

    /// After a recording's bytes are in a conversation: its start time; when the conversation already
    /// had recordings (or a multipoint link reserved it), its place on the timeline and a Version
    /// History entry; the link it fulfils; or the suggestion for a recording that might belong elsewhere.
    func sourceArrived(_ meetingID: UUID, before: Meeting, imported: Meeting, url: URL, device: DeviceRecordingIdentity?,
                       plan: SourceArrivalPlan?) async {
        let known = Set(before.tracks.map(\.id))
        // The same bytes were already in this conversation: nothing new arrived.
        guard let track = imported.tracks.first(where: { !known.contains($0.id) }) else { return }
        let carried = sources.carried.removeValue(forKey: track.sha256)
        let start: (date: Date?, reliable: Bool)
        if let plan { start = (plan.arrival.start, plan.arrival.startIsReliable) }
        else if let date = carried?.startedAt { start = (date, true) }
        else { start = await recordingStart(url: url, device: device) }
        // The link this recording fulfils, also when it was added to the conversation directly.
        let reserved = plan?.companion ?? device.flatMap {
            SourceMatcher.linked(Self.fullRecording($0), start: start.date, in: [before], policy: sources.policy)
        }
        let link = reserved.flatMap { reserved in
            reserved.meetingID == meetingID ? before.companions?.first { $0.id == reserved.companionID } : nil
        }
        let isNewSource = !before.tracks.isEmpty || link != nil
        var clockOffset = carried?.clockOffset
        if clockOffset == nil, let link {
            // The recorder's start on this Mac's clock: corrected by the clock the link measured, when
            // one did (Daybook on iPhone), which is the prior the sound search starts from.
            let zero = before.knownTimelineStart(startOf: trackStart) ?? link.macStartedAt
            let recorderStart = link.recorderStartedAt ?? start.date
            clockOffset = recorderStart.map { link.clock?.macDate(fromRecorder: $0) ?? $0 }?.timeIntervalSince(zero)
        } else if clockOffset == nil, start.reliable, let date = start.date, let zero = before.knownTimelineStart(startOf: trackStart) {
            clockOffset = date.timeIntervalSince(zero)
        }
        let name = sourceName(track)
        let reliableStart = start.reliable ? start.date : nil
        let placement = plan?.placement ?? carried?.placement
        let preferences = processingPreferences
        update(meetingID) { meeting in
            guard let index = meeting.tracks.firstIndex(where: { $0.id == track.id }) else { return }
            if meeting.tracks[index].startedAt == nil { meeting.tracks[index].startedAt = reliableStart }
            if isNewSource {
                var alignment = placement ?? SourceAlignment(method: .pending, clockOffset: clockOffset)
                if alignment.clockOffset == nil { alignment.clockOffset = clockOffset }
                meeting.tracks[index].alignment = alignment
                meeting.tracks[index].offset = alignment.isPlaced ? alignment.offset : nil
                meeting.revisions.append(MeetingRevision(field: "source:\(track.id.uuidString)", oldValue: "", newValue: "Added \(name)"))
                if let carried, let transcript = carried.transcript, !meeting.transcripts.contains(where: { $0.trackID == track.id }) {
                    Self.adopt(transcript, speakers: carried.speakers, for: track.id, into: &meeting, preferences: preferences)
                }
                for mark in carried?.highlights ?? []
                where !meeting.highlights.contains(where: { $0.trackID == track.id && $0.time == mark.time && $0.text == mark.text }) {
                    meeting.highlights.append(Highlight(trackID: track.id, time: mark.time, text: mark.text, duration: mark.duration))
                }
            }
            if let link, var links = meeting.companions, let linkIndex = links.firstIndex(where: { $0.id == link.id }) {
                links[linkIndex].state = .attached
                links[linkIndex].trackID = track.id
                links[linkIndex].recordingID = links[linkIndex].recordingID ?? device.map(Self.fullRecording)?.recordingID
                meeting.companions = links
            }
            if let suggestion = plan?.suggestion {
                meeting.sourceSuggestions = (meeting.sourceSuggestions ?? []) + [SourceSuggestion(
                    trackID: track.id, candidateMeetingIDs: suggestion.candidates, reason: suggestion.reason,
                    confidence: suggestion.confidence, clockOffsets: suggestion.clockOffsets.isEmpty ? nil : suggestion.clockOffsets)]
            }
            // A recorder's recording can arrive while this Mac is still recording the conversation.
            if meeting.id == recordingID { meeting.status = .recording }
        }
    }

    /// A transcript moving with its recording: it joins the conversation as that recording's own
    /// run, with its speakers numbered after the conversation's and matched by voice where possible.
    private static func adopt(_ transcript: TrackTranscript, speakers: [Speaker], for trackID: UUID, into meeting: inout Meeting,
                              preferences: ProcessingPreferences) {
        var copy = transcript
        copy.id = UUID(); copy.trackID = trackID; copy.knownOffset = nil
        copy.segments = copy.segments.map { segment in
            var moved = segment; moved.trackID = trackID; moved.provenance = []; return moved
        }
        let incoming = speakers.filter { speaker in !meeting.speakers.contains { $0.id == speaker.id } }.enumerated().map { index, speaker in
            var moved = speaker
            moved.sourceTrackID = trackID
            if moved.name.hasPrefix("Speaker ") { moved.name = "Speaker \(meeting.speakers.count + index + 1)" }
            return moved
        }
        if preferences.matchSpeakersAcrossSources, incoming.contains(where: { $0.embeddingModelID != nil }) {
            let matches = SpeakerMatcher.match(incoming: incoming, in: meeting,
                configuration: .init(minimumSimilarity: preferences.speakerMatchThreshold, minimumMargin: preferences.speakerMatchMargin))
            meeting.speakerMatches = (meeting.speakerMatches ?? []) + matches
            let accepted = Dictionary(matches.compactMap { match in match.targetSpeakerID.map { (match.sourceSpeakerID, $0) } },
                                      uniquingKeysWith: { first, _ in first })
            for index in copy.segments.indices {
                if let speaker = copy.segments[index].speakerID, let target = accepted[speaker] { copy.segments[index].speakerID = target }
            }
        }
        meeting.speakers += incoming
        meeting.transcripts.append(copy)
    }

    /// When a recording started: a recorder's own start (Soundcore IDs are start times), which is
    /// reliable, or the file's creation date, which copying can change.
    func recordingStart(url: URL, device: DeviceRecordingIdentity?) async -> (date: Date?, reliable: Bool) {
        if let device, let start = deviceRecordingStart(device) { return (start, true) }
        if let item = try? await AVURLAsset(url: url).load(.creationDate), let date = try? await item.load(.dateValue) { return (date, false) }
        return ((try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate, false)
    }

    /// When a recording started by the wall clock, when Daybook knows.
    func trackStart(_ track: RecordingTrack) -> Date? {
        if let startedAt = track.startedAt { return startedAt }
        // Capture sets a Mac recording's creation date to when its first sample arrived.
        if track.source == .microphone || track.source == .systemAudio { return track.createdAt }
        return track.device.flatMap(deviceRecordingStart)
    }

    /// The identity of the whole recording, for a Listen Live portion too.
    static func fullRecording(_ identity: DeviceRecordingIdentity) -> DeviceRecordingIdentity {
        guard identity.recordingID.hasSuffix(DeviceLibraryLinks.partialSuffix) else { return identity }
        var whole = identity
        whole.recordingID = String(identity.recordingID.dropLast(DeviceLibraryLinks.partialSuffix.count))
        return whole
    }

    // MARK: This Mac's recordings

    /// This Mac can record into a conversation that isn't being processed or waiting to be. One that
    /// already holds recordings gains this one as another source on its timeline.
    func canRecordInto(_ id: UUID) -> Bool {
        meetings.contains { $0.id == id } && processingID != id && !queuedIDs.contains(id)
    }

    /// Before this Mac records into a conversation: what it already holds.
    func prepareSourceCapture(_ id: UUID) {
        guard let meeting = meetings.first(where: { $0.id == id }) else { sources.captures[id] = nil; return }
        sources.captures[id] = .init(preexistingTrackIDs: Set(meeting.tracks.map(\.id)), date: meeting.date,
                                     noteIDs: Set((meeting.timedNotes ?? []).map(\.id)), highlightIDs: Set(meeting.highlights.map(\.id)),
                                     photoIDs: Set((meeting.photos ?? []).map(\.id)))
    }

    /// This Mac is recording: recorders set to record alongside it start too. Their trouble only
    /// ever shows as a status line; it can't stop or delay this recording.
    func recordingDidStart(_ id: UUID) {
        if let context = sources.captures[id], !context.preexistingTrackIDs.isEmpty {
            // A conversation that already had recordings keeps its date and timeline.
            update(id) { $0.date = context.date }
        }
        // A recording a phone asked for links that phone as already recording, rather than asking it.
        sources.recorders.macRecordingStarted(id, at: recordingStartedAt ?? Date(), lead: phoneLeads[id])
    }

    /// This Mac's recording is ending: stop the recorders Daybook started with it.
    func recordingWillFinish(_ id: UUID, at end: Date) {
        sources.recorders.macRecordingStopped(id, at: end)
    }

    /// This Mac's recording is in the library. Into a conversation that already had recordings (the
    /// other direction), the new ones join its existing timeline rather than replacing it: they wait
    /// to be lined up (sound, transcript, then clock), bookmarks made meanwhile follow the microphone
    /// recording, and notes made meanwhile move onto the timeline once it's placed.
    func sourcesAfterCapture(_ id: UUID, startedAt: Date, captureID: UUID) {
        guard let context = sources.captures.removeValue(forKey: id), !context.preexistingTrackIDs.isEmpty,
              let meeting = meetings.first(where: { $0.id == id }) else { return }
        var existing = meeting
        existing.tracks = meeting.tracks.filter { context.preexistingTrackIDs.contains($0.id) }
        let captured = meeting.tracks.filter {
            !context.preexistingTrackIDs.contains($0.id) && ($0.source == .microphone || $0.source == .systemAudio)
        }
        guard !captured.isEmpty else { return }
        let prior = existing.knownTimelineStart(startOf: trackStart).map { startedAt.timeIntervalSince($0) }
        let lead = captured.first { $0.source == .microphone && $0.derivedFrom == nil } ?? captured[0]
        let reference = existing.alignmentReference()?.id
        update(id) { meeting in
            let held = (meeting.timedNotes ?? []).filter { !context.noteIDs.contains($0.id) && $0.time != nil }.map(\.id)
            for track in captured {
                guard let index = meeting.tracks.firstIndex(where: { $0.id == track.id }) else { continue }
                let local = track.offset ?? 0
                meeting.tracks[index].startedAt = meeting.tracks[index].startedAt ?? track.createdAt
                meeting.tracks[index].alignment = SourceAlignment(method: .pending, referenceTrackID: reference,
                    clockOffset: prior.map { $0 + local }, clockID: captureID,
                    heldNoteIDs: track.id == lead.id && !held.isEmpty ? held : nil, captureOffset: track.id == lead.id ? local : nil)
                meeting.tracks[index].offset = nil
            }
            for index in meeting.highlights.indices
            where !context.highlightIDs.contains(meeting.highlights[index].id) && meeting.highlights[index].trackID == nil {
                meeting.highlights[index].trackID = lead.id
                meeting.highlights[index].time = max(0, meeting.highlights[index].time - (lead.offset ?? 0))
            }
            // Photos taken meanwhile follow the microphone recording too, like bookmarks.
            meeting.movePhotos(onto: lead, except: context.photoIDs)
            meeting.date = context.date
            meeting.revisions.append(MeetingRevision(field: "source:\(lead.id.uuidString)", oldValue: "", newValue: "Added \(self.sourceName(lead))"))
        }
    }

    // MARK: Processing

    /// The first step of processing: recordings waiting to be placed, or placed only by the clocks,
    /// are lined up from their sound against the conversation's best placed recording, once there is
    /// one to compare with. What the sound doesn't settle waits for the transcript, then the clocks
    /// (`SourceFusion`). Cancellable with the rest of the request between recordings; one comparison
    /// in progress finishes first.
    func placePendingSources(_ id: UUID) async throws {
        guard let initial = meetings.first(where: { $0.id == id }) else { return }
        func soundMayHelp(_ alignment: SourceAlignment?) -> Bool {
            guard let alignment, alignment.audioChecked != true else { return false }
            return alignment.isPending || alignment.method == .clock
        }
        let waiting = initial.tracks.filter { soundMayHelp($0.alignment) }
        guard !waiting.isEmpty else { return }
        let unplaced = Set(initial.tracks.filter { $0.alignment?.isPending == true || $0.alignment?.method == .unaligned }.map(\.id))
        for track in waiting {
            try Task.checkCancellation()
            guard let pending = meetings.first(where: { $0.id == id })?.tracks.first(where: { $0.id == track.id })?.alignment,
                  soundMayHelp(pending) else { continue }
            var placed: SourceAlignment?, compared = false
            if let url = await audioURL(for: track, meetingID: id) {
                switch await compareSound(of: url, duration: track.duration, in: id, clockOffset: pending.clockOffset,
                                          reliableClock: pending.clockOffset != nil, excluding: unplaced.union([track.id])) {
                case .unavailable, .failed: break
                case .noMatch: compared = true
                case .match(let found):
                    compared = true
                    if (found.confidence ?? 0) >= sources.policy.placeConfidence {
                        placed = found
                        placed?.clockID = pending.clockID
                        placed?.heldNoteIDs = pending.heldNoteIDs
                        placed?.captureOffset = pending.captureOffset
                    }
                }
            }
            try Task.checkCancellation()
            // Nothing to compare with yet (this Mac's recording isn't in): try again next time.
            guard placed != nil || compared else { continue }
            var checked = pending
            checked.audioChecked = true
            update(id) { $0.applyPlacements([track.id: placed ?? checked]) }
        }
        // A recording on the same clock as one the sound placed moves with it.
        guard let current = meetings.first(where: { $0.id == id }) else { return }
        let following = SourcePlacement.followingClockSiblings(current.tracks, placed: SourceFusion.currentPlacements(current))
        if !following.isEmpty { update(id) { $0.applyPlacements(following) } }
    }

    /// After a conversation's transcripts are fused: a recording waiting for its transcript to show
    /// which conversation it belongs to is checked, both for this conversation's own recording and
    /// for recordings elsewhere waiting on this one. Returns true when this conversation's recording
    /// moved into another conversation, so it isn't summarized on its own.
    func sourcesAfterTranscription(_ id: UUID) async -> Bool {
        if let meeting = meetings.first(where: { $0.id == id }),
           let suggestion = meeting.sourceSuggestions?.first(where: { $0.reason == .checkingTranscript }),
           let target = suggestion.candidateMeetingIDs.first, let candidate = meetings.first(where: { $0.id == target }),
           candidate.transcripts.contains(where: { !$0.segments.isEmpty }), canMoveSource(into: target),
           let result = transcriptCheck(suggestion, in: meeting, against: candidate) {
            if let placement = result {
                if await moveSource(from: id, suggestion: suggestion, into: target, placement: placement) {
                    update(id) { $0.status = $0.summary == nil ? .imported : .ready }
                    return true
                }
            } else { lowerToSuggestion(suggestion, in: id) }
        }
        for other in meetings where other.id != id && processingID != other.id && !queuedIDs.contains(other.id) {
            guard let suggestion = other.sourceSuggestions?.first(where: { $0.reason == .checkingTranscript && $0.candidateMeetingIDs.first == id }),
                  let candidate = meetings.first(where: { $0.id == id }),
                  let result = transcriptCheck(suggestion, in: other, against: candidate) else { continue }
            if let placement = result {
                if await moveSource(from: other.id, suggestion: suggestion, into: id, placement: placement) {
                    // It joins this run: fuse again now rather than processing the conversation twice.
                    cancelQueued(id)
                    await realign(id)
                }
            } else { lowerToSuggestion(suggestion, in: other.id) }
        }
        return false
    }

    /// Nil when the check can't run yet (not transcribed); otherwise the placement, or nil inside
    /// when the transcripts don't confirm the match.
    private func transcriptCheck(_ suggestion: SourceSuggestion, in meeting: Meeting, against candidate: Meeting) -> SourceAlignment?? {
        guard let track = meeting.tracks.first(where: { $0.id == suggestion.trackID }),
              let transcript = meeting.transcripts.filter({ $0.trackID == track.id }).max(by: { $0.createdAt < $1.createdAt }),
              candidate.transcripts.contains(where: { !$0.segments.isEmpty }) else { return nil }
        return .some(SourceMatcher.transcriptPlacement(of: transcript, track: track, clockOffset: suggestion.clockOffsets?[candidate.id],
                                                       in: candidate, policy: sources.policy))
    }

    private func lowerToSuggestion(_ suggestion: SourceSuggestion, in meetingID: UUID) {
        update(meetingID) { meeting in
            guard let index = meeting.sourceSuggestions?.firstIndex(where: { $0.id == suggestion.id }) else { return }
            meeting.sourceSuggestions?[index].reason = .lowConfidence
        }
    }

    func canMoveSource(into target: UUID) -> Bool { target != recordingID && meetings.contains { $0.id == target } }

    // MARK: Suggestions

    /// The person confirms a suggested match: the recording joins `target` as another source.
    @discardableResult
    func confirmSourceSuggestion(_ suggestionID: UUID, in meetingID: UUID, into target: UUID) async -> Bool {
        guard let meeting = meetings.first(where: { $0.id == meetingID }),
              let suggestion = meeting.sourceSuggestions?.first(where: { $0.id == suggestionID }),
              suggestion.candidateMeetingIDs.contains(target), processingID != meetingID, processingID != target,
              recordingID != meetingID, canMoveSource(into: target) else { return false }
        cancelQueued(meetingID)
        return await moveSource(from: meetingID, suggestion: suggestion, into: target, placement: nil)
    }

    /// The person keeps the recording in its own conversation.
    func dismissSourceSuggestion(_ suggestionID: UUID, in meetingID: UUID) {
        update(meetingID) { meeting in
            meeting.sourceSuggestions?.removeAll { $0.id == suggestionID }
            if meeting.sourceSuggestions?.isEmpty == true { meeting.sourceSuggestions = nil }
        }
    }

    /// Copies a recording into `target` (its original stays where it was), with its transcript so it
    /// isn't transcribed again. The conversation it came from goes to the Trash, where it can be
    /// restored, unless the person has worked in it.
    private func moveSource(from sourceID: UUID, suggestion: SourceSuggestion, into target: UUID, placement: SourceAlignment?) async -> Bool {
        guard let source = meetings.first(where: { $0.id == sourceID }),
              let track = source.tracks.first(where: { $0.id == suggestion.trackID }),
              let url = await audioURL(for: track, meetingID: sourceID),
              let targetTitle = meetings.first(where: { $0.id == target })?.title else { return false }
        let transcript = source.transcripts.filter { $0.trackID == track.id }.max { $0.createdAt < $1.createdAt }
        let speakerIDs = Set(transcript?.segments.compactMap(\.speakerID) ?? [])
        let marks = Self.highlightsMoving(with: track, from: source)
        sources.carried[track.sha256] = .init(transcript: transcript, speakers: source.speakers.filter { speakerIDs.contains($0.id) },
                                              highlights: marks, placement: placement, clockOffset: suggestion.clockOffsets?[target],
                                              startedAt: suggestion.clockOffsets?[target] == nil ? nil : trackStart(track))
        defer { sources.carried[track.sha256] = nil }
        do { _ = try await importAudio([url], source: track.source, attachTo: target, device: track.device) }
        catch { errorMessage = error.localizedDescription; return false }
        dismissSourceSuggestion(suggestion.id, in: sourceID)
        trashWhenIdle(sourceID, addedTo: targetTitle)
        return true
    }

    /// Bookmarks on a recording, or on its conversation's timeline, in the recording's own time,
    /// so they move with it.
    static func highlightsMoving(with track: RecordingTrack, from source: Meeting) -> [Highlight] {
        let own = source.timelinePlacement(of: track.id) ?? (0, 1)
        return source.highlights.compactMap { mark -> Highlight? in
            if mark.trackID == track.id { return mark }
            guard mark.trackID == nil, own.rate > 0 else { return nil }
            let local = (mark.time - own.offset) / own.rate
            guard local.isFinite, local >= 0 else { return nil }
            var moved = mark; moved.time = local; moved.trackID = track.id
            return moved
        }
    }

    /// Once the conversation isn't being processed, moves it to the Trash, unless the person has
    /// worked in it or it holds other recordings, or a recording is starting or stopping.
    func trashWhenIdle(_ id: UUID, addedTo target: String) {
        Task { [weak self] in
            guard let self else { return }
            for await current in self.$processingID.values where current != id { break }
            // Take in what other devices added meanwhile (notes or photos from the phone) before deciding. Sync keeps
            // anything that still arrives after the deletion as a new conversation.
            await self.synchronizeLibrary()
            guard let meeting = self.meetings.first(where: { $0.id == id }) else { return }
            guard !meeting.hasPersonMadeContent, meeting.tracks.count <= 1, id != self.recordingID,
                  !self.isStartingRecording, !self.isStoppingRecording else {
                self.notice = "Added this recording to “\(target)”. “\(meeting.title)” stays as it is."
                return
            }
            self.trashMeeting(id)
        }
    }

    // MARK: Words for the interface

    /// "Adding Soundcore Work recording…" while a conversation gains a source, or "Waiting to add …".
    func sourceActivity(_ id: UUID) -> String? {
        guard processingID == id || queuedIDs.contains(id), let meeting = meetings.first(where: { $0.id == id }),
              meeting.transcripts.contains(where: { !$0.segments.isEmpty }) else { return nil }
        let replaced = Set(meeting.tracks.compactMap(\.derivedFrom))
        guard let adding = meeting.tracks.first(where: { track in
            !replaced.contains(track.id) && (track.alignment?.isPending == true || !meeting.transcripts.contains { $0.trackID == track.id })
        }) else { return nil }
        let name = sourceName(adding)
        return processingID == id ? "Adding \(name)…" : "Waiting to add \(name)"
    }

    /// "Soundcore Work recording", "iPhone recording", "recording from this Mac", "“Interview.m4a”".
    func sourceName(_ track: RecordingTrack) -> String {
        if track.deviceKind == DaybookPhoneIntegration.id { return "\(phoneName(track) ?? "iPhone") recording" }
        if let kind = track.deviceKind, let name = DeviceCatalog.kind(kind)?.name { return "\(name) recording" }
        switch track.source {
        case .microphone, .systemAudio: return "recording from this Mac"
        case .soundcore: return "\(AudioSource.soundcore.title) recording"
        case .imported: return "“\(track.fileName)”"
        }
    }

    /// What a recording is in its conversation: "This Mac · microphone", "Soundcore Work".
    func sourceRole(_ track: RecordingTrack, in meeting: Meeting) -> String {
        var role: String
        // The phone records its microphone too; it isn't this Mac's.
        if track.deviceKind == DaybookPhoneIntegration.id {
            role = phoneName(track).map { "\($0) · microphone" } ?? "iPhone · microphone"
            if meeting.alignmentReports.contains(where: { $0.trackID == track.id && $0.method == .reference }) && meeting.tracks.count > 1 {
                role += " · sets the timeline"
            }
            return role
        }
        switch track.source {
        case .microphone: role = track.derivedFrom == nil ? "This Mac · microphone" : "This Mac · microphone, \(RecordingTrack.processingName(track.processing))"
        case .systemAudio: role = "This Mac · computer audio"
        case .soundcore, .imported:
            role = track.deviceKind.flatMap { DeviceCatalog.kind($0)?.name } ?? (track.source == .soundcore ? AudioSource.soundcore.title : "Imported file")
        }
        if meeting.alignmentReports.contains(where: { $0.trackID == track.id && $0.method == .reference }) && meeting.tracks.count > 1 {
            role += " · sets the timeline"
        }
        return role
    }

    /// The paired phone a recording came from, by name, when this Mac knows it.
    func phoneName(_ track: RecordingTrack) -> String? {
        guard track.deviceKind == DaybookPhoneIntegration.id, let serial = track.deviceSerial else { return nil }
        return devices.session(serial)?.device.name
    }

    /// How a recording was lined up: "Lined up by sound · starts 0:12 · 93% sure".
    func sourceTimingLine(_ track: RecordingTrack, in meeting: Meeting) -> String {
        let report = meeting.alignmentReports.first { $0.trackID == track.id }
        let placement = meeting.timelinePlacement(of: track.id)
        let starts = placement.map { "starts \(TimeLabel.short($0.offset))" }
        let sure = track.alignment?.confidence.map { "\(Int(($0 * 100).rounded()))% sure" }
        let drift = placement.flatMap { abs($0.rate - 1) > 0.000_001 ? String(format: "drift %+.3f%%", ($0.rate - 1) * 100) : nil }
        func line(_ parts: String?...) -> String { parts.compactMap { $0 }.joined(separator: " · ") }
        switch track.alignment?.method {
        case .audio?: return line("Lined up by sound", starts, sure, drift)
        case .transcript?: return line("Lined up by shared phrases", starts, sure, drift)
        case .clock?: return line("Placed by the clocks only", starts)
        case .manual?: return line("Timing set by you", starts)
        case .pending?: return processingID == meeting.id ? "Lining up…" : "Lines up when it’s processed"
        case .unaligned?: return "Couldn’t line up"
        case nil:
            switch report?.method {
            case .unaligned?: return "Couldn’t line up"
            case .anchors?: return line("Lined up by shared phrases", starts, drift)
            case .audio?: return line("Lined up by sound", starts, report?.confidence.map { "\(Int(($0 * 100).rounded()))% sure" }, drift)
            case .timestamps?: return line("Placed by the clocks only", starts)
            case .reference?: return meeting.tracks.count > 1 ? line("The main recording", starts) : "The main recording"
            case .provided?:
                let here = (track.source == .microphone || track.source == .systemAudio) && track.deviceKind != DaybookPhoneIntegration.id
                return here ? line("Recorded on this Mac", starts) : line("Placed", starts)
            case nil: return placement == nil ? "Not lined up yet" : line(starts)
            }
        }
    }
}
