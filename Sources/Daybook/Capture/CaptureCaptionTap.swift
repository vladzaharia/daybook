import AVFoundation
import Foundation

/// Where a recording's live audio is copied for captions, one handler per source: You (the
/// microphone) and Call (the call or system track). The recorder calls them on capture threads with
/// the same buffers its writers get, which are copies no one modifies.
///
/// Captions never affect capture: a handler only hands the buffer on (`LiveCaptioning.append` is
/// cheap and drops audio when the recognizer falls behind), it can't fail, and nothing waits on it.
struct CaptureCaptionTap: Sendable {
    var microphone: CaptureBufferHandler?
    var call: CaptureBufferHandler?

    /// The same handlers, given seconds since the recording started instead of host time, so both
    /// sources' captions share the recording's timeline.
    func onSessionTimeline(from origin: TimeInterval) -> CaptureCaptionTap {
        CaptureCaptionTap(microphone: Self.shift(microphone, by: origin), call: Self.shift(call, by: origin))
    }

    private static func shift(_ handler: CaptureBufferHandler?, by origin: TimeInterval) -> CaptureBufferHandler? {
        guard let handler else { return nil }
        return { @Sendable buffer, host in handler(buffer, host - origin) }
    }
}
