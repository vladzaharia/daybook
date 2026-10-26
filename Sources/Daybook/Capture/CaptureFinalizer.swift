import DaybookCore
import Foundation

/// Prepares a finished capture for transcription: removes the call's echo from the microphone
/// using the recorded call track as the reference, and writes the result as a derived track.
///
/// The captured originals are opened read-only and never modified. The outcome (applied, skipped
/// with a reason, or failed) is saved in `capture-result.json`, so running this again (for example
/// during crash recovery) reuses the existing result instead of recomputing it.
enum CaptureFinalizer {
    static let echoCancelledFileName = "microphone.echo-cancelled.caf"

    static func finalize(_ result: CaptureResult, configuration: EchoRemovalConfiguration = .init(),
                         isCancelled: () -> Bool = { false }) -> CaptureResult {
        var result = result
        let derivedURL = result.directory.appendingPathComponent(echoCancelledFileName)
        if let report = result.echoRemoval {
            // Already finalized. Keep it if the derived audio it describes is still there.
            if report.outcome != .applied || FileManager.default.fileExists(atPath: derivedURL.path) { return result }
            result.derivedTracks = nil
        }
        guard let microphone = result.tracks.first(where: { $0.role == .microphone }), microphone.frameCount > 0 else { return result }
        let report: EchoRemovalReport
        if let call = result.tracks.first(where: { $0.role == .systemAudio }), call.frameCount > 0 {
            report = removeEcho(microphone: microphone, call: call, headphones: result.outputRouteSummary == .headphones,
                                output: derivedURL, configuration: configuration, isCancelled: isCancelled)
        } else {
            report = .skipped(.noCallTrack)
        }
        result.echoRemoval = report
        if report.outcome == .applied, let derived = derivedTrack(at: derivedURL, from: microphone, sampleRate: configuration.processingRate) {
            result.derivedTracks = [derived]
        } else {
            result.derivedTracks = nil
        }
        if report.outcome == .failed, report.detail != nil {
            // The detail stays in the echo removal report, which the capture details show.
            result.warnings = Array(Set(result.warnings + ["Echo removal failed, so the original microphone recording is transcribed."])).sorted()
        }
        // Best effort: the in-memory result is still used if metadata can't be written.
        try? CaptureJSON.persist(result, at: result.directory.appendingPathComponent("capture-result.json"))
        return result
    }

    private static func removeEcho(microphone: CapturedAudioTrack, call: CapturedAudioTrack, headphones: Bool, output: URL,
                                   configuration: EchoRemovalConfiguration, isCancelled: () -> Bool) -> EchoRemovalReport {
        // AVAudioFile picks the container from the extension, so the partial file keeps `.caf`.
        let temporary = output.deletingLastPathComponent()
            .appendingPathComponent(".\(output.deletingPathExtension().lastPathComponent).partial.caf")
        try? FileManager.default.removeItem(at: temporary)
        do {
            let micSource = try AudioFileSampleSource(url: microphone.url)
            let callSource = try AudioFileSampleSource(url: call.url)
            var report: EchoRemovalReport
            do {
                let sink = try AudioFileSampleSink(url: temporary, sampleRate: configuration.processingRate)
                report = try EchoRemover.run(microphone: micSource, microphoneClock: microphone.clock,
                                             call: callSource, callClock: call.clock, sink: sink,
                                             configuration: configuration, isCancelled: isCancelled)
            }
            if report.outcome == .skipped && report.skipReason == .noEchoDetected && headphones {
                report.skipReason = .headphones
                report.detail = EchoRemovalSkipReason.headphones.explanation
            } else if report.outcome == .applied && headphones {
                report.detail = "Headphones were reported, but the call was audible in the microphone, so its echo was removed."
            }
            if report.outcome == .applied {
                try? FileManager.default.removeItem(at: output)
                try FileManager.default.moveItem(at: temporary, to: output)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
            } else {
                try? FileManager.default.removeItem(at: temporary)
            }
            return report
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return .failed(error is CancellationError ? "Echo removal was canceled." : error.localizedDescription)
        }
    }

    private static func derivedTrack(at url: URL, from microphone: CapturedAudioTrack, sampleRate: Double) -> DerivedCaptureTrack? {
        guard let source = try? AudioFileSampleSource(url: url), source.frameCount > 0 else { return nil }
        // The cleaned track starts at the microphone's first sample on the drift-corrected timeline.
        let offset = microphone.clock.time(atFrame: 0)
        return DerivedCaptureTrack(url: url, derivedFrom: .microphone, processing: RecordingTrack.echoCancelledProcessing,
                                   offsetSeconds: offset, startedAt: microphone.startedAt.addingTimeInterval(offset - microphone.offsetSeconds),
                                   sampleRate: sampleRate, frameCount: source.frameCount)
    }

    /// What to store on each library track made from this capture.
    static func details(for track: CapturedAudioTrack, in result: CaptureResult) -> TrackCaptureDetails {
        var details = TrackCaptureDetails(method: track.method ?? (track.role == .microphone ? "microphone" : result.systemAudio?.method.rawValue),
                                          clockRate: track.clockAnchors == nil ? nil : track.clock.rate,
                                          outputRoute: result.outputRouteSummary?.rawValue, notes: track.notes)
        if track.role == .systemAudio, let info = result.systemAudio {
            details.method = info.method.rawValue
            details.capturedApps = info.capturedApps
            details.fallbackReason = info.fallbackReason
        }
        if track.role == .microphone { details.echoRemoval = result.echoRemoval }
        return details
    }

    static func details(for derived: DerivedCaptureTrack, in result: CaptureResult) -> TrackCaptureDetails {
        TrackCaptureDetails(method: derived.processing, clockRate: 1, outputRoute: result.outputRouteSummary?.rawValue,
                            echoRemoval: result.echoRemoval)
    }
}
