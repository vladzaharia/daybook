import AVFoundation
import DaybookDevices
import DaybookKit
import DaybookUI
import MediaPlayer
import Observation
import UIKit

/// Plays one recording of one conversation, from local audio an `AudioProviding` hands it, through DaybookKit's
/// `PlaybackEngine` (the Mac's player plays through the same one), with Lock Screen and Control Center controls. It lives
/// in the reading session, above every layout, so folding or unfolding the iPhone Duo never interrupts it. The shared
/// `PlayerBar` draws it (`PlaybackControlling`).
///
/// The recorder owns the audio session. While a recording is under way (`isRecording`) the player won't play, never
/// changes the session's category or activity, and has cleared the Lock Screen's Now Playing and turned off its remote
/// commands (`suspendForRecording`), so a press on the Lock Screen or an AirPods stem can't take the microphone away
/// from the recording.
@MainActor
@Observable
final class PlaybackController: PlaybackControlling {
    typealias Phase = PlaybackPhase

    @ObservationIgnored let engine = PlaybackEngine()

    private(set) var phase: PlaybackPhase = .idle
    var isPlaying: Bool { engine.isPlaying }
    var position: TimeInterval { engine.position }
    var duration: TimeInterval { engine.duration }
    var backSkips: Int { engine.backSkips }
    var forwardSkips: Int { engine.forwardSkips }
    /// Playback speed, kept when another recording loads.
    var rate: Float {
        get { engine.rate }
        set { engine.rate = newValue; updateNowPlaying() }
    }
    private(set) var meetingID: UUID?
    private(set) var trackID: UUID?
    /// What the Lock Screen shows.
    private(set) var title = ""
    private(set) var subtitle = ""
    /// Debug screenshots play silently (`--play-muted`).
    var muted = false { didSet { engine.volume = muted ? 0 : 1 } }

    /// Whether this iPhone is recording now; the recorder's state, followed once `follow(recording:)` is called.
    @ObservationIgnored private var isRecording: @MainActor () -> Bool = { false }
    @ObservationIgnored private var recordingWatch: ObservationWatch?
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var commandsInstalled = false

    init() {
        engine.onEnding = { [weak self] ending in self?.ended(ending) }
    }

    // The iPhone's problems are an unavailable phase.
    var problem: String? { nil }
    var problemDetails: String? { nil }

    /// Something is loaded or loading for this conversation, so its player shows.
    func isActive(for id: UUID) -> Bool { meetingID == id && phase != .idle }

    // MARK: Recording

    /// Follows the recorder: the moment a recording starts, playback stops for it (`suspendForRecording`), wherever it
    /// starts from (the app, a Shortcut, the Lock Screen, a Mac's request, a recorder's button), with no view involved.
    func follow(recording: @escaping @MainActor () -> Bool) {
        isRecording = recording
        recordingWatch = ObservationWatch.distinctValues(of: recording) { [weak self] recording in
            if recording { self?.suspendForRecording() }
        }
    }

    /// A recording started: the player pauses, takes its card off the Lock Screen and Control Center, and stops
    /// answering their buttons and headphones' until the person plays something here again. It leaves the audio session
    /// to the recorder: no category, no deactivation.
    func suspendForRecording() {
        loading?.cancel()
        engine.pause()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        setRemoteCommands(enabled: false)
    }

    // MARK: Playing

    /// Starts playing a passage, a time, or a recording of a conversation, fetching the audio
    /// through `provider` first when it isn't on this iPhone.
    func play(_ target: PlaybackTarget, in meeting: Meeting, provider: any AudioProviding) {
        guard let (track, seconds) = target.resolve(in: meeting) else {
            meetingID = meeting.id
            phase = .unavailable("This conversation has no recording to play.")
            return
        }
        let (title, subtitle) = Self.nowPlaying(meeting)
        self.title = title
        self.subtitle = subtitle
        if meetingID == meeting.id, trackID == track.id, engine.isLoaded, phase == .ready {
            seek(to: seconds)
            resume()
            return
        }
        loading?.cancel()
        pause()
        meetingID = meeting.id
        trackID = track.id
        phase = .loading(nil)
        let meetingID = meeting.id
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.reportDownload(fraction, for: meetingID) }
        }
        loading = Task { [weak self] in
            do {
                let url = try await provider.localAudio(for: track, in: meetingID, progress: report)
                guard let self, !Task.isCancelled, self.meetingID == meetingID else { return }
                try self.engine.load(url)
                self.engine.volume = self.muted ? 0 : 1
                self.phase = .ready
                self.seek(to: seconds)
                self.resume()
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled, self.meetingID == meetingID else { return }
                // The provider's own reasons are plain ("It downloads when you’re online"); others get a sentence.
                self.phase = .unavailable(ProblemWords(fallback: "The audio couldn’t be loaded. Try again.", error: error).message)
            }
        }
    }

    /// What the Lock Screen and paired devices show: the title, and when it was. Never who was there, and a Personal
    /// conversation by no name at all, since the Lock Screen shows it to anyone holding the phone.
    static func nowPlaying(_ meeting: Meeting) -> (title: String, subtitle: String) {
        let when = meeting.date.formatted(date: .abbreviated, time: .shortened)
        if meeting.effectivePlacement == .personal { return ("Daybook conversation", when) }
        return (meeting.title.isEmpty ? "Untitled Conversation" : meeting.title, when)
    }

    private func reportDownload(_ fraction: Double, for id: UUID) {
        guard meetingID == id, case .loading(let previous) = phase else { return }
        let value = min(1, max(0, fraction.isFinite ? fraction : 0))
        // Throttle: a hundredth is the finest the bar can show.
        if let previous, abs(previous - value) < 0.01, value < 1 { return }
        phase = .loading(value)
    }

    func toggle() { isPlaying ? pause() : resume() }

    /// Plays, unless this iPhone is recording: then the microphone has the session, and nothing plays.
    func resume() {
        guard engine.isLoaded, !isRecording() else { return }
        activateSession()
        guard engine.play() else {
            phase = .unavailable("Playback couldn’t start. Check the sound output and try again.")
            return
        }
        installRemoteCommands()
        setRemoteCommands(enabled: true)
        updateNowPlaying()
    }

    func pause() {
        guard engine.isLoaded else { return }
        engine.pause()
        if !isRecording() { updateNowPlaying() }
    }

    func skip(_ seconds: TimeInterval) {
        engine.skip(seconds)
        updateNowPlaying()
    }

    func seek(to seconds: TimeInterval) {
        engine.seek(to: seconds)
        updateNowPlaying()
    }

    /// Stops and releases the recording, which hides the player. The audio session goes back to the system only when
    /// no recording holds it.
    func close() {
        loading?.cancel()
        loading = nil
        engine.unload()
        meetingID = nil
        trackID = nil
        phase = .idle
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        guard !isRecording() else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func ended(_ ending: PlaybackEnding) {
        switch ending {
        case .reachedEnd, .cutShort, .stoppedElsewhere:
            if !isRecording() { updateNowPlaying() }
        case .undecodable:
            phase = .unavailable("This recording couldn’t be played.")
        }
    }

    // MARK: Lock Screen and Control Center

    private func activateSession() {
        guard !isRecording() else { return }
        let session = AVAudioSession.sharedInstance()
        // Spoken audio: the system pauses rather than ducks it for other speech.
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
    }

    private func installRemoteCommands() {
        guard !commandsInstalled else { return }
        commandsInstalled = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.toggle() }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.skip(-15) }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.skip(15) }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.seek(to: event.positionTime) }
            return .success
        }
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }

    /// The Lock Screen's and headphones' buttons answer while something of Daybook's can play, and not during a recording.
    private func setRemoteCommands(enabled: Bool) {
        guard commandsInstalled else { return }
        let center = MPRemoteCommandCenter.shared()
        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand, center.skipBackwardCommand,
                        center.skipForwardCommand, center.changePlaybackPositionCommand] {
            command.isEnabled = enabled
        }
    }

    private func updateNowPlaying() {
        guard engine.isLoaded, !isRecording() else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: subtitle,
            MPMediaItemPropertyAlbumTitle: "Daybook",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
    }
}
