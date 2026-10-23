import AVFoundation
import FluidAudio
import Foundation

/// Applies the upstream offline Sortformer graph to bounded audio windows.
/// Only four probability tracks grow with recording duration (~0.72 MB/hour);
/// decoded PCM and mel features never hold the entire recording in memory.
enum BoundedSortformer {
    static func process(url: URL, models: OfflineSortformerModels, options: SpeakerAnalysisOptions,
                        progress: @escaping IntelligenceProgressHandler) throws -> SpeakerAnalysis {
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration.isFinite, duration > 0 else { throw LocalIntelligenceError.invalidAudio }
        let frameDuration = 0.08
        let totalFrames = Int(ceil(duration / frameDuration))
        let windowFrames = 384
        let overlap = options.sortformerOverlapFrames
        let hop = windowFrames - overlap
        var probabilities = [Float](repeating: 0, count: totalFrames * 4)
        var filled = [Bool](repeating: false, count: totalFrames)
        let mel = AudioMelSpectrogram()
        for startFrame in stride(from: 0, to: totalFrames, by: hop) {
            try Task.checkCancellation()
            let validFrames = min(windowFrames, totalFrames - startFrame)
            let features = try melWindow(url: url, startFrame: startFrame, duration: duration, mel: mel)
            let predictions = try models.runOffline(melTimeMajor: features.values, validMelFrames: features.frames)
            guard predictions.count >= validFrames * 4, predictions.prefix(validFrames * 4).allSatisfy(\.isFinite) else {
                throw LocalIntelligenceError.invalidSpeakerOutput
            }
            let comparedFrames = startFrame == 0 ? 0 : min(overlap, validFrames)
            let existing = Array(probabilities[(startFrame * 4)..<((startFrame + comparedFrames) * 4)])
            let mapping = align(existing: existing, incoming: predictions, frames: comparedFrames)
            for frame in 0..<validFrames {
                let global = startFrame + frame
                for speaker in 0..<4 {
                    let index = global * 4 + mapping[speaker]
                    let predicted = predictions[frame * 4 + speaker]
                    probabilities[index] = filled[global] ? (probabilities[index] + predicted) * 0.5 : predicted
                }
                filled[global] = true
            }
            progress(.init(Double(min(totalFrames, startFrame + validFrames)) / Double(totalFrames) * 0.97,
                           "Detecting speakers with Sortformer (\(options.quality.title.lowercased()))"))
            if startFrame + validFrames == totalFrames { break }
        }
        try Task.checkCancellation()
        let timeline = try DiarizerTimeline(finalizedPredictions: probabilities, tentativePredictions: [],
                                            config: .sortformerDefault, isComplete: true)
        var turns: [SpeakerTurn] = []
        for speaker in timeline.speakers.values {
            for segment in speaker.finalizedSegments {
                let start = max(0, Double(segment.startTime)), end = min(duration, Double(segment.endTime))
                guard end > start else { continue }
                turns.append(SpeakerTurn(speakerID: "S\(segment.speakerIndex + 1)", start: start, end: end,
                                         confidence: min(1, max(0, Double(segment.activity)))))
            }
        }
        turns.sort { $0.start == $1.start ? $0.speakerID < $1.speakerID : $0.start < $1.start }
        var warnings = ["Sortformer detects at most four speakers and does not create reusable voice profiles. Quiet speech or identities across silent window boundaries may be missed."]
        if options.expectedSpeakerCount != nil {
            warnings.append("The expected speaker count applies only to Community-1; Sortformer used automatic detection with four fixed speaker slots.")
        }
        progress(.init(1, "Speaker detection complete"))
        return .init(turns: turns, embeddings: [:], embeddingModelID: nil, warnings: warnings)
    }

    /// Load additional context before/after the window so centered STFT and
    /// pre-emphasis don't acquire a new zero boundary at every window start.
    static func melWindow(url: URL, startFrame: Int, duration: Double,
                          mel: AudioMelSpectrogram) throws -> (values: [Float], frames: Int) {
        let firstMel = startFrame * 8
        let readMel = max(0, firstMel - 3)
        let start = Double(readMel) * 0.01
        let end = min(duration, Double(firstMel + 3_072 + 3) * 0.01)
        let samples = try AudioSlabReader.samples(url: url, from: start, to: end)
        let features = mel.computeFlatTransposed(audio: samples)
        let offset = firstMel - readMel
        let valid = min(3_072, max(0, features.numFrames - offset))
        guard valid > 0 else { throw LocalIntelligenceError.invalidAudio }
        return (Array(features.mel[(offset * 128)..<((offset + valid) * 128)]), valid)
    }

    /// Maximize activity agreement across the four speaker-column permutations.
    /// This matches the upstream offline pipeline's window stitching objective.
    /// An entirely silent overlap contains no identity evidence; retain ordering.
    static func align(existing: [Float], incoming: [Float], frames: Int) -> [Int] {
        let identity = [0, 1, 2, 3]
        guard frames > 0, existing.count >= frames * 4, incoming.count >= frames * 4 else { return identity }
        var agreement = [Double](repeating: 0, count: 16)
        for frame in 0..<frames {
            for current in 0..<4 {
                for previous in 0..<4 {
                    agreement[current * 4 + previous] += Double(incoming[frame * 4 + current] * existing[frame * 4 + previous])
                }
            }
        }
        var best = identity, score = -Double.infinity
        for a in 0..<4 {
            for b in 0..<4 where b != a {
                for c in 0..<4 where c != a && c != b {
                    let d = 6 - a - b - c
                    let candidate = agreement[a] + agreement[4 + b] + agreement[8 + c] + agreement[12 + d]
                    if candidate > score { score = candidate; best = [a, b, c, d] }
                }
            }
        }
        return best
    }
}
