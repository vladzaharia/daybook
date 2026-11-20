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
/// backups), in a folder of its own with the recording's file protection class where that can be read and set (an
/// iPhone's recording is class B), and removed with that folder when the work ends, however it ends (`remove()`). The
/// stored recording is only read.
struct LevelledAudio: Sendable {
    /// What the models read.
    let url: URL
    /// What was measured and done; nil when the recording couldn't be measured or copied (the models then read it as is).
    let adjustment: LevelAdjustment?
    /// The copy made for the models, which `remove()` deletes with the folder made for it.
    let copy: URL?

    /// Room the copy needs beyond its own size, so raising a level never takes the space a recording, a download, or
    /// sync needs.
    static let spareBytes: Int64 = 1_000_000_000
    /// The largest copy made, bytes: a WAV file holds at most 4,294,967,295, and this leaves room for its header. At
    /// 32,000 bytes a second it's about 34 hours of audio; a longer recording is heard as stored.
    static let maximumCopyBytes: Int64 = 4_000_000_000
    private static let log = Logger(subsystem: "local.daybook", category: "Processing")

    /// The recording as it is, unmeasured.
    static func unchanged(_ url: URL) -> LevelledAudio { LevelledAudio(url: url, adjustment: nil, copy: nil) }

    func remove() {
        if let copy { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
    }

    /// Why a copy the rule calls for isn't made.
    enum Declined: String, Equatable {
        /// Over `maximumCopyBytes`.
        case tooLong = "too long for a copy"
        /// Less free than the copy and `spareBytes` (`free`: bytes free where it would go; nil when unknown, which stops nothing).
        case noRoom = "no room for a copy"
    }

    /// Whether a copy of `frames` 16-bit samples is declined, and why.
    static func declined(frames: Int, free: Int64?) -> Declined? {
        let bytes = Int64(frames) * 2 + 65_536
        if bytes > maximumCopyBytes { return .tooLong }
        if let free, free < bytes + spareBytes { return .noRoom }
        return nil
    }

    /// The recording's file protection class, when it can be read and is one a folder can be given.
    static func protection(of url: URL) -> FileProtectionType? {
        var url = url
        url.removeAllCachedResourceValues()   // read now, not as an earlier look at this URL found it
        guard let value = (try? url.resourceValues(forKeys: [.fileProtectionKey]))?.fileProtection else { return nil }
        switch value {
        case .complete: return .complete
        case .completeUnlessOpen: return .completeUnlessOpen
        case .completeUntilFirstUserAuthentication: return .completeUntilFirstUserAuthentication
        case URLFileProtection.none: return FileProtectionType.none
        default: return nil
        }
    }

    /// Measures `url` and, when the rule calls for a gain and the copy isn't declined (`declined(frames:free:)`;
    /// `freeSpace` is asked about the scratch folder), writes the raised copy into `directory`'s processing scratch. A
    /// declined copy leaves the recording as it is, with its level and peak recorded and a gain of 0, and says why in the
    /// log. A cancellation is passed on, any copy begun removed first; any other failure leaves the recording as it is,
    /// unrecorded, so levels never stop a recording from being processed.
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
        let free = freeSpace(ProcessingScratch.root(in: directory))
        if let reason = declined(frames: frames, free: free) {
            log.notice("Input level left as recorded, \(reason.rawValue, privacy: .public): \(frames, privacy: .public) samples, \(free ?? -1, privacy: .public) bytes free")
            return LevelledAudio(url: url, adjustment: LevelAdjustment(speechLevel: adjustment.speechLevel, peak: adjustment.peak, gain: 0), copy: nil)
        }
        var folder: URL?
        do {
            let made = try ProcessingScratch.folder(protection: protection(of: url), in: directory)
            folder = made
            let destination = made.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
            try writeCopy(of: url, factor: adjustment.factor, to: destination)
            return LevelledAudio(url: destination, adjustment: adjustment, copy: destination)
        } catch {
            if let folder { try? FileManager.default.removeItem(at: folder) }
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
