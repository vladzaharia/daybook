import AVFoundation
import Combine
import DaybookKit
import MediaPlayer
import UIKit

/// Plays one recording of one conversation, from local audio an `AudioProviding` hands it, with
/// Lock Screen and Control Center controls. It lives in the reading session, above every layout,
/// so folding or unfolding the iPhone Duo never interrupts it.
@MainActor
final class PlaybackController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    enum Phase: Equatable {
        case idle
        /// Getting the audio: downloading (with a fraction when known) or opening it.
        case loading(Double?)
        case ready
        /// The audio can't play now; the words say why (offline, missing, undecodable).
        case unavailable(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var isPlaying = false
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    /// Playback speed, kept when another recording loads.
    @Published var rate: Float = 1 { didSet { player?.rate = rate; updateNowPlaying() } }
    @Published private(set) var meetingID: UUID?
    @Published private(set) var trackID: UUID?
    /// What the Lock Screen shows.
    private(set) var title = ""
    private(set) var subtitle = ""
    /// Debug screenshots play silently (`--play-muted`).
    var muted = false { didSet { player?.volume = muted ? 0 : 1 } }

    private var player: AVAudioPlayer?
    private var currentURL: URL?
    private var timer: Timer?
    private var loading: Task<Void, Never>?
    private var commandsInstalled = false

    /// Something is loaded or loading for this conversation, so its player shows.
    func isActive(for id: UUID) -> Bool { meetingID == id && phase != .idle }

    /// Starts playing a passage, a time, or a recording of a conversation, fetching the audio
    /// through `provider` first when it isn't on this iPhone.
    func play(_ target: PlaybackTarget, in meeting: Meeting, provider: any AudioProviding) {
        guard let (track, seconds) = target.resolve(in: meeting) else {
            meetingID = meeting.id
            phase = .unavailable("This conversation has no recording to play.")
            return
        }
        title = meeting.title.isEmpty ? "Untitled Conversation" : meeting.title
        subtitle = [meeting.peopleLine, meeting.date.formatted(date: .abbreviated, time: .shortened)].compactMap { $0 }.joined(separator: " · ")
        if meetingID == meeting.id, trackID == track.id, player != nil, phase == .ready {
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
                try self.load(url)
                self.phase = .ready
                self.seek(to: seconds)
                self.resume()
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled, self.meetingID == meetingID else { return }
                // The provider's own reasons are plain ("It downloads when you’re online"); others get a sentence.
                self.phase = .unavailable(PlainError.message(for: error, fallback: "The audio couldn’t be loaded. Try again.").message)
            }
        }
    }

    private func reportDownload(_ fraction: Double, for id: UUID) {
        guard meetingID == id, case .loading(let previous) = phase else { return }
        let value = min(1, max(0, fraction.isFinite ? fraction : 0))
        // Throttle: a hundredth is the finest the bar can show.
        if let previous, abs(previous - value) < 0.01, value < 1 { return }
        phase = .loading(value)
    }

    private func load(_ url: URL) throws {
        if currentURL == url, player != nil { return }
        stopTimer()
        player?.stop()
        let loaded = try AVAudioPlayer(contentsOf: url)
        loaded.delegate = self
        loaded.enableRate = true
        guard loaded.prepareToPlay() else {
            throw NSError(domain: "DaybookPlayback", code: 1, userInfo: [NSLocalizedDescriptionKey: "This recording couldn’t be prepared for playback."])
        }
        loaded.rate = rate
        loaded.volume = muted ? 0 : 1
        player = loaded
        currentURL = url
        duration = loaded.duration
        position = 0
    }

    func toggle() { isPlaying ? pause() : resume() }

    func resume() {
        guard let player else { return }
        activateSession()
        if player.currentTime >= player.duration - 0.05 { player.currentTime = 0 }
        guard player.play() else {
            phase = .unavailable("Playback couldn’t start. Check the sound output and try again.")
            isPlaying = false
            return
        }
        isPlaying = true
        position = player.currentTime
        startTimer()
        installRemoteCommands()
        updateNowPlaying()
    }

    func pause() {
        guard let player else { return }
        player.pause()
        position = player.currentTime
        isPlaying = false
        stopTimer()
        updateNowPlaying()
    }

    func skip(_ seconds: TimeInterval) { seek(to: position + seconds) }

    func seek(to seconds: TimeInterval) {
        guard let player else { return }
        let target = seconds.isFinite ? min(max(0, seconds), duration) : 0
        player.currentTime = target
        position = target
        updateNowPlaying()
    }

    /// Stops and releases the recording, which hides the player.
    func close() {
        loading?.cancel()
        loading = nil
        player?.stop()
        player = nil
        currentURL = nil
        stopTimer()
        isPlaying = false
        position = 0
        duration = 0
        meetingID = nil
        trackID = nil
        phase = .idle
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Clock

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let player else { return }
        position = min(player.currentTime, duration)
        if !player.isPlaying, isPlaying {
            isPlaying = false
            stopTimer()
            updateNowPlaying()
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.isPlaying = false
            self.position = self.duration
            self.stopTimer()
            self.updateNowPlaying()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.isPlaying = false
            self.stopTimer()
            self.phase = .unavailable("This recording couldn’t be played.")
        }
    }

    // MARK: Lock Screen and Control Center

    private func activateSession() {
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

    private func updateNowPlaying() {
        guard player != nil else { return }
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

    deinit { timer?.invalidate() }
}
