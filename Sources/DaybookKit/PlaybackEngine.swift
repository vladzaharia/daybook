import AVFoundation
import Foundation
import Observation

/// Where a player stands, as both apps' player bars show it.
public enum PlaybackPhase: Equatable, Sendable {
    /// Nothing loaded: no player shows.
    case idle
    /// Getting the audio: downloading (with a fraction when known) or opening it. The Mac's audio is always here.
    case loading(Double?)
    case ready
    /// The audio can't play now; the words say why (offline, missing, undecodable).
    case unavailable(String)
}

/// How playback ended without being asked to.
public enum PlaybackEnding: Equatable, Sendable {
    /// It played to the end.
    case reachedEnd
    /// The file ended early: it couldn't be read to its end.
    case cutShort
    /// Something else stopped it: an interruption, the output device going away.
    case stoppedElsewhere
    /// It couldn't be decoded; the system's words, when it has some.
    case undecodable(String?)
}

/// A recording that couldn't be opened for playback.
public struct PlaybackError: LocalizedError, Equatable, Sendable {
    public var errorDescription: String? { "This recording couldn’t be prepared for playback." }
}

/// One recording playing, the same way on both apps: the file loaded once, the speed kept from one recording to the
/// next, a seek held inside the recording, Play at the very end starting it over, and the position read ten times a
/// second while it plays. Each app's player wraps one and adds its own: the Mac its words for a problem, the iPhone
/// downloads, the audio session, and the Lock Screen.
///
/// `isPlaying` changes only when playback starts or stops, so a view that reads only it (a row's waveform, the
/// Controls menu's Play or Pause) isn't redrawn as the position moves.
@MainActor
@Observable
public final class PlaybackEngine: NSObject, AVAudioPlayerDelegate {
    public private(set) var isPlaying = false
    public private(set) var position: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    /// The file loaded, if any.
    public private(set) var url: URL?
    /// Playback speed, kept when another recording loads.
    public var rate: Float = 1 { didSet { player?.rate = rate } }
    /// 0 plays silently (debug screenshots, tests).
    public var volume: Float = 1 { didSet { player?.volume = volume } }
    /// How many times each skip was asked for, so a skip button can answer every press (the keyboard's too).
    public private(set) var backSkips = 0
    public private(set) var forwardSkips = 0

    /// Told when playback ends without being asked to.
    @ObservationIgnored public var onEnding: (@MainActor (PlaybackEnding) -> Void)?

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var clock: Task<Void, Never>?

    /// How often the position is read while playing.
    public nonisolated static let tick: Duration = .milliseconds(100)
    /// Within this of the end, Play starts the recording over rather than playing its last moment.
    public nonisolated static let endTolerance: TimeInterval = 0.05

    public override init() { super.init() }

    /// Whether Play at `position` starts over: at the end, or within `endTolerance` of it.
    public nonisolated static func startsOver(at position: TimeInterval, duration: TimeInterval) -> Bool {
        duration > 0 && position >= duration - endTolerance
    }

    /// `seconds` held inside a recording `duration` long; anything that isn't a number is its start.
    public nonisolated static func clamped(_ seconds: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard seconds.isFinite else { return 0 }
        return min(max(0, seconds), max(0, duration))
    }

    public var isLoaded: Bool { player != nil }

    /// Opens `url` for playback, at its start. The same file again keeps its place.
    public func load(_ url: URL) throws {
        if self.url == url, player != nil { return }
        unload()
        let loaded = try AVAudioPlayer(contentsOf: url)
        loaded.delegate = self
        loaded.enableRate = true
        guard loaded.prepareToPlay() else { throw PlaybackError() }
        loaded.rate = rate
        loaded.volume = volume
        player = loaded
        self.url = url
        duration = loaded.duration
        position = 0
    }

    /// Plays from the position, or from the start when it's at the end. False when the system won't play it.
    @discardableResult
    public func play() -> Bool {
        guard let player else { return false }
        if Self.startsOver(at: player.currentTime, duration: player.duration) { player.currentTime = 0 }
        guard player.play() else {
            setPlaying(false)
            stopClock()
            return false
        }
        position = player.currentTime
        setPlaying(true)
        startClock()
        return true
    }

    public func pause() {
        guard let player else { return }
        player.pause()
        position = player.currentTime
        setPlaying(false)
        stopClock()
    }

    /// Moves to `seconds`, held inside the recording; playing or paused stays as it was.
    public func seek(to seconds: TimeInterval) {
        guard let player else { return }
        let target = Self.clamped(seconds, duration: duration)
        player.currentTime = target
        position = target
    }

    /// Back (negative) or forward from the position.
    public func skip(_ seconds: TimeInterval) {
        guard player != nil else { return }
        if seconds < 0 { backSkips += 1 } else { forwardSkips += 1 }
        seek(to: position + seconds)
    }

    /// Stops and goes back to the start, keeping the recording loaded.
    public func stop() {
        player?.stop()
        player?.currentTime = 0
        position = 0
        setPlaying(false)
        stopClock()
    }

    /// Stops and lets the recording go.
    public func unload() {
        stop()
        player?.delegate = nil
        player = nil
        url = nil
        duration = 0
    }

    /// Changes `isPlaying` only when it differs.
    private func setPlaying(_ playing: Bool) {
        if isPlaying != playing { isPlaying = playing }
    }

    // MARK: The clock

    /// Reads the position every `tick` until playback stops: one task, cancelled with it, rather than a timer that
    /// starts a task each time it fires.
    private func startClock() {
        stopClock()
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tick)
                guard !Task.isCancelled, let self else { return }
                self.readPosition()
            }
        }
    }

    private func stopClock() {
        clock?.cancel()
        clock = nil
    }

    private func readPosition() {
        guard let player else { stopClock(); return }
        position = min(player.currentTime, duration)
        // Stopped without being asked (an interruption, headphones unplugged): say so once.
        if !player.isPlaying, isPlaying {
            setPlaying(false)
            stopClock()
            onEnding?(.stoppedElsewhere)
        }
    }

    // MARK: AVAudioPlayerDelegate

    public nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let current = self.player, ObjectIdentifier(current) == finished else { return }
            self.setPlaying(false)
            self.position = self.duration
            self.stopClock()
            self.onEnding?(flag ? .reachedEnd : .cutShort)
        }
    }

    public nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let failed = ObjectIdentifier(player)
        let words = error?.localizedDescription
        Task { @MainActor [weak self] in
            guard let self, let current = self.player, ObjectIdentifier(current) == failed else { return }
            self.setPlaying(false)
            self.stopClock()
            self.onEnding?(.undecodable(words))
        }
    }
}
