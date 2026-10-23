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
    private var player: AVAudioPlayer?
    private var timer: Timer?

    /// Starts or seeks playback; loading another URL replaces the current source.
    func play(url: URL, at seconds: TimeInterval = 0) {
        do {
            if currentURL != url || player == nil {
                stop()
                let loaded = try AVAudioPlayer(contentsOf: url)
                loaded.delegate = self
                guard loaded.prepareToPlay() else {
                    throw NSError(domain: "DaybookPlayback", code: 1, userInfo: [NSLocalizedDescriptionKey: "This audio file could not be prepared for playback."])
                }
                player = loaded
                currentURL = url
                duration = loaded.duration
            }
            errorMessage = nil
            seek(to: seconds)
            resume()
        } catch {
            player = nil
            currentURL = nil
            duration = 0
            position = 0
            isPlaying = false
            errorMessage = error.localizedDescription
            invalidateTimer()
        }
    }

    func resume() {
        guard let player else { return }
        if player.currentTime >= player.duration { player.currentTime = 0 }
        guard player.play() else {
            errorMessage = "Audio playback could not start. Check your output device and try again."
            isPlaying = false
            invalidateTimer()
            return
        }
        errorMessage = nil
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
            if !flag { self.errorMessage = "Playback ended before the audio file finished." }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.isPlaying = false
            self.errorMessage = error?.localizedDescription ?? "This audio file could not be decoded."
            self.invalidateTimer()
        }
    }

    deinit { timer?.invalidate() }
}
