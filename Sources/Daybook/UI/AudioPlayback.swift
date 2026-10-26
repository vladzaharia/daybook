import AVFoundation
import Combine
import Foundation

/// Lightweight local-file playback for source audio and transcript timestamps.
@MainActor
final class AudioPlaybackController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var currentURL: URL?
    @Published private(set) var errorMessage: String?
    /// The system's words for `errorMessage`, in its tooltip.
    @Published private(set) var errorDetails: String?
    /// Playback speed, kept when another source loads.
    @Published var rate: Float = 1 { didSet { player?.rate = rate } }
    /// The recording and conversation now loaded, so views can follow along.
    @Published private(set) var trackID: UUID?
    @Published private(set) var meetingID: UUID?
    private var player: AVAudioPlayer?
    private var timer: Timer?

    /// Starts or seeks playback of one recording of a conversation.
    func play(url: URL, at seconds: TimeInterval = 0, trackID: UUID, meetingID: UUID) {
        self.trackID = trackID; self.meetingID = meetingID
        play(url: url, at: seconds)
    }

    /// Silences the current source; used only by debug launch actions.
    func mute() { player?.volume = 0 }

    func toggle() {
        guard player != nil else { return }
        if isPlaying { pause() } else { resume() }
    }

    func skip(_ seconds: TimeInterval) { seek(to: position + seconds) }

    /// Starts or seeks playback; loading another URL replaces the current source.
    func play(url: URL, at seconds: TimeInterval = 0) {
        do {
            if currentURL != url || player == nil {
                stop()
                let loaded = try AVAudioPlayer(contentsOf: url)
                loaded.delegate = self
                loaded.enableRate = true
                guard loaded.prepareToPlay() else {
                    throw NSError(domain: "DaybookPlayback", code: 1, userInfo: [NSLocalizedDescriptionKey: "The audio file couldn’t be prepared for playback."])
                }
                loaded.rate = rate
                player = loaded
                currentURL = url
                duration = loaded.duration
            }
            errorMessage = nil; errorDetails = nil
            seek(to: seconds)
            resume()
        } catch {
            player = nil
            currentURL = nil
            duration = 0
            position = 0
            isPlaying = false
            errorMessage = "This recording couldn’t be opened."; errorDetails = error.localizedDescription
            invalidateTimer()
        }
    }

    func resume() {
        guard let player else { return }
        if player.currentTime >= player.duration { player.currentTime = 0 }
        guard player.play() else {
            errorMessage = "Playback couldn’t start. Check your output device and try again."; errorDetails = nil
            isPlaying = false
            invalidateTimer()
            return
        }
        errorMessage = nil; errorDetails = nil
        isPlaying = true
        position = player.currentTime
        invalidateTimer()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updatePosition() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func pause() {
        player?.pause()
        position = player?.currentTime ?? position
        isPlaying = false
        invalidateTimer()
    }

    /// Stops playback and returns to the beginning, retaining the loaded source.
    func stop() {
        player?.stop()
        player?.currentTime = 0
        position = 0
        isPlaying = false
        invalidateTimer()
    }

    /// Stops playback and releases the source, which hides playback controls.
    func unload() {
        stop()
        player = nil
        currentURL = nil
        trackID = nil
        meetingID = nil
        duration = 0
        errorMessage = nil; errorDetails = nil
    }

    /// Bind a playback slider's setter to this method. Seeking preserves pause/play.
    func seek(to seconds: TimeInterval) {
        guard let player else { return }
        let target = seconds.isFinite ? min(max(0, seconds), duration) : 0
        player.currentTime = target
        position = target
    }

    private func updatePosition() {
        guard let player else { return }
        position = min(player.currentTime, duration)
        if !player.isPlaying {
            isPlaying = false
            invalidateTimer()
        }
    }

    private func invalidateTimer() {
        timer?.invalidate()
        timer = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.isPlaying = false
            self.position = self.duration
            self.invalidateTimer()
            if !flag { self.errorMessage = "Playback stopped before the end of the recording."; self.errorDetails = nil }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.isPlaying = false
            self.errorMessage = "This recording couldn’t be played."; self.errorDetails = error?.localizedDescription
            self.invalidateTimer()
        }
    }

    deinit { timer?.invalidate() }
}
