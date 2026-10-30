import AVFoundation
import Foundation

/// Recordings for tests, without a microphone: speech from `say` and music from tones and noise
/// bursts, mixed at known levels, 16 kHz mono. Deterministic, except that `say` voices differ
/// between macOS releases. Nothing is downloaded or recorded.
public enum SyntheticAudio {
    public static let rate = 16_000.0

    /// Speech from `say` at 16 kHz; nil when the voice isn't available here (tests skip).
    public static func speech(_ text: String, voice: String, in folder: URL) throws -> [Float]? {
        let url = folder.appendingPathComponent("\(voice.replacingOccurrences(of: " ", with: "-"))-\(abs(text.hashValue)).wav")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", voice, "-o", url.path, "--data-format=LEI16@16000", text]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let samples = try? read(url), !samples.isEmpty else { return nil }
        return samples
    }

    public static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    public static func write(_ samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
    }

    /// Music-like sound at 120 bpm: a chord progression of harmonic voices, a plucked arpeggio, a bass
    /// line, and kick, snare, and hi-hat from decaying tones and noise. Deterministic.
    public static func music(seconds: Double) -> [Float] {
        let count = Int(seconds * rate)
        var out = [Float](repeating: 0, count: count)
        var seed: UInt64 = 7
        func noise() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) * 2 - 1 }
        let beat = 0.5
        let chords: [[Double]] = [[261.63, 329.63, 392.0], [220.0, 261.63, 329.63], [174.61, 220.0, 261.63], [196.0, 246.94, 293.66]]
        for i in 0..<count {
            let t = Double(i) / rate
            let chord = chords[Int(t / (beat * 4)) % chords.count]
            var v = 0.0
            for f in chord { for h in 1...4 { v += sin(2 * .pi * f * Double(h) * t + 0.3 * sin(2 * .pi * 5 * t)) / Double(h * h) * 0.12 } }
            let eighth = Int(t / (beat / 2)), since = t - Double(eighth) * beat / 2
            let note = chord[eighth % 3] * 2
            v += sin(2 * .pi * note * t) * exp(-since * 8) * 0.25 + sin(2 * .pi * note * 2 * t) * exp(-since * 12) * 0.08
            let sinceBeat = t - Double(Int(t / beat)) * beat
            v += sin(2 * .pi * chord[0] / 2 * t) * exp(-sinceBeat * 3) * 0.3
            out[i] = Float(v)
        }
        for b in 0..<Int(seconds / beat) {
            let start = Int(Double(b) * beat * rate)
            for k in 0..<Int(0.25 * rate) where start + k < count {
                let t = Double(k) / rate
                out[start + k] += Float(b % 2 == 0 ? sin(2 * .pi * (60 + 80 * exp(-t * 30)) * t) * exp(-t * 12) * 0.5 : noise() * exp(-t * 20) * 0.3)
            }
            let hat = start + Int(beat / 2 * rate)
            for k in 0..<Int(0.05 * rate) where hat + k < count { out[hat + k] += Float(noise() * exp(-Double(k) / rate * 80) * 0.12) }
        }
        return out
    }

    public static func rms(_ x: [Float]) -> Float { sqrt(x.reduce(0) { $0 + $1 * $1 } / Float(max(1, x.count))) }

    /// `x` at `decibels` relative to an RMS of 0.08 (about −22 dBFS).
    public static func level(_ x: [Float], _ decibels: Float) -> [Float] {
        let gain = 0.08 * pow(10, decibels / 20) / max(rms(x), 1e-9)
        return x.map { $0 * gain }
    }

    /// Adds `part` into `mix` from `at` seconds, for at most `seconds`.
    public static func add(_ part: [Float], into mix: inout [Float], at: Double, seconds: Double? = nil) {
        let start = Int(at * rate), length = seconds.map { Int($0 * rate) } ?? part.count
        for index in 0..<min(part.count, length) where start + index < mix.count { mix[start + index] += part[index] }
    }

    /// Silence of `seconds`, for a mix.
    public static func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * rate)) }

    /// Scales `mix` down only if it would clip.
    public static func limited(_ mix: [Float]) -> [Float] {
        let peak = mix.map(abs).max() ?? 1
        return peak > 0.99 ? mix.map { $0 / peak * 0.99 } : mix
    }
}
