import DaybookCaptions
import DaybookCore
import DaybookDevices
import DaybookIntelligence
import DaybookKit
import DaybookLink
import DaybookUI
import Foundation

/// Live captions on this Mac: its own recordings (You and Call, `LiveCaptionsController`) and a
/// recorder's live audio (Listen Live, through the device framework's `LiveCaptionHooks`), all on the
/// DaybookCaptions engine, under one setting and language. Captions start beside a recording and
/// finish after it; nothing about the recording waits for them.
extension AppState {
    func wireCaptions() {
        let settings = captionSettings
        liveModels.voices.metadata = { [weak self] in self?.library.metadata ?? LibraryMetadata() }
        captions.makeCaptioner = MacCaptioners.recordingFactory(settings: settings, live: liveModels, makesCaptioners: environment.makesCaptioners)
        devices.environment.liveCaptions.makeCaptioner = MacCaptioners.recorderFactory(settings: settings, live: liveModels,
                                                                                         makesCaptioners: environment.makesCaptioners)
        devices.environment.liveCaptions.locale = { [weak settings] in settings?.locale ?? .current }
        captions.follow(recorder)
        // Recorders recording along: their live audio is captioned here and joins this Mac's captions.
        captions.recorders.follow(devices, conversation: { [weak self] in self?.captions.meetingID }) { [weak self] update in
            self?.recorderCaptioned(update)
        }
        // An utterance several sources heard reads from the loudest; another device's lines are replaced by
        // its own recording's transcript.
        captions.session.levels = { [weak self] in self?.captionLevels() ?? [:] }
        captions.session.track = { [weak self] source in self?.captionTrack(of: source) }
        // Live recognizers are biased toward the library's approved vocabulary, including a term
        // approved while a recording runs.
        let library = self.library
        watches.append(ObservationWatch.distinctValues(of: { MacLiveModels.terms(library.glossary) }) { [weak self] terms in
            self?.liveModels.vocabulary.update(terms)
        })
        // Which live models captions use follows what's downloaded, chosen, and the captions' language.
        watches.append(ObservationWatch.values(of: { [weak self, weak settings] in
            _ = (self?.installedModels, self?.modelSelections, settings?.localeIdentifier)
        }, delay: .milliseconds(200)) { [weak self] _ in self?.refreshLiveModels() })
        // Captions the transcript replaced, or whose conversation went to the Trash, go: only when a
        // transcript or the set of conversations changes, never as notes are typed.
        watches.append(ObservationWatch.distinctValues(of: { LiveCaptionStore.transcriptDates(library.meetings) },
                                                       delay: .seconds(1)) { [weak self] _ in
            self?.pruneCaptions()
        })
        // The conversation whose captions were saved is read again, off the main actor, each time they are.
        let captions = self.captions
        watches.append(ObservationWatch.distinctValues(of: { captions.lastSave }, initial: false) { _ in
            guard let saved = captions.session.lastSaved else { return }
            Task { await captions.readSaved(saved) }
        })
    }

    /// A conversation's saved live captions as its transcript page shows them (`SavedCaptions.shown`,
    /// the iPhone's rule), each recording's, from what was last read; none while this Mac records it, when
    /// its page shows them live.
    func savedCaptions(for meeting: Meeting) -> LiveCaptions? {
        recordingID == meeting.id ? nil : SavedCaptions.shown(captions.saved[meeting.id] ?? [], for: meeting)
    }

    /// Whether a conversation has a transcript page to turn to: a transcript, or saved captions in its place.
    func hasTranscriptPage(_ meeting: Meeting) -> Bool {
        !meeting.unifiedTranscript.isEmpty || savedCaptions(for: meeting) != nil
    }

    /// Re-reads the live models captions use (`MacLiveModels`).
    func refreshLiveModels() {
        let settings = captionSettings
        liveModels.refresh(selections: modelSelections, catalog: modelCatalog, engines: runtime.engines,
                           locale: settings.locale, store: runtime.store) { [weak settings] models, languages in
            let ready = models.transcribes(settings?.locale ?? .current)
            if settings?.hasLiveModels != ready { settings?.hasLiveModels = ready }
            if settings?.liveLanguages != languages { settings?.liveLanguages = languages }
        }
    }

    /// Before the recorder starts: the tap that hands each source's audio to its captioner.
    func prepareCaptions(for id: UUID) {
        recorder.captionTap = captions.prepare(meetingID: id, includesCall: includeComputerAudio)
    }

    /// The recording is running: captions start beside it, never in its way.
    func startCaptions() {
        let locale = captionSettings.locale, startedAt = recorder.startedAt ?? Date()
        Task { await captions.start(locale: locale, startedAt: startedAt) }
        if let id = captions.meetingID {
            captions.shareCall(conversation: id, startedAt: startedAt, recipients: { [weak self] in self?.phonesShowingCaptions(of: id) ?? [] },
                               send: { [weak self] message, phone in try? await self?.phoneLink.send(.captions(message), to: phone) })
        }
    }

    /// The recording ended, or never started: captions finish and save on their own time.
    func finishCaptions() {
        recorder.captionTap = nil
        Task { await captions.finish() }
    }

    /// A recorder recording along captioned its live audio: its lines move onto this Mac's recording by when each
    /// began, counted from where its live stream starts on this Mac's clock (`Update.startedAt`), not from its
    /// recording's start, which a recorder already recording began minutes before the stream.
    func recorderCaptioned(_ update: LiveCaptureCaptions.Update) {
        guard let id = recordingID, captions.meetingID == id, let start = recordingStartedAt else { return }
        let link = meetings.first { $0.id == id }?.companions?.last { $0.deviceID == update.recorderID && $0.macEndedAt == nil }
        let began = update.startedAt ?? link?.recorderStartedAt ?? start
        captions.received(update.segments, from: .device(update.recorderID), name: update.name, offset: began.timeIntervalSince(start))
    }

    /// A paired iPhone recording this conversation too sent the captions it's making (its microphone,
    /// and a recorder it manages), and those it took back: they join this Mac's, placed by when its
    /// recording began on this Mac's clock. They stay here: never sent on.
    func phoneCaptioned(_ message: LinkCaptions, from phone: UUID) {
        guard let id = recordingID, message.conversationID == id, captions.meetingID == id, let start = recordingStartedAt else { return }
        let began = phoneLink.peers[phone]?.clock?.localDate(fromPeer: message.startedAt) ?? message.startedAt
        let offset = began.timeIntervalSince(start)
        let phoneName = DaybookPhoneIntegration().kind.shortName
        let own = LiveCaptionSource.device("phone:\(phone.uuidString)")
        if let removed = message.removed, !removed.isEmpty {
            captions.received([], removed: removed, from: own, name: phoneName, offset: offset, changesOnly: true, forwards: false)
        }
        for (device, lines) in Dictionary(grouping: message.lines, by: \.device) {
            let segments = lines.map { line in
                LiveCaptionSegment(id: line.id, start: line.start, end: line.end, text: line.text, isTentative: line.isTentative,
                                   speaker: line.speakerSlot.map { LiveCaptionSpeaker(slot: $0, name: line.speakerName) })
            }
            let source = device.map { LiveCaptionSource.device("phone:\(phone.uuidString):\($0)") } ?? own
            captions.received(segments, from: source, name: device ?? phoneName, offset: offset, changesOnly: true, forwards: false)
        }
    }

    /// The iPhones recording conversation `id` with this Mac that show other devices' captions: they get its call's.
    func phonesShowingCaptions(of id: UUID) -> [UUID] {
        guard recordingID == id else { return [] }
        return phoneLink.peers.values.filter { $0.capabilities.showsCaptions && isRecording(id, with: $0.deviceID.uuidString) }
            .map(\.deviceID)
    }

    /// Each source's level now, for an utterance several heard: this Mac's microphone and call, each recorder's
    /// live audio, and each iPhone's meter.
    func captionLevels() -> [LiveCaptionSource: Double] {
        guard let id = recordingID else { return [:] }
        var levels: [LiveCaptionSource: Double] = [.microphone: recorder.levels.microphone.meterValue]
        if recorder.levels.isCapturingCall { levels[.call] = recorder.levels.call.meterValue }
        for session in devices.sessions {
            if let level = session.liveLevel(into: id) { levels[.device(session.id)] = level }
        }
        for phone in phoneLink.peers.keys {
            if let level = phoneLevels.last(phone, conversation: id) { levels[.device("phone:\(phone.uuidString)")] = level }
        }
        return levels
    }

    /// Another device's recording of this one, by its lines' source: an iPhone's by the recording ID its link
    /// gave, a recorder's by its own; nil until it's known (a recorder's iPhone-managed recorder never is here).
    func captionTrack(of source: LiveCaptionSource) -> LiveCaptionTrack? {
        guard source.isDevice, let id = captions.meetingID, let meeting = meetings.first(where: { $0.id == id }) else { return nil }
        let device = String(source.rawValue.dropFirst("device:".count))
        let since = (captions.session.startedAt ?? recordingStartedAt ?? Date()).addingTimeInterval(-60)
        let link: CompanionRecording?
        if device.hasPrefix("phone:") {
            let phone = device.dropFirst("phone:".count)
            guard !phone.contains(":") else { return nil }
            link = meeting.companions?.last { $0.deviceKind == DaybookPhoneIntegration.id && $0.deviceID == phone && $0.macStartedAt >= since }
        } else {
            link = meeting.companions?.last { $0.deviceID == device && $0.macStartedAt >= since }
        }
        guard let link, let recording = link.recordingID else { return nil }
        return LiveCaptionTrack(trackID: link.trackID, deviceKind: link.deviceKind, recordingID: recording)
    }

    /// Removes the captions transcripts replaced and those of conversations gone to the Trash, off the
    /// main actor, then reads what's left.
    func pruneCaptions() {
        guard library.isLoaded else { return }
        let captions = self.captions, store = captions.store, keeping = Set([captions.meetingID, recordingID].compactMap { $0 })
        let coverage = LiveCaptionStore.coverage(library.meetings)
        Task {
            await store.prune(coverage, keeping: keeping)
            await captions.readSaved()
        }
    }

    #if DEBUG
    /// `--simulate-recording` with `--demo-captions`: scripted You and Call captions, no audio.
    func startDemoCaptions(_ id: UUID) {
        _ = captions.prepare(meetingID: id, includesCall: true)
        startCaptions()
    }
    #endif
}
