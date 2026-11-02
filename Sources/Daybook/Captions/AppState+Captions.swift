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
        captions.makeCaptioner = MacCaptioners.recordingFactory(settings: settings, live: liveModels)
        devices.environment.liveCaptions.makeCaptioner = MacCaptioners.recorderFactory(settings: settings, live: liveModels)
        devices.environment.liveCaptions.locale = { [weak settings] in settings?.locale ?? .current }
        captions.follow(recorder)
        // Recorders recording along: their live audio is captioned here and joins this Mac's captions.
        captions.recorders.follow(devices, conversation: { [weak self] in self?.captions.meetingID }) { [weak self] update in
            self?.recorderCaptioned(update)
        }
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
                                                       delay: .seconds(1)) { [weak self] transcripts in
            self?.pruneCaptions(transcripts)
        })
        // Saved captions are read again, off the main actor, each time captions are saved.
        let captions = self.captions
        watches.append(ObservationWatch.distinctValues(of: { captions.lastSave }, initial: false) { _ in
            Task { await captions.readSaved() }
        })
    }

    /// A conversation's saved live captions as its transcript page shows them (`SavedCaptions.shown`,
    /// the iPhone's rule), from what was last read; none while this Mac records it, when its page shows
    /// them live.
    func savedCaptions(for meeting: Meeting) -> LiveCaptions? {
        recordingID == meeting.id ? nil : SavedCaptions.shown(captions.saved[meeting.id], for: meeting)
    }

    /// Whether a conversation has a transcript page to turn to: a transcript, or saved captions in its place.
    func hasTranscriptPage(_ meeting: Meeting) -> Bool {
        !meeting.unifiedTranscript.isEmpty || savedCaptions(for: meeting) != nil
    }

    /// Saved captions that match the search, in conversations it found nothing else in and its scope and
    /// tokens keep, as on the iPhone.
    var captionSearchHits: [(meeting: Meeting, segment: LiveCaptionSegment)] {
        guard isSearching, !captions.saved.isEmpty, !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let found = Set(searchHits.map(\.meetingID))
        let candidates = meetings.filter { captions.saved[$0.id] != nil && !found.contains($0.id) && recordingID != $0.id }
        let scoped = Set(LibrarySearch.hits(in: candidates, text: "", tokens: searchTokens, scope: searchScope).map(\.meetingID))
        return SavedCaptions.hits(in: candidates.filter { scoped.contains($0.id) }, query: search, captions: captions.saved)
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
        let locale = captionSettings.locale
        Task { await captions.start(locale: locale) }
    }

    /// The recording ended, or never started: captions finish and save on their own time.
    func finishCaptions() {
        recorder.captionTap = nil
        Task { await captions.finish() }
    }

    /// A recorder recording along captioned its live audio, which starts with its recording: its lines
    /// move onto this Mac's recording by when each began.
    func recorderCaptioned(_ update: LiveCaptureCaptions.Update) {
        guard let id = recordingID, captions.meetingID == id, let start = recordingStartedAt else { return }
        let link = meetings.first { $0.id == id }?.companions?.last { $0.deviceID == update.recorderID && $0.macEndedAt == nil }
        let began = update.startedAt ?? link?.recorderStartedAt ?? start
        captions.received(update.segments, from: .device(update.recorderID), name: update.name, offset: began.timeIntervalSince(start))
    }

    /// A paired iPhone recording this conversation too sent the captions it's making (its microphone,
    /// and a recorder it manages): they join this Mac's, placed by when its recording began on this
    /// Mac's clock.
    func phoneCaptioned(_ message: LinkCaptions, from phone: UUID) {
        guard let id = recordingID, message.conversationID == id, captions.meetingID == id, let start = recordingStartedAt else { return }
        let began = phoneLink.peers[phone]?.clock?.localDate(fromPeer: message.startedAt) ?? message.startedAt
        let offset = began.timeIntervalSince(start)
        for (device, lines) in Dictionary(grouping: message.lines, by: \.device) {
            let segments = lines.map { line in
                LiveCaptionSegment(id: line.id, start: line.start, end: line.end, text: line.text, isTentative: line.isTentative,
                                   speaker: line.speakerSlot.map { LiveCaptionSpeaker(slot: $0, name: line.speakerName) })
            }
            let source = LiveCaptionSource.device("phone:\(phone.uuidString)" + (device.map { ":\($0)" } ?? ""))
            captions.received(segments, from: source, name: device ?? DaybookPhoneIntegration().kind.shortName, offset: offset, changesOnly: true)
        }
    }

    /// Removes the captions transcripts replaced and those of conversations gone to the Trash, off the
    /// main actor, then reads what's left. `transcripts`: when each conversation's transcripts were made.
    func pruneCaptions(_ transcripts: [UUID: [Date]]) {
        guard library.isLoaded else { return }
        let captions = self.captions, store = captions.store, keeping = Set([captions.meetingID, recordingID].compactMap { $0 })
        Task {
            await store.prune(transcripts, keeping: keeping)
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
