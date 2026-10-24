import Combine
import DaybookCaptions
import DaybookCore
import Foundation

/// Live captions on this Mac: its own recordings (You and Call, `LiveCaptionsController`) and a
/// recorder's live audio (Listen Live, through the device framework's `LiveCaptionHooks`), all on the
/// DaybookCaptions engine, under one setting and language. Captions start beside a recording and
/// finish after it; nothing about the recording waits for them.
extension AppState {
    func wireCaptions() {
        let settings = captionSettings
        devices.environment.liveCaptions.makeCaptioner = MacCaptioners.recorderFactory(settings: settings)
        devices.environment.liveCaptions.locale = { [weak settings] in settings?.locale ?? .current }
        captions.follow(recorder)
        // Captions the transcript replaced, or whose conversation went to the Trash, go.
        library.$meetings
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] meetings in self?.pruneCaptions(meetings) }
            .store(in: &subscriptions)
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
