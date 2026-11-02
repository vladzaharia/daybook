import DaybookKit
import Foundation

// Filing what this iPhone recorded: after Stop, after a recording that stopped by itself, and at launch
// for what a run that ended left in staging. A recording that captured no audio is the person's notes,
// bookmarks, and photos all the same: they're filed as a conversation of notes, never left behind.
extension PhoneAppModel {
    /// How a stop ended: where the recording went (`lastFiling`), and what Siri says.
    struct StopOutcome {
        var filing: Filing?
        var result: RecordingStopResult

        init(filing: Filing?, result: RecordingStopResult) {
            self.filing = filing
            self.result = result
        }

        /// A recording that was filed, or couldn't be.
        init(filing: Filing) {
            self.filing = filing
            if case .failed(let sentence) = filing { result = RecordingStopResult(sentence: sentence) } else { result = .saved }
        }
    }

    /// A stop under way (`stopUnderway`), until it's done.
    struct StopUnderway {
        let token: UUID
        /// The recording it stops (`PhoneRecorder.recordingID`): a Stop for another, started meanwhile, is that one's.
        let recordingID: UUID?
        let task: Task<Void, Never>
    }

    /// Runs `work` as the stop under way of recording `recordingID`, which a Stop meanwhile waits for.
    @discardableResult
    func beginStop(of recordingID: UUID?, _ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let token = UUID()
        let task = Task { @MainActor in
            await work()
            if self.stopUnderway?.token == token { self.stopUnderway = nil }
        }
        stopUnderway = StopUnderway(token: token, recordingID: recordingID, task: task)
        return task
    }

    static let notFinished = "Couldn’t finish the recording. It’s kept, and Daybook tries again the next time it opens."
    static let notFiled = "Couldn’t add the recording to your library. It’s saved and will be added next time Daybook opens."
    /// A recording that captured no audio, with notes, bookmarks, or photos: they're a conversation of notes now.
    static let notesSaved = "No audio was recorded. Your notes are saved."
    /// One that captured no audio and nothing else.
    static let noAudio = "No audio was recorded."
    /// Its notes couldn't be added yet; they stay for the next launch.
    static let notesNotFiled = "No audio was recorded. Couldn’t add your notes to your library. They’re kept and will be added next time Daybook opens."

    /// Runs the filing of conversation `id`'s recording, registered while it runs so a photo taken as the
    /// recording ended waits for it rather than polling.
    func whileFiling(_ id: UUID?, _ filing: Task<StopOutcome, Never>) async -> StopOutcome {
        guard let id else { return await filing.value }
        let done = Task { _ = await filing.value }
        filings[id] = done
        let outcome = await filing.value
        if filings[id] == done { filings[id] = nil }
        return outcome
    }

    /// Files a finished recording into the library, joining the conversation of the Macs it was made with.
    @discardableResult
    func file(_ recording: PhoneRecording, session: MultipointSession? = nil) async -> Filing {
        let join = multipoints.join(for: recording, session: session)
        let filing: Filing
        // A Mac's conversation that hasn't synced here yet: one pass first, so this files into its copy.
        if join != nil, library.controller.meeting(recording.id) == nil, sync.isConnected { await sync.synchronize(.filed) }
        do {
            let filed = try await library.fileRecording(recording, join: join, requestTranscription: settings.requestsTranscription)
            noteFiled(filed.meeting.id)
            filing = .saved(filed.meeting.id, Date())
            let identity = PhoneDevice.identity(recordingID: recording.recordingID, installation: library.installationID)
            if let track = filed.meeting.tracks.first(where: { $0.device == identity }) {
                await captions.attach(trackID: track.id, meetingID: filed.meeting.id)
                // Speakers the live model missed, from the recording, while the app is in front.
                labelCaptionSpeakers()
            }
            if recording.recovered { say("Recovered a recording Daybook was making when it quit.") }
            if let request = filed.request { link.nudge(request) }
            if !options.isRunningTests { sync.synchronizeFinishing(.filed) }
            // Transcribed here when this iPhone has the models (it claimed the request as it filed it).
            processor.pickUp()
        } catch {
            say(Self.notFiled, details: error.localizedDescription)
            filing = .failed(Self.notFiled)
        }
        publish()
        return filing
    }

    /// Stop couldn't finish the recording (`PhoneRecorder.lastFailure`). One that captured no audio is filed
    /// as notes when it has any (`fileUnrecorded`); otherwise its folder stays, for the next launch to try again.
    func fileUnfinished(_ folder: URL?, failure: PhoneRecorderError?, reason: String?) async -> StopOutcome {
        if failure == .nothingRecorded, let folder {
            return await fileUnrecorded(folder)
        }
        guard let reason else {
            // A start cancelled before any audio: nothing was made.
            return StopOutcome(filing: nil, result: RecordingStopResult(sentence: Self.noAudio))
        }
        say(Self.notFinished, details: reason)
        return StopOutcome(filing: .failed(Self.notFinished), result: RecordingStopResult(sentence: Self.notFinished))
    }

    /// A recording that captured no audio: its notes, bookmarks, and photos become a conversation of notes
    /// ("Note at 10:15 AM", or the conversation it was recording into), which says "No recording yet" with
    /// Record; with none of those, the folder goes. Either way the person hears what happened.
    func fileUnrecorded(_ folder: URL) async -> StopOutcome {
        do {
            let journal = try PhoneCaptureJournal.load(from: folder)
            guard UnrecordedCapture.hasContent(journal) else {
                try? FileManager.default.removeItem(at: folder)
                say(Self.noAudio)
                return StopOutcome(filing: .failed(Self.noAudio), result: RecordingStopResult(sentence: Self.noAudio))
            }
            let id = try await UnrecordedCapture.file(journal, in: folder, library: library)
            noteFiled(id)
            if !options.isRunningTests { sync.synchronizeFinishing(.filed) }
            say(Self.notesSaved)
            publish()
            return StopOutcome(filing: .saved(id, Date()), result: RecordingStopResult(sentence: Self.notesSaved))
        } catch {
            say(Self.notesNotFiled, details: error.localizedDescription)
            return StopOutcome(filing: .failed(Self.notesNotFiled), result: RecordingStopResult(sentence: Self.notesNotFiled))
        }
    }

    /// The recording stopped by itself (storage full or too slow, the encoder failed): what was recorded
    /// is filed, the Live Activity ends as stopped in the warning ink with the time everything is saved up
    /// to, the Macs and recorders stop with it, and, when Daybook isn't in front, a time-sensitive
    /// notification says so. In front, the notice does. With audio saved, the notification goes before
    /// filing, which can take a while (a sync pass first, for a Mac's conversation), while iOS may suspend
    /// Daybook; without, it waits to say what happened to the notes.
    func finishUnexpectedly(_ recording: PhoneRecording?) async {
        let cause = recorder.unexpectedStop
        let details = recorder.lastError
        activities.end(Self.stoppedActivity(recording: recording, bookmarks: recording?.highlights.count ?? 0))
        let session = multipoints.session
        multipoints.stopMacsStartedHere(session)
        multipoints.endCascade(recording?.id ?? session?.conversationID ?? devices.cascade.conversation?.id, session: session, cascadesUp: false)
        multipoints.session = nil
        multipoints.recordingEnded()
        sharing.stopSharingCaptions()
        recorder.audioTap = nil
        // Storage that couldn't keep up asks to free space only when it's nearly full.
        let spaceLeft = (cause as? PhoneRecorderError) == .diskBacklog ? await PhoneNotices.spaceLeft(at: library.stagingURL) : nil
        // Everything up to its end is saved: said now, opening the conversation it's filed as.
        let saved = recording.map { PhoneNotices.recordingStoppedText(savedUpTo: $0.duration, because: cause, spaceLeft: spaceLeft) }
        if let saved, let recording, !isInFront { notices.recordingStopped(saved, opening: .conversation(recording.id)) }
        await captions.finish()
        let outcome: StopOutcome
        if let recording {
            let filing = Task { @MainActor in StopOutcome(filing: await self.file(recording, session: session)) }
            outcome = await whileFiling(recording.id, filing)
        } else {
            outcome = await fileUnfinished(recorder.unfinishedFolder, failure: recorder.lastFailure, reason: recorder.lastError ?? Self.notFinished)
        }
        noteStopped(outcome)
        // No audio at all: what happened to the notes.
        let text = saved ?? PhoneNotices.recordingStoppedText(savedUpTo: nil, because: cause, otherwise: outcome.result.sentence)
        say("\(text.title). \(text.body)", details: details)
        if saved == nil, !isInFront {
            let opens: AppDestination = { if case .saved(let id, _)? = outcome.filing { return .conversation(id) } else { return .library } }()
            notices.recordingStopped(text, opening: opens)
        }
        sharing.sendRecordingState(force: true)
        publish()
    }

    /// The Live Activity's end for a recording that stopped by itself: stopped, its clock frozen where the
    /// saved audio ends.
    static func stoppedActivity(recording: PhoneRecording?, bookmarks: Int) -> RecordingActivityAttributes.ContentState {
        RecordingActivityAttributes.ContentState(phase: .stopped, timerStart: recording?.startedAt ?? Date(),
                                                 frozenElapsed: recording?.duration ?? 0, level: 0, bookmarkCount: bookmarks)
    }

    /// What the Live Activity shows from Stop until the recorder has finished (`final`: what it showed, its clock
    /// frozen where it stopped): saving, with no buttons.
    static func savingActivity(_ final: RecordingActivityAttributes.ContentState) -> RecordingActivityAttributes.ContentState {
        var saving = final
        saving.phase = .saving
        saving.level = 0
        saving.caption = nil
        saving.canResume = nil
        return saving
    }

    /// The Live Activity's end once Stop has finished the recording (`final`: what it showed, its clock
    /// frozen where it stopped). Saved when there's a recording; never without one. A capture with no
    /// audio (or a start that never got any) ends as stopped, "No audio was recorded"; one Daybook
    /// couldn't finish, kept for the next launch, as stopped with everything up to then saved.
    static func endedActivity(_ final: RecordingActivityAttributes.ContentState, recorded: Bool, failure: PhoneRecorderError?,
                              kept: Bool) -> RecordingActivityAttributes.ContentState {
        var ended = final
        ended.canResume = nil
        guard !recorded else {
            ended.phase = .saved
            return ended
        }
        ended.phase = .stopped
        ended.level = 0
        if failure == .nothingRecorded || !kept { ended.frozenElapsed = 0 }
        return ended
    }

    /// Files recordings a killed or crashed run left in staging.
    func recoverLeftovers() async {
        for folder in PhoneRecorder.pendingCaptures(in: library.stagingURL) where folder.standardizedFileURL != recorder.stagingDirectory?.standardizedFileURL {
            do {
                let recording = try await PhoneRecorder.recover(in: folder)
                // Made with Macs: it joins their conversation, and the ones this iPhone started are stopped.
                let session = MultipointSession(conversationID: recording.id, journaled: recording.multipoint)
                await file(recording, session: session)
                for mac in session?.macsToStop ?? [] { multipoints.queueStop(of: mac.id, conversation: recording.id) }
            } catch PhoneRecorderError.nothingRecorded {
                // No audio at all: its notes, bookmarks, and photos are filed as notes, or the folder goes.
                let journal = try? PhoneCaptureJournal.load(from: folder)
                if let journal, UnrecordedCapture.hasContent(journal) {
                    _ = await fileUnrecorded(folder)
                    let session = MultipointSession(conversationID: journal.id, journaled: journal.multipoint)
                    for mac in session?.macsToStop ?? [] { multipoints.queueStop(of: mac.id, conversation: journal.id) }
                } else {
                    try? FileManager.default.removeItem(at: folder)
                }
            } catch {
                say("Couldn’t recover a recording. Daybook tries again the next time it opens.", details: error.localizedDescription)
            }
        }
    }
}

/// A recording that captured no audio (`PhoneRecorderError.nothingRecorded`: the microphone never
/// delivered, or a start raced a call). What the person made during it (notes, bookmarks, photos) is
/// theirs, so it's filed as a conversation of notes, as New Note makes, and the page offers Record.
enum UnrecordedCapture {
    /// Whether the person made anything during it.
    static func hasContent(_ journal: PhoneCaptureJournal) -> Bool {
        let notes = journal.timedNotes.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            || !journal.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return notes || !journal.highlights.isEmpty || !(journal.photos ?? []).isEmpty
    }

    /// Files it into the library and removes its folder. Into its conversation when that's here (recording
    /// into a New Note, or one a Mac leads that has synced), else a new one: the Mac's title and date when a
    /// Mac led it, "Note at 10:15 AM" otherwise. Times stay on the conversation's timeline when there was
    /// one (the first sample arrived, and, for a Mac's, moved by where this iPhone started on it); without
    /// one, notes have none. Returns the conversation's ID.
    @MainActor
    static func file(_ journal: PhoneCaptureJournal, in folder: URL, library: PhoneLibrary) async throws -> UUID {
        try await library.reload()
        let controller = library.controller
        await controller.acquireLock()
        defer { controller.releaseLock() }
        let id = journal.id
        let session = MultipointSession(conversationID: id, journaled: journal.multipoint)
        if controller.meeting(id) == nil {
            let led = session?.isMacLed == true
            let started = journal.startedAt ?? journal.createdAt
            controller.add(Meeting(id: id, title: led ? journal.multipoint?.title ?? journal.title : LibraryWords.noteTitle(at: started),
                                   date: led ? journal.multipoint?.date ?? started : started, status: .draft))
        }
        let shift = timelineShift(journal, session: session)
        let sharedNoteIDs = Set((journal.sharedNotes ?? []).map(\.id)), sharedMarkIDs = Set((journal.sharedBookmarks ?? []).map(\.id))
        let anchors = journal.timedNotes.isEmpty ? NoteTimeline.reconcile(previous: [], text: journal.notes, captureTime: nil) : journal.timedNotes
        let notes = anchors.filter { !sharedNoteIDs.contains($0.id) }.map { note in
            TimedNote(id: note.id, time: shift.flatMap { shift in note.time.map { $0 + shift } }, text: note.text)
        }
        let bookmarks = journal.highlights.filter { !sharedMarkIDs.contains($0.id) }.map { mark in
            Highlight(id: mark.id, time: mark.time + (shift ?? 0), text: mark.text)
        }
        let shared = (journal.sharedNotes ?? []).compactMap { filed in
            anchors.first { $0.id == filed.id }.map { SharedNote(id: filed.id, text: $0.text, time: filed.time) }
        }
        let sharedMarks = (journal.sharedBookmarks ?? []).compactMap { filed in
            journal.highlights.first { $0.id == filed.id }.map { Highlight(id: filed.id, time: filed.time, text: $0.text) }
        }
        controller.update(id) { meeting in
            // Not joining: no track holds them (the recording ID only names the work).
            meeting.addRecordingWork(trackID: journal.recordingID ?? id, notes: notes, bookmarks: bookmarks, joining: false)
            for note in shared { meeting.applySharedNote(note) }
            for mark in sharedMarks { _ = meeting.addSharedBookmark(mark) }
        }
        for photo in journal.photos ?? [] {
            let url = folder.appendingPathComponent(photo.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try await controller.addPhoto(from: url, to: id,
                                              timing: PhotoTimingInput(capturedAt: photo.capturedAt, time: shift.map { photo.time + $0 }),
                                              origin: .thisIPhone(installation: library.installationID), fileName: "Photo.\(url.pathExtension)")
            } catch PhotoStoreError.unsupportedImage {
                continue
            }
        }
        // The conversation is on disk before the folder, its only other copy, goes.
        try await controller.flushDurably([id])
        try? FileManager.default.removeItem(at: folder)
        return id
    }

    /// How far this capture's times move to land on its conversation's timeline: 0 for its own, where it
    /// started on a Mac's for one a Mac led (when the clocks say); nil when it never had a first sample, so
    /// its times mean nothing.
    static func timelineShift(_ journal: PhoneCaptureJournal, session: MultipointSession?) -> TimeInterval? {
        guard let started = journal.startedAt else { return nil }
        guard let session, session.isMacLed else { return 0 }
        return MultipointTimeline.offset(of: started, from: session.timelineZero).map { max(0, $0) } ?? 0
    }
}
