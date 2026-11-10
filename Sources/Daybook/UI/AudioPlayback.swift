import DaybookKit
import DaybookUI
import Foundation
import Observation

/// This Mac's player: a conversation's recordings from their local files, through DaybookKit's `PlaybackEngine` (the
/// iPhone's player plays through the same one), with this Mac's words for what goes wrong. The shared `PlayerBar` draws
/// it (`PlaybackControlling`).
@MainActor
@Observable
final class AudioPlaybackController: PlaybackControlling {
    @ObservationIgnored let engine = PlaybackEngine()

    /// Whether it's playing. What reads only this (the Controls menu's Play or Pause) isn't redrawn as `position` moves
    /// ten times a second.
    var isPlaying: Bool { engine.isPlaying }
    var position: TimeInterval { engine.position }
    var duration: TimeInterval { engine.duration }
    var backSkips: Int { engine.backSkips }
    var forwardSkips: Int { engine.forwardSkips }
    /// What went wrong, in a sentence, while the recording stays open or when it couldn't be.
    private(set) var errorMessage: String?
    /// The system's words for `errorMessage`, in its tooltip.
    private(set) var errorDetails: String?
    /// Playback speed, kept when another source loads.
    var rate: Float {
        get { engine.rate }
        set { engine.rate = newValue }
    }
    /// The recording and conversation now loaded, so views can follow along.
    private(set) var trackID: UUID?
    private(set) var meetingID: UUID?

    init() {
        engine.onEnding = { [weak self] ending in self?.ended(ending) }
    }

    /// Starts or seeks playback of one recording of a conversation.
    func play(url: URL, at seconds: TimeInterval = 0, trackID: UUID, meetingID: UUID) {
        self.trackID = trackID; self.meetingID = meetingID
        play(url: url, at: seconds)
    }

    /// Silences the current source; used only by debug launch actions.
    func mute() { engine.volume = 0 }

    func toggle() {
        guard engine.isLoaded else { return }
        if isPlaying { pause() } else { resume() }
    }

    func skip(_ seconds: TimeInterval) { engine.skip(seconds) }

    /// Starts or seeks playback; loading another URL replaces the current source.
    func play(url: URL, at seconds: TimeInterval = 0) {
        do {
            try engine.load(url)
            errorMessage = nil; errorDetails = nil
            engine.seek(to: seconds)
            resume()
        } catch {
            engine.unload()
            errorMessage = "This recording couldn’t be opened."; errorDetails = error.localizedDescription
        }
    }

    func resume() {
        guard engine.isLoaded else { return }
        guard engine.play() else {
            errorMessage = "Playback couldn’t start. Check your output device and try again."; errorDetails = nil
            return
        }
        errorMessage = nil; errorDetails = nil
    }

    func pause() { engine.pause() }

    /// Stops playback and returns to the beginning, retaining the loaded source.
    func stop() { engine.stop() }

    /// Stops playback and releases the source, which hides playback controls.
    func unload() {
        engine.unload()
        trackID = nil
        meetingID = nil
        errorMessage = nil; errorDetails = nil
    }

    /// Bind a playback slider's setter to this method. Seeking preserves pause/play.
    func seek(to seconds: TimeInterval) { engine.seek(to: seconds) }

    private func ended(_ ending: PlaybackEnding) {
        switch ending {
        case .reachedEnd, .stoppedElsewhere: break
        case .cutShort: errorMessage = "Playback stopped before the end of the recording."; errorDetails = nil
        case .undecodable(let words): errorMessage = "This recording couldn’t be played."; errorDetails = words
        }
    }

    // MARK: PlaybackControlling

    /// The Mac's audio is always on it, so it never loads: it's ready, or it says it can't open the recording.
    var phase: PlaybackPhase {
        if duration > 0 { return .ready }
        if let errorMessage, meetingID != nil { return .unavailable(errorMessage) }
        return .idle
    }

    /// A problem with the recording that's open.
    var problem: String? { duration > 0 ? errorMessage : nil }
    var problemDetails: String? { errorDetails }

    func close() { unload() }
}
