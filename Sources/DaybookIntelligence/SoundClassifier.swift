import AVFoundation
import DaybookCore
import Foundation
import SoundAnalysis

/// Apple's built-in sound classifier (SoundAnalysis, `SNClassifySoundRequest` `.version1`) over a
/// whole recording: per one-second frame, how much it sounds like speech, music, and an audience,
/// and how loud it is. The classifier ships with the operating system: nothing is downloaded and
/// nothing leaves the Mac. `BackgroundAudio.judge` turns the result into what's left out.
///
/// The recording is read once, block by block (`MonoAudioReader`, 16 kHz mono), so memory stays
/// bounded; the classifier and the level share each block.
public enum SoundClassifier {
    public static let classifier = "SoundAnalysis version1"
    /// Two-second windows every second: long enough to tell music from speech, fine enough for passages.
    public static let window = 2.0
    public static let hop = 1.0

    /// Speech, as the classifier names it.
    static let speechLabels: Set<String> = ["speech", "shout", "yell", "whispering", "children_shouting"]
    /// Music, singing, and instruments. Bells and chimes are left out: phones and doors make them.
    static let musicLabels: Set<String> = [
        "music", "singing", "choir_singing", "yodeling", "rapping",
        "plucked_string_instrument", "guitar", "electric_guitar", "bass_guitar", "acoustic_guitar", "steel_guitar_slide_guitar",
        "guitar_tapping", "guitar_strum", "banjo", "sitar", "mandolin", "zither", "ukulele",
        "keyboard_musical", "piano", "electric_piano", "organ", "electronic_organ", "hammond_organ", "synthesizer", "harpsichord",
        "percussion", "drum_kit", "drum", "snare_drum", "bass_drum", "timpani", "tabla", "cymbal", "hi_hat", "tambourine",
        "rattle_instrument", "gong", "mallet_percussion", "marimba_xylophone", "glockenspiel", "vibraphone", "steelpan",
        "orchestra", "brass_instrument", "french_horn", "trumpet", "trombone", "bowed_string_instrument", "violin_fiddle", "cello",
        "double_bass", "wind_instrument", "flute", "saxophone", "clarinet", "oboe", "bassoon", "harp", "harmonica", "accordion",
        "bagpipes", "didgeridoo", "theremin", "disc_scratching",
    ]
    /// A studio or stadium audience. Laughter and chatter are left out: they're part of conversations.
    static let audienceLabels: Set<String> = ["applause", "cheering", "booing"]

    /// Classifies `url`. Throws when the audio can't be read or the classifier can't run.
    public static func analyze(url: URL, progress: @escaping IntelligenceProgressHandler = { _ in }) throws -> BackgroundAudioAnalysis {
        let rate = MonoAudioReader.sampleRate
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) else {
            throw LocalIntelligenceError.invalidAudio
        }
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: window, preferredTimescale: CMTimeScale(rate))
        request.overlapFactor = 1 - hop / window
        let analyzer = SNAudioStreamAnalyzer(format: format)
        let collector = Collector()
        try analyzer.add(request, withObserver: collector)
        let duration = (try? AVAudioFile(forReading: url).duration) ?? 0
        let hopSamples = Int(hop * rate)
        var squares: [Double] = []
        var pending: [Float] = []
        var position: AVAudioFramePosition = 0
        try MonoAudioReader.read(url: url, blockSeconds: 30) { block in
            try Task.checkCancellation()
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block.count)) else { throw LocalIntelligenceError.invalidAudio }
            buffer.frameLength = AVAudioFrameCount(block.count)
            block.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: block.count) }
            analyzer.analyze(buffer, atAudioFramePosition: position)
            position += AVAudioFramePosition(block.count)
            // Mean square per hop, for the level.
            let joined = pending.isEmpty ? block : pending + block
            var start = 0
            while start + hopSamples <= joined.count {
                var sum = 0.0
                for index in start..<(start + hopSamples) { sum += Double(joined[index]) * Double(joined[index]) }
                squares.append(sum / Double(hopSamples))
                start += hopSamples
            }
            pending = Array(joined[start...])
            if duration > 0 { progress(IntelligenceProgress(min(0.99, Double(position) / rate / duration), "Listening for music and TV")) }
        }
        analyzer.completeAnalysis()
        if !pending.isEmpty { squares.append(pending.reduce(0) { $0 + Double($1) * Double($1) } / Double(pending.count)) }
        if let error = collector.error { throw error }

        let results = collector.results
        let count = (results.map { Int(($0.start / hop).rounded()) }.max() ?? -1) + 1
        var speech = [Double](repeating: 0, count: max(0, count)), music = speech, audience = speech
        for result in results {
            let index = Int((result.start / hop).rounded())
            guard index >= 0, index < count else { continue }
            speech[index] = result.speech; music[index] = result.music; audience[index] = result.audience
        }
        let frames = Int((window / hop).rounded())
        let level = (0..<max(0, count)).map { index -> Double in
            let covered = squares[min(index, squares.count)..<min(index + frames, squares.count)]
            guard !covered.isEmpty else { return -127 }
            let power = covered.reduce(0, +) / Double(covered.count)
            return power > 0 ? max(-127, 10 * log10(power)) : -127
        }
        progress(IntelligenceProgress(1, "Listened for music and TV"))
        return BackgroundAudioAnalysis(classifier: classifier, hop: hop, window: window, speech: speech, music: music,
                                       audience: audience, level: level)
    }

    /// One window's family scores.
    struct Scores: Sendable {
        var start: Double
        var speech: Double
        var music: Double
        var audience: Double
    }

    private final class Collector: NSObject, SNResultsObserving, @unchecked Sendable {
        private let lock = NSLock()
        private var _results: [Scores] = []
        private var _error: Error?
        var results: [Scores] { lock.withLock { _results.sorted { $0.start < $1.start } } }
        var error: Error? { lock.withLock { _error } }

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            var speech = 0.0, music = 0.0, audience = 0.0
            for item in result.classifications {
                if SoundClassifier.speechLabels.contains(item.identifier) { speech = max(speech, item.confidence) }
                else if SoundClassifier.musicLabels.contains(item.identifier) { music = max(music, item.confidence) }
                else if SoundClassifier.audienceLabels.contains(item.identifier) { audience = max(audience, item.confidence) }
            }
            let scores = Scores(start: result.timeRange.start.seconds, speech: speech, music: music, audience: audience)
            lock.withLock { _results.append(scores) }
        }

        func request(_ request: SNRequest, didFailWithError error: Error) {
            lock.withLock { _error = error }
        }
    }
}

private extension AVAudioFile {
    var duration: Double { processingFormat.sampleRate > 0 ? Double(length) / processingFormat.sampleRate : 0 }
}
