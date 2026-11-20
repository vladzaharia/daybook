import AVFoundation
import DaybookCore
import DaybookKit
import Foundation
import os

/// The audio the speech models hear for one recording (docs/architecture.md, "Input levels"): the stored file itself, or,
/// when its speech is far quieter than a normal level (`SpeechLevel`), a copy raised by one constant gain.
///
/// Every model reads a recording as 16 kHz mono, so the copy is that: the recording's 16 kHz mono rendering from
/// `MonoAudioReader` (the downmix and resampler Nemotron 3 reads with, and Parakeet and Apple Speech read a recording
/// with several channels through), times the gain, as 16-bit PCM in a WAV file, about 115 MB an hour. Its length is
/// the rendering's, so every timing a model makes is the one it would make from the original. The level and the peak
/// are measured on that same rendering, so the gain keeps its loudest sample at −1 dBFS and 16 bits never clip; and
/// a 16-bit mono 16 kHz WAV is what FluidAudio maps in place without converting it again (Parakeet over 30 s,
/// Community-1).
///
/// It's the conversation's audio, so it's made where processing keeps such copies (`ProcessingScratch`: kept out of
/// backups, the temporary folder's file protection) and removed when the work ends, however it ends (`remove()`). The
/// stored recording is only read.
struct LevelledAudio: Sendable {
    /// What the models read.
    let url: URL
    /// What was measured and done; nil when the recording couldn't be measured or copied (the models then read it as is).
    let adjustment: LevelAdjustment?
    /// The copy made for the models, which `remove()` deletes.
    let copy: URL?

    /// Room the copy needs beyond its own size, so raising a level never takes the space a recording, a download, or
    /// sync needs.
    static let spareBytes: Int64 = 1_000_000_000
    private static let log = Logger(subsystem: "local.daybook", category: "Processing")

    /// The recording as it is, unmeasured.
    static func unchanged(_ url: URL) -> LevelledAudio { LevelledAudio(url: url, adjustment: nil, copy: nil) }

    func remove() {
        if let copy { try? FileManager.default.removeItem(at: copy) }
    }

    /// Measures `url` and, when the rule calls for a gain and the volume has room (`freeSpace`, bytes free where the copy
    /// goes; nil when unknown), writes the raised copy into `directory`'s processing scratch. A cancellation is passed
    /// on, any copy begun removed first; any other failure leaves the recording as it is, so levels never stop a
    /// recording from being processed.
    static func prepare(_ url: URL, policy: SpeechLevel.Policy = .standard,
                        in directory: URL = FileManager.default.temporaryDirectory,
                        freeSpace: (URL) -> Int64? = { ModelSpace.available(at: $0).free }) throws -> LevelledAudio {
        let adjustment: LevelAdjustment
        let frames: Int
        do {
            var meter = SpeechLevel.Meter(sampleRate: MonoAudioReader.sampleRate, policy: policy)
            frames = try MonoAudioReader.read(url: url) { meter.add($0) }
            adjustment = SpeechLevel.adjustment(for: meter.measurement(), policy: policy)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return unchanged(url)
        }
        guard adjustment.gain > 0 else { return LevelledAudio(url: url, adjustment: adjustment, copy: nil) }
        let needed = Int64(frames) * 2 + 65_536 + spareBytes
        if let free = freeSpace(ProcessingScratch.root(in: directory)), free < needed {
            log.notice("Input level left as recorded: \(free, privacy: .public) bytes free, \(needed, privacy: .public) needed")
            return unchanged(url)
        }
        var copy: URL?
        do {
            let destination = try ProcessingScratch.file(extension: "wav", in: directory)
            copy = destination
            try writeCopy(of: url, factor: adjustment.factor, to: destination)
            return LevelledAudio(url: destination, adjustment: adjustment, copy: destination)
        } catch {
            if let copy { try? FileManager.default.removeItem(at: copy) }
            if error is CancellationError { throw error }
            return unchanged(url)
        }
    }

    /// Writes `url`'s 16 kHz mono rendering times `factor` to `destination` as 16-bit PCM (a WAV file for a `.wav` name).
    static func writeCopy(of url: URL, factor: Float, to destination: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: MonoAudioReader.sampleRate, channels: 1, interleaved: false) else {
            throw LocalIntelligenceError.invalidAudio
        }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: MonoAudioReader.sampleRate,
                                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                                       AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        let output = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try MonoAudioReader.read(url: url) { samples in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
                throw LocalIntelligenceError.invalidAudio
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            let channel = buffer.floatChannelData![0]
            for index in samples.indices { channel[index] = samples[index] * factor }
            try output.write(from: buffer)
        }
    }
}
