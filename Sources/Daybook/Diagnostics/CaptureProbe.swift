import Accelerate
import AVFoundation
import Foundation

/// The peak level of each second of captured audio, from the first buffer on.
struct ProbeLevels {
    private(set) var peaks: [Float] = []
    private(set) var buffers = 0
    private(set) var frames = 0
    private var start: TimeInterval?

    /// Adds a buffer captured at `time` (host seconds). Only float audio is measured; anything else counts as frames.
    mutating func add(_ buffer: AVAudioPCMBuffer, at time: TimeInterval) {
        let origin = start ?? time
        start = origin
        buffers += 1
        frames += Int(buffer.frameLength)
        let second = max(0, Int(time - origin))
        while peaks.count <= second { peaks.append(0) }
        peaks[second] = max(peaks[second], Self.peak(buffer))
    }

    static func peak(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let count = buffer.format.isInterleaved ? Int(buffer.frameLength) * Int(buffer.format.channelCount) : Int(buffer.frameLength)
        let lanes = buffer.format.isInterleaved ? 1 : Int(buffer.format.channelCount)
        var peak: Float = 0
        for lane in 0..<lanes {
            var value: Float = 0
            vDSP_maxmgv(channels[lane], 1, &value, vDSP_Length(count))
            peak = max(peak, value)
        }
        return peak
    }
}

/// What `--capture-probe` found, written as JSON.
struct CaptureProbeReport: Codable {
    var bundleID: String
    var sandboxed: Bool
    var startedAt: Date
    var requestedSeconds: Int
    var capturedBundleIDs: [String] = []
    var buffers = 0
    var frames = 0
    /// Each second's peak level (0…1, linear).
    var peaks: [Float] = []
    var maxPeak: Float = 0
    /// Some audio wasn't digital silence: the tap works, and the permission is on.
    var heardSignal = false
    var events: [String] = []
    var error: String?
}

#if DEBUG
/// `Daybook --capture-probe <bundle ID> [--seconds 10] [--output <json>]`: runs only the process tap on the app with
/// that bundle ID for a few seconds, records nothing, and reports each second's peak level. It answers whether process
/// taps work in the App Sandbox (docs/sandbox.md); run it from the sandboxed ad hoc build while that app plays sound.
/// macOS asks for System Audio Recording the first time. Exit status: 0 when audio was heard, 1 when the tap stayed
/// silent (the permission is off, or the app played nothing), 2 when the tap couldn't start.
@MainActor
enum CaptureProbe {
    static func run(arguments: [String]) async -> Int32 {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let bundleID = value("--capture-probe"), !bundleID.hasPrefix("-") else {
            print("Usage: Daybook --capture-probe <bundle ID> [--seconds 10] [--output <json>]")
            return 2
        }
        let seconds = max(1, min(600, Int(value("--seconds") ?? "") ?? 10))
        let output = value("--output").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("daybook-capture-probe.json")
        var report = CaptureProbeReport(bundleID: bundleID, sandboxed: SandboxEnvironment.isSandboxed, startedAt: Date(), requestedSeconds: seconds)
        let recorder = ProbeRecorder()
        let source = ProcessTapSource(target: CallAppTarget(bundleID: bundleID, displayName: bundleID, isBrowser: false))
        do {
            try await source.start(onBuffer: { buffer, time in recorder.add(buffer, at: time) },
                                   onEvent: { event in recorder.note(event) })
            print("Listening to \(bundleID) for \(seconds) s…")
            try? await Task.sleep(for: .seconds(seconds))
            await source.stop()
            report.capturedBundleIDs = source.capturedBundleIDs
        } catch {
            report.error = error.localizedDescription
        }
        let levels = recorder.levels
        report.buffers = levels.buffers; report.frames = levels.frames; report.peaks = levels.peaks
        report.maxPeak = levels.peaks.max() ?? 0
        report.heardSignal = report.maxPeak > 0
        report.events = recorder.events
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        do { try encoder.encode(report).write(to: output, options: .atomic) }
        catch { print("Couldn’t write \(output.path): \(error.localizedDescription)") }
        let summary = report.error.map { "Tap failed: \($0)" }
            ?? "\(report.buffers) buffers, peak \(String(format: "%.4f", report.maxPeak)), \(report.heardSignal ? "audio heard" : "silent")"
        print("\(summary) (sandboxed: \(report.sandboxed)). Report: \(output.path)")
        if report.error != nil { return 2 }
        return report.heardSignal ? 0 : 1
    }
}

/// Collects levels from the tap's IO queue.
private final class ProbeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = ProbeLevels()
    private var notes: [String] = []
    var levels: ProbeLevels { lock.withLock { stored } }
    var events: [String] { lock.withLock { notes } }
    func add(_ buffer: AVAudioPCMBuffer, at time: TimeInterval) { lock.withLock { stored.add(buffer, at: time) } }
    func note(_ event: CaptureSourceEvent) {
        let text: String
        switch event {
        case .failed(let error): text = "failed: \(error.localizedDescription)"
        case .deviceChanged(let reason): text = "device changed: \(reason)"
        }
        lock.withLock { notes.append(text) }
    }
}
#endif
