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

    /// What the notice says of a recording an earlier run left, as it's filed: one Daybook was making when it quit, or one
    /// Stop had ended that Daybook was interrupted while saving (whole, so nothing's said to be missing).
    static func recovered(_ recovery: PhoneRecording.Recovery) -> String {
        switch recovery {
        case .quitWhileRecording: return "Recovered a recording Daybook was making when it quit."
        case .interruptedWhileSaving: return "Saved a recording Daybook was interrupted while saving."
        }
    }

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
        // Recovery leaves its folder be meanwhile.
        let folder = recording.stagingDirectory.standardizedFileURL
        let registered = finishingFolders.insert(folder).inserted
        defer { if registered { finishingFolders.remove(folder) } }
        let join = multipoints.join(for: recording, session: session)
        // A Mac waits for it: the Macs hear where it stands until it's on its way.
        if join != nil { multipoints.outgoingFiling(recording.id, recordingID: recording.recordingID.uuidString) }
        let filing: Filing
        // A Mac's conversation that hasn't synced here yet: one pass first, so this files into its copy.
        if join != nil, library.controller.meeting(recording.id) == nil, sync.isConnected { await sync.synchronize(.filed) }
        do {
            let filed = try await library.fileRecording(recording, join: join, requestTranscription: settings.requestsTranscription)
            noteFiled(filed.meeting.id)
            filing = .saved(filed.meeting.id, Date())
            if join != nil { multipoints.outgoingFiled(recording.id, into: filed.meeting.id) }
            let identity = PhoneDevice.identity(recordingID: recording.recordingID, installation: library.installationID)
            if let track = filed.meeting.tracks.first(where: { $0.device == identity }) {
                await captions.attach(trackID: track.id, meetingID: filed.meeting.id)
                // Speakers the live model missed, from the recording, while the app is in front.
                labelCaptionSpeakers()
            }
            if let recovery = recording.recovery { say(Self.recovered(recovery)) }
            if let request = filed.request { link.nudge(request) }
            if !options.isRunningTests { sync.synchronizeFinishing(.filed) }
            // Transcribed here when this iPhone has the models (it claimed the request as it filed it).
            processor.pickUp()
        } catch {
            say(Self.notFiled, details: error.localizedDescription)
            filing = .failed(Self.notFiled)
            if join != nil { multipoints.outgoingFiled(recording.id, into: nil) }
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
    /// Record; with none of those, the folder goes, once every file in it could be read (a locked iPhone can't open
    /// them, and that's never proof of nothing). Either way the person hears what happened.
    func fileUnrecorded(_ folder: URL) async -> StopOutcome {
        do {
            let journal = try PhoneCaptureJournal.load(from: folder)
            guard UnrecordedCapture.hasContent(journal) else {
                if StagingProtection.canReadAll(in: folder) { try? FileManager.default.removeItem(at: folder) }
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
        // Stopped while the iPhone was locked: what was recorded is saved, and joined and filed once it's unlocked.
        let waiting = recording == nil ? recorder.waitingCapture : nil
        activities.end(Self.stoppedActivity(recording: recording, bookmarks: recording?.highlights.count ?? waiting?.journal.highlights.count ?? 0,
                                            waiting: waiting))
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
        let savedUpTo = recording?.duration ?? waiting?.duration
        let saved = savedUpTo.map { PhoneNotices.recordingStoppedText(savedUpTo: $0, because: cause, spaceLeft: spaceLeft) }
        if let saved, let id = recording?.id ?? waiting?.conversationID, !isInFront { notices.recordingStopped(saved, opening: .conversation(id)) }
        await captions.finish()
        let outcome: StopOutcome
        if let recording {
            let filing = Task { @MainActor in StopOutcome(filing: await self.file(recording, session: session)) }
            outcome = await whileFiling(recording.id, filing)
        } else if let waiting {
            // "Recording stopped" stays on the Lock Screen until the person has seen it.
            finishAfterUnlock(waiting, session: session, clocks: [], dismissesActivity: false)
            outcome = StopOutcome(filing: nil, result: RecordingStopResult(sentence: RecordingWords.savedUntilUnlock))
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
    /// saved audio ends (where its parts end, for one `waiting` for an unlock to be joined).
    static func stoppedActivity(recording: PhoneRecording?, bookmarks: Int, waiting: StoppedCapture? = nil) -> RecordingActivityAttributes.ContentState {
        RecordingActivityAttributes.ContentState(phase: .stopped, timerStart: recording?.startedAt ?? waiting?.journal.startedAt ?? Date(),
                                                 frozenElapsed: recording?.duration ?? waiting?.duration ?? 0, level: 0, bookmarkCount: bookmarks)
    }

    /// The Live Activity's end for a recording stopped while the iPhone was locked (`final`: what it showed, its clock
    /// frozen where it stopped): Saved, "Finishes when you unlock iPhone", until it's finished (`dismissFinished`).
    static func savedUntilUnlockActivity(_ final: RecordingActivityAttributes.ContentState) -> RecordingActivityAttributes.ContentState {
        var saved = final
        saved.phase = .saved
        saved.level = 0
        saved.caption = nil
        saved.canResume = nil
        saved.savedLine = RecordingWords.finishesWhenUnlocked
        return saved
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

    /// Files recordings a killed or crashed run left in staging. Safe to run again: it leaves alone the recording being
    /// made and those a stop is finishing (`finishingFolders`); one it can't read while the iPhone is locked waits,
    /// and it runs again once the iPhone is unlocked (`protectedDataMayBeAvailable`); and a folder goes only when every
    /// file in it could be read.
    func recoverLeftovers() async {
        guard !recoveringLeftovers else { return }
        recoveringLeftovers = true
        defer { recoveringLeftovers = false }
        recoveryWaitsForUnlock = false
        let leftovers = PhoneRecorder.pendingCaptures(in: library.stagingURL).filter { folder in
            let folder = folder.standardizedFileURL
            return folder != recorder.stagingDirectory?.standardizedFileURL && !finishingFolders.contains(folder)
        }
        for folder in leftovers {
            guard environment.protectedData.isAvailable() else {
                recoveryWaitsForUnlock = true
                continue
            }
            do {
                let recording = try await PhoneRecorder.recover(in: folder)
                // Made with Macs: it joins their conversation, and the ones this iPhone started are stopped.
                let session = MultipointSession(conversationID: recording.id, journaled: recording.multipoint)
                await file(recording, session: session)
                for mac in session?.macsToStop ?? [] { multipoints.queueStop(of: mac.id, conversation: recording.id) }
            } catch PhoneRecorderError.locked where !environment.protectedData.isAvailable() {
                // Locked as it read the folder: it's tried again once the iPhone is unlocked.
                recoveryWaitsForUnlock = true
            } catch PhoneRecorderError.nothingRecorded {
                // No audio at all: its notes, bookmarks, and photos are filed as notes, or the folder goes, once all of
                // it could be read.
                let journal = try? PhoneCaptureJournal.load(from: folder)
                if let journal, UnrecordedCapture.hasContent(journal) {
                    _ = await fileUnrecorded(folder)
                    let session = MultipointSession(conversationID: journal.id, journaled: journal.multipoint)
                    for mac in session?.macsToStop ?? [] { multipoints.queueStop(of: mac.id, conversation: journal.id) }
                } else if journal != nil, StagingProtection.canReadAll(in: folder) {
                    try? FileManager.default.removeItem(at: folder)
                } else if !environment.protectedData.isAvailable() {
                    recoveryWaitsForUnlock = true
                }
            } catch {
                say("Couldn’t recover a recording. Daybook tries again the next time it opens.", details: error.localizedDescription)
            }
        }
    }

    // MARK: Stopped while the iPhone was locked

    /// A recording stopped while the iPhone was locked (`afterUnlock`), until it's filed.
    struct AfterUnlock: Equatable {
        var conversationID: UUID
        /// Saved and waiting for the unlock; false once it's being joined and filed.
        var waiting: Bool
    }

    /// Whether conversation `id`'s recording, stopped while the iPhone was locked, waits for the unlock (true) or is
    /// being joined and filed after it (false); nil when it's neither.
    func waitsForUnlock(_ id: UUID) -> Bool? {
        afterUnlock.values.first { $0.conversationID == id }?.waiting
    }

    /// Stop on a locked iPhone: the recording is whole on disk and saved, and it's joined and filed once the iPhone is
    /// unlocked (`finishAfterUnlock`). Everything else ends as Stop ends it, now: the Live Activity says it's saved and
    /// finishes when the iPhone is unlocked, the captions are kept, the Macs, the recorders, and the link hear it has
    /// stopped (`ended`), and Daybook can record again.
    func leaveForUnlock(_ capture: StoppedCapture, final: RecordingActivityAttributes.ContentState, session: MultipointSession?,
                        clocks: [CapturePeerClock], ended: RunOnce) async -> StopOutcome {
        activities.end(Self.savedUntilUnlockActivity(final))
        recorder.audioTap = nil
        await captions.finish()
        ended()
        finishAfterUnlock(capture, session: session, clocks: clocks, dismissesActivity: true)
        return StopOutcome(filing: nil, result: RecordingStopResult(sentence: RecordingWords.savedUntilUnlock))
    }

    /// Joins and files a recording stopped while the iPhone was locked, once it's unlocked, as Stop would have: under
    /// background time while it waits and while it finishes, where iOS grants it, and from the wait again if the
    /// iPhone locks as it joins. Meanwhile recovery leaves its folder be, and a photo taken as it ended waits for it.
    /// `dismissesActivity`: its Live Activity said "Finishes when you unlock iPhone", and goes once it has.
    func finishAfterUnlock(_ capture: StoppedCapture, session: MultipointSession?, clocks: [CapturePeerClock], dismissesActivity: Bool) {
        let folder = capture.directory.standardizedFileURL
        let id = capture.conversationID
        finishingFolders.insert(folder)
        afterUnlock[folder] = AfterUnlock(conversationID: id, waiting: true)
        // Its own stop is noted next ("Saved to Daybook. It finishes when you unlock iPhone.").
        let stop = stopsNoted + 1
        filings[id] = Task { @MainActor in
            let outcome = await self.finishingAfterUnlock(capture, session: session, clocks: clocks)
            // Where it went, unless a later stop has said where its recording went.
            if self.stopsNoted <= stop { self.noteStopped(outcome) }
            if dismissesActivity { self.activities.dismissFinished(conversationID: id) }
            self.afterUnlock[folder] = nil
            self.finishingFolders.remove(folder)
            self.publish()
        }
    }

    private func finishingAfterUnlock(_ capture: StoppedCapture, session: MultipointSession?, clocks: [CapturePeerClock]) async -> StopOutcome {
        let folder = capture.directory.standardizedFileURL
        while true {
            // An unlock while iOS grants this time finishes it at once; past it, Daybook finishes it when it next runs.
            let waiting = BackgroundAssertion(environment.backgroundTime)
            waiting.begin(Self.savingTitle)
            await waitUntilUnlocked()
            waiting.end()
            afterUnlock[folder]?.waiting = false
            let time = BackgroundAssertion(environment.backgroundTime)
            time.begin(Self.savingTitle)
            defer { time.end() }
            do {
                var recording = try await PhoneRecorder.finish(capture)
                if !clocks.isEmpty { recording.capture.peerClocks = clocks }
                return StopOutcome(filing: await file(recording, session: session))
            } catch PhoneRecorderError.locked where !environment.protectedData.isAvailable() {
                // Locked again as it joined: it waits for the next unlock.
                afterUnlock[folder]?.waiting = true
            } catch PhoneRecorderError.nothingRecorded {
                return await fileUnrecorded(capture.directory)
            } catch {
                // Kept for the next launch, which joins and files it as it finds it.
                var kept = capture.journal
                kept.state = .stopped
                try? kept.write(to: capture.directory)
                say(Self.notFinished, details: error.localizedDescription)
                return StopOutcome(filing: .failed(Self.notFinished), result: RecordingStopResult(sentence: Self.notFinished))
            }
        }
    }

    /// How often a wait for an unlock looks again while Daybook runs: iOS may have suspended it through the unlock and
    /// woken it since for something else.
    static let unlockCheckInterval: Duration = .seconds(10)

    /// Returns once files kept until unlock can be read: at once when they can, else when iOS says they can, Daybook
    /// comes to the front, or a look while it runs finds they can (`protectedDataMayBeAvailable`).
    func waitUntilUnlocked() async {
        while !environment.protectedData.isAvailable() {
            await withCheckedContinuation { waiter in
                unlockWaiters.append(waiter)
                if unlockCheck == nil { unlockCheck = lookAgainForUnlock() }
            }
        }
    }

    /// Files kept until unlock may be readable again (iOS said so, Daybook came to the front, or it's time to look):
    /// what waits for them goes on, and recovery runs again if it left a folder it couldn't read.
    func protectedDataMayBeAvailable() {
        guard environment.protectedData.isAvailable() else {
            if !unlockWaiters.isEmpty, unlockCheck == nil { unlockCheck = lookAgainForUnlock() }
            return
        }
        unlockCheck?.cancel()
        unlockCheck = nil
        let waiting = unlockWaiters
        unlockWaiters = []
        for waiter in waiting { waiter.resume() }
        if recoveryWaitsForUnlock {
            recoveryWaitsForUnlock = false
            Task { await self.recoverLeftovers() }
        }
    }

    /// Looks again in a while, and so on while something waits.
    private func lookAgainForUnlock() -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(for: Self.unlockCheckInterval)
            guard !Task.isCancelled, let self else { return }
            self.unlockCheck = nil
            self.protectedDataMayBeAvailable()
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
            meeting.adoptInk(journal.ink ?? [])
        }
        for photo in journal.photos ?? [] {
            let url = folder.appendingPathComponent(photo.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try await controller.addPhoto(from: url, to: id,
                                              timing: PhotoTimingInput(capturedAt: photo.capturedAt, time: shift.map { photo.time + $0 }),
                                              origin: .thisIPhone(installation: library.installationID), fileName: "Photo.\(url.pathExtension)")
            } catch PhotoStoreError.unsupportedImage {
                // One that can't be read until the iPhone is unlocked stays with the folder, not left out.
                if StagingProtection.cannotOpen(url) { throw PhoneRecorderError.locked }
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
