import Accelerate
import AVFoundation
import Foundation

/// Deterministic random numbers so synthetic recordings are identical on every run.
struct SeededRandom {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func uniform(_ range: ClosedRange<Double>) -> Double { range.lowerBound + uniform() * (range.upperBound - range.lowerBound) }
}

/// A synthetic conversation in "true time" at 8 kHz: voiced syllables (harmonics shaped by vowel
/// formants, with a consonant noise burst) in talk spurts and pauses, alternating between a remote
/// talker (heard on the call) and a local one (only in the room). Nothing is recorded or downloaded.
struct SyntheticEvent {
    static let rate = 8_000.0
    /// True time of sample 0, seconds.
    var start: Double
    /// The remote side as the call delivers it: clean, no room.
    var remote: [Float]
    /// What a recorder in the room hears: both talkers with reverb, the remote one through a speaker.
    var room: [Float]

    var end: Double { start + Double(remote.count) / Self.rate }

    struct Reverb {
        var taps: [(delay: Int, gain: Float)]
        /// A direct path plus 48 reflections with exponentially decaying gain (RT60 about 0.45 s).
        static func room(seed: UInt64) -> Reverb {
            var random = SeededRandom(seed)
            var taps: [(Int, Float)] = [(0, 1)]
            for _ in 0..<48 {
                let delay = random.uniform(0.004...0.42)
                let decay = Float(exp(-6.9 * delay / 0.45))
                taps.append((Int(delay * SyntheticEvent.rate), decay * Float(random.uniform(0.25...0.6)) * (random.uniform() < 0.5 ? -1 : 1)))
            }
            return Reverb(taps: taps)
        }
    }

    /// `remoteShare` of the talk spurts belong to the remote talker.
    static func conversation(seed: UInt64, start: Double = 0, duration: Double, remoteShare: Double = 0.6,
                             remoteInRoomGain: Float = 0.5, localGain: Float = 1, noiseLevel: Float = 0.02) -> SyntheticEvent {
        var random = SeededRandom(seed)
        let count = Int(duration * rate)
        var remote = [Float](repeating: 0, count: count)
        var room = [Float](repeating: 0, count: count)
        let remoteReverb = Reverb.room(seed: seed &+ 11), localReverb = Reverb.room(seed: seed &+ 23)
        let vowels: [(Double, Double)] = [(730, 1090), (270, 2290), (300, 870), (530, 1840), (570, 840), (440, 1020), (660, 1720)]
        let noise = (0..<4096).map { _ in Float(random.uniform(-1...1)) }
        var time = random.uniform(0.2...1.0)
        var syllable = [Float](repeating: 0, count: Int(0.5 * rate))
        var phase = [Float](repeating: 0, count: syllable.count)
        while time < duration - 1 {
            let isRemote = random.uniform() < remoteShare
            let pitch = isRemote ? random.uniform(95...140) : random.uniform(170...240)
            let syllables = Int(random.uniform(3...14))
            for _ in 0..<syllables {
                let length = Int(random.uniform(0.11...0.32) * rate)
                guard time + Double(length) / rate < duration - 0.5 else { break }
                vDSP_vclr(&syllable, 1, vDSP_Length(length))
                let (f1, f2) = vowels[Int(random.uniform() * Double(vowels.count)) % vowels.count]
                let f0 = pitch * random.uniform(0.9...1.12)
                var harmonic = 1
                while Double(harmonic) * f0 < 3_600, harmonic <= 30 {
                    let frequency = Double(harmonic) * f0
                    let amplitude = 1 / (1 + pow((frequency - f1) / 120, 2)) + 0.7 / (1 + pow((frequency - f2) / 160, 2)) + 0.02
                    if amplitude > 0.05 {
                        var start = Float(random.uniform(0...(2 * .pi))), step = Float(2 * .pi * frequency / rate)
                        vDSP_vramp(&start, &step, &phase, 1, vDSP_Length(length))
                        var n = Int32(length)
                        vvsinf(&phase, phase, &n)
                        var gain = Float(amplitude)
                        vDSP_vsma(phase, 1, &gain, syllable, 1, &syllable, 1, vDSP_Length(length))
                    }
                    harmonic += 1
                }
                // Raised-cosine attack and release.
                let attack = min(length / 3, Int(0.015 * rate)), release = min(length / 2, Int(0.05 * rate))
                for index in 0..<attack { syllable[index] *= Float(0.5 - 0.5 * cos(.pi * Double(index) / Double(attack))) }
                for index in 0..<release { syllable[length - 1 - index] *= Float(0.5 - 0.5 * cos(.pi * Double(index) / Double(release))) }
                // Consonant: a short noise burst just before the vowel.
                let burst = Int(random.uniform(0.008...0.035) * rate)
                let burstStart = max(0, Int(time * rate) - burst)
                let loudness = Float(random.uniform(0.15...0.35)) * Float(random.uniform(0.6...1.4))
                let offset = Int(random.uniform(0...3000))
                let at = Int(time * rate)
                func add(_ destination: inout [Float], gain: Float, reverb: Reverb?) {
                    for tap in reverb?.taps ?? [(0, 1)] {
                        var g = gain * tap.gain * loudness
                        let position = at + tap.delay
                        guard position + length < destination.count else { continue }
                        destination.withUnsafeMutableBufferPointer { out in
                            vDSP_vsma(syllable, 1, &g, out.baseAddress! + position, 1, out.baseAddress! + position, 1, vDSP_Length(length))
                        }
                        var b = g * 0.6
                        let burstPosition = burstStart + tap.delay
                        guard burstPosition + burst < destination.count else { continue }
                        destination.withUnsafeMutableBufferPointer { out in
                            vDSP_vsma(Array(noise[offset..<(offset + burst)]), 1, &b, out.baseAddress! + burstPosition, 1,
                                      out.baseAddress! + burstPosition, 1, vDSP_Length(burst))
                        }
                    }
                }
                if isRemote {
                    add(&remote, gain: 1, reverb: nil)
                    add(&room, gain: remoteInRoomGain, reverb: remoteReverb)
                } else {
                    add(&room, gain: localGain, reverb: localReverb)
                }
                time += Double(length) / rate + random.uniform(0.02...0.09)
            }
            time += random.uniform(0.25...1.6)
        }
        // Room background noise: a shuffled noise table so it doesn't repeat audibly.
        if noiseLevel > 0 {
            let table = (0..<(1 << 16)).map { _ in Float(random.uniform(-1...1)) }
            var position = 0
            while position < count {
                let length = min(8_192, count - position)
                let source = Int(random.uniform(0...Double(table.count - 8_193)))
                var level = noiseLevel
                table.withUnsafeBufferPointer { values in
                    room.withUnsafeMutableBufferPointer { out in
                        vDSP_vsma(values.baseAddress! + source, 1, &level, out.baseAddress! + position, 1, out.baseAddress! + position, 1, vDSP_Length(length))
                    }
                }
                position += length
            }
        }
        return SyntheticEvent(start: start, remote: remote, room: room)
    }
}

/// How a device recorded part of the event.
struct SyntheticCapture {
    enum Format { case wav16, aac }
    var sampleRate: Double
    var format: Format
    /// True time of the recording's first sample.
    var start: Double
    var duration: Double
    /// True seconds per recorder second: the recorder's clock drift.
    var rate: Double = 1
    /// Linear gain at the start and end of each `gainSegment`-second stretch (alternating).
    var gains: [Float] = [1]
    var gainSegment: Double = 60

    /// Renders `signal` (true time, starting at `event.start`) through this capture and writes it.
    func write(_ signal: [Float], event: SyntheticEvent, to url: URL) throws {
        let settings: [String: Any]
        switch format {
        case .wav16:
            settings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
                        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        case .aac:
            settings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
                        AVEncoderBitRateKey: 48_000]
        }
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let total = Int(duration * sampleRate)
        let chunk = 1 << 16
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk))!
        var indices = [Double](repeating: 0, count: chunk)
        var floatIndices = [Float](repeating: 0, count: chunk)
        var position = 0
        while position < total {
            let length = min(chunk, total - position)
            // Event sample index for recorder sample n: (start + rate·n/fs − event.start)·8000.
            let first = (start + rate * Double(position) / sampleRate - event.start) * SyntheticEvent.rate
            let base = max(0, Int(first.rounded(.down)) - 1)
            var rampStart = first - Double(base), step = rate * SyntheticEvent.rate / sampleRate
            vDSP_vrampD(&rampStart, &step, &indices, 1, vDSP_Length(length))
            vDSP_vdpsp(indices, 1, &floatIndices, 1, vDSP_Length(length))
            let out = buffer.floatChannelData![0]
            let needed = Int(Double(length) * step) + 4
            if base + needed < signal.count, first >= 0 {
                signal.withUnsafeBufferPointer { values in
                    vDSP_vlint(values.baseAddress! + base, floatIndices, 1, out, 1, vDSP_Length(length), vDSP_Length(needed))
                }
            } else {
                // Beyond the event: silence plus whatever overlaps.
                for index in 0..<length {
                    let source = Double(base) + Double(floatIndices[index])
                    let lower = Int(source.rounded(.down))
                    if first + Double(index) * step < 0 || lower < 0 || lower + 1 >= signal.count { out[index] = 0; continue }
                    let fraction = Float(source - Double(lower))
                    out[index] = signal[lower] * (1 - fraction) + signal[lower + 1] * fraction
                }
            }
            // Recorder gain changes (automatic gain control, someone moving the device).
            let segment = Int(gainSegment * sampleRate)
            var cursor = 0
            while cursor < length {
                let absolute = position + cursor
                let index = absolute / max(1, segment)
                let within = absolute % max(1, segment)
                let span = min(length - cursor, segment - within)
                let from = gains[index % gains.count], to = gains[(index + 1) % gains.count]
                var a = from + (to - from) * Float(within) / Float(segment)
                var slope = (to - from) / Float(segment)
                vDSP_vrampmul(out + cursor, 1, &a, &slope, out + cursor, 1, vDSP_Length(span))
                cursor += span
            }
            var limit: Float = 0.98, negative: Float = -0.98
            vDSP_vclip(out, 1, &negative, &limit, out, 1, vDSP_Length(length))
            buffer.frameLength = AVAudioFrameCount(length)
            try file.write(from: buffer)
            position += length
        }
    }
}
