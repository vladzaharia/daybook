import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Receives copied PCM buffers with the host time of their first frame, on any thread.
typealias CaptureBufferHandler = @Sendable (AVAudioPCMBuffer, TimeInterval) -> Void

enum CaptureSourceEvent {
    /// The source stopped delivering audio.
    case failed(Error)
    /// The source continued on a different device or format; the next buffer starts a new clock segment.
    case deviceChanged(String)
}
typealias CaptureEventHandler = @Sendable (CaptureSourceEvent) -> Void

/// One live audio input: the microphone, a process tap, or ScreenCaptureKit.
protocol CaptureAudioSource: AnyObject {
    /// `microphone`, `process-tap`, or `screen-capture-kit`.
    var method: String { get }
    func start(onBuffer: @escaping CaptureBufferHandler, onEvent: @escaping CaptureEventHandler) async throws
    /// Stops delivery; when it returns no further buffers arrive.
    func stop() async
}

/// Creates call-audio sources. The live implementation talks to Core Audio and ScreenCaptureKit;
/// tests inject fakes, so no permission prompt or capture happens under test.
protocol SystemAudioProviding {
    /// Process taps exist from macOS 14.2. Daybook requires macOS 15, so the live value is true;
    /// the flag keeps the fallback testable.
    var supportsProcessTaps: Bool { get }
    /// A tap on the call app and its helper processes, excluding Daybook.
    func makeProcessTap(for target: CallAppTarget) throws -> CaptureAudioSource
    /// All Mac playback except Daybook. May show the Screen & System Audio Recording prompt.
    func makeScreenCapture() async throws -> CaptureAudioSource
    /// True when ScreenCaptureKit is already authorized, so switching to it mid-call shows no prompt.
    var screenCaptureAuthorized: Bool { get }
}

enum SystemAudioSelector {
    /// Starts the best available call-audio path: a process tap on the known call app, otherwise
    /// ScreenCaptureKit. A tap that fails to start never costs the recording; the reason is kept.
    static func start(target: CallAppTarget?, provider: SystemAudioProviding,
                      onBuffer: @escaping CaptureBufferHandler, onEvent: @escaping CaptureEventHandler)
    async throws -> (source: CaptureAudioSource, info: SystemAudioCaptureInfo) {
        var fallbackReason: String
        var fallbackDetail: String?
        if let target {
            if provider.supportsProcessTaps {
                var tap: CaptureAudioSource?
                do {
                    let created = try provider.makeProcessTap(for: target)
                    tap = created
                    try await created.start(onBuffer: onBuffer, onEvent: onEvent)
                    let apps = (created as? ProcessTapReporting)?.capturedBundleIDs ?? [target.bundleID]
                    return (created, SystemAudioCaptureInfo(method: .processTap, capturedApps: apps))
                } catch {
                    if let tap { await tap.stop() }
                    fallbackReason = "Couldn’t record \(target.displayName) on its own, so all Mac audio is recorded."
                    fallbackDetail = error.localizedDescription
                }
            } else {
                fallbackReason = "Recording only the call app needs macOS 14.2 or later, so all Mac audio is recorded."
            }
        } else {
            fallbackReason = "No call app was identified, so all Mac audio is recorded."
        }
        let screen = try await provider.makeScreenCapture()
        try await screen.start(onBuffer: onBuffer, onEvent: onEvent)
        return (screen, SystemAudioCaptureInfo(method: .screenCaptureKit, fallbackReason: fallbackReason, fallbackDetail: fallbackDetail))
    }
}

/// Sources that can say which apps they recorded.
protocol ProcessTapReporting {
    var capturedBundleIDs: [String] { get }
}

struct LiveSystemAudioProvider: SystemAudioProviding {
    /// The package's minimum is macOS 15, which always has process taps (added in 14.2).
    var supportsProcessTaps: Bool { true }

    func makeProcessTap(for target: CallAppTarget) throws -> CaptureAudioSource {
        ProcessTapSource(target: target)
    }

    /// Checks without prompting.
    var screenCaptureAuthorized: Bool { CGPreflightScreenCaptureAccess() }

    func makeScreenCapture() async throws -> CaptureAudioSource {
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) }
        catch {
            throw RecordingError.interrupted("System audio is unavailable. Allow Daybook in System Settings › Privacy & Security › Screen & System Audio Recording.")
        }
        guard let display = content.displays.first else { throw RecordingError.noDisplay }
        return ScreenCaptureAudioSource(filter: SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []))
    }
}

/// System audio through ScreenCaptureKit. No video output is registered and no screen images are
/// stored; the stream still needs a display filter and Screen & System Audio Recording permission.
final class ScreenCaptureAudioSource: NSObject, CaptureAudioSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let method = "screen-capture-kit"
    let queue = DispatchQueue(label: "app.daybook.system-audio", qos: .userInitiated)
    private let filter: SCContentFilter
    private var stream: SCStream?
    private var onBuffer: CaptureBufferHandler?
    private var onEvent: CaptureEventHandler?

    init(filter: SCContentFilter) { self.filter = filter }

    func start(onBuffer: @escaping CaptureBufferHandler, onEvent: @escaping CaptureEventHandler) async throws {
        self.onBuffer = onBuffer
        self.onEvent = onEvent
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        self.stream = stream
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
    }

    func stop() async {
        if let stream {
            do { try await stream.stopCapture() }
            catch { onEvent?(.failed(error)) }
        }
        stream = nil
        // Drain callbacks already queued before the writer closes.
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        onBuffer = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer),
              let description = sampleBuffer.formatDescription,
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: streamDescription) else { return }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, frames <= Int(Int32.max),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        guard status == noErr else {
            onEvent?(.failed(NSError(domain: NSOSStatusErrorDomain, code: Int(status))))
            return
        }
        onBuffer?(buffer, CMTimeGetSeconds(sampleBuffer.presentationTimeStamp))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onEvent?(.failed(error)) }
}
