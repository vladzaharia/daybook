import AVFoundation
import Foundation

/// One transfer's audio, decrypted, decoded, and written in arrival order on a queue of its own, off the main actor:
/// Wi‑Fi Fast Transfer delivers hundreds of 20 ms packets at once, and the main actor draws the page. What it decodes,
/// and whatever goes wrong, comes back on the main actor. A live transfer's writer is lenient: a packet that doesn't
/// decode becomes 20 ms of silence, so what follows keeps its time; any other transfer fails on it.
final class SoundcoreAudioWriter: @unchecked Sendable {
    /// What the finished file holds.
    struct Written: Equatable {
        /// Samples written, at 16 kHz.
        let samples: Int64
        /// What the packets appended (silence included) should have decoded to: 320 samples each.
        let expectedSamples: Int64
        /// Packets that didn't decode and became silence (live audio only).
        let concealed: Int
    }

    let url: URL
    private let queue = DispatchQueue(label: "local.daybook.soundcore.audio", qos: .userInitiated)
    private let lenient: Bool
    private let onFailure: @MainActor (Error) -> Void
    /// The rest is touched only on `queue`.
    private var decoder: SoundcoreOpusDecoder?
    private var failure: Error?
    private var concealed = 0

    /// `onPCM` gets each decoded buffer on the main actor, in order; `onFailure` once, when a packet can't be decrypted
    /// or decoded (never for a lenient writer's).
    init(url: URL, lenient: Bool, onPCM: (@MainActor (AVAudioPCMBuffer) -> Void)?, onFailure: @escaping @MainActor (Error) -> Void) throws {
        self.url = url
        self.lenient = lenient
        self.onFailure = onFailure
        let decoder = try SoundcoreOpusDecoder(outputURL: url)
        if let onPCM {
            decoder.onPCM = { buffer in
                DispatchQueue.main.async { MainActor.assumeIsolated { onPCM(buffer) } }
            }
        }
        self.decoder = decoder
    }

    /// Decrypts and decodes one slice after those before it.
    func append(_ slice: SoundcoreAudioSlice, key: SoundcoreFileKey) {
        queue.async { [self] in
            guard let decoder, failure == nil else { return }
            do {
                try decoder.append(key.decrypt(slice))
            } catch {
                if lenient, (try? decoder.appendSilence(packets: 1)) != nil {
                    concealed += 1
                } else {
                    fail(error)
                }
            }
        }
    }

    /// `packets` × 20 ms of silence after what came before: live audio the stream lost.
    func appendSilence(packets: Int) {
        queue.async { [self] in
            guard let decoder, failure == nil else { return }
            do { try decoder.appendSilence(packets: packets) } catch { fail(error) }
        }
    }

    /// Writes what the decoder still holds and closes the file, once everything appended before has been written.
    func finish() async throws -> Written {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Written, Error>) in
            queue.async { [self] in
                do {
                    if let failure { throw failure }
                    guard let decoder else { throw SoundcoreError.corruptAudio }
                    try decoder.finish()
                    self.decoder = nil
                    continuation.resume(returning: Written(samples: decoder.sampleCount, expectedSamples: decoder.expectedSampleCount,
                                                           concealed: concealed))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// The transfer failed or was stopped: nothing more is written, and the partial file goes once what's queued has run.
    func discard() {
        queue.async { [self] in
            decoder = nil
            if failure == nil { failure = CancellationError() }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// On `queue`.
    private func fail(_ error: Error) {
        failure = error
        decoder = nil
        let report = onFailure
        DispatchQueue.main.async { MainActor.assumeIsolated { report(error) } }
    }
}
