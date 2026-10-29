import Combine
import DaybookCaptions
import DaybookCore
import DaybookIntelligence
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
        // Live recognizers are biased toward the library's approved vocabulary, including a term
        // approved while a recording runs.
        library.$glossary
            .map(MacLiveModels.terms)
            .removeDuplicates()
            .sink { [weak self] terms in self?.liveModels.vocabulary.update(terms) }
            .store(in: &subscriptions)
        // Which live models captions use follows what's downloaded, chosen, and the captions' language.
        Publishers.CombineLatest3($installedModels, $modelSelections, settings.$localeIdentifier)
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refreshLiveModels() }
            .store(in: &subscriptions)
        // Captions the transcript replaced, or whose conversation went to the Trash, go.
        library.$meetings
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] meetings in self?.pruneCaptions(meetings) }
            .store(in: &subscriptions)
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

    func pruneCaptions(_ meetings: [Meeting]) {
        guard library.isLoaded else { return }
        captions.store.prune(meetings: meetings, keeping: captions.meetingID ?? recordingID)
    }

    #if DEBUG
    /// `--simulate-recording` with `--demo-captions`: scripted You and Call captions, no audio.
    func startDemoCaptions(_ id: UUID) {
        _ = captions.prepare(meetingID: id, includesCall: true)
        startCaptions()
    }
    #endif
}
