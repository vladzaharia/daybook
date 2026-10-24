import AVFoundation
import DaybookCaptions
import Foundation

/// Live captions of a recorder's live audio (Listen Live), from the shared DaybookCaptions engine:
/// tentative feedback that the audio is arriving, never the transcript. Shared by reference, so
/// the app can point it at its own settings after the devices exist.
@MainActor
public final class LiveCaptionHooks {
    /// Makes the captioner for one Listen Live; nil means no captions. By default, the Speech
    /// framework where it exists (macOS 26, iOS 26), never downloading a language: captions run when
    /// the system already has it (the iPhone's recording captions or the Mac's fetch it).
    public var makeCaptioner: () -> (any LiveCaptioning)? = { LiveCaptionHooks.speechCaptioner(allowsDownload: false) }
    /// The captions' language.
    public var locale: () -> Locale = { .current }

    public init() {}

    /// A recorder's live audio arrives as one decoded 20 ms packet at a time, in bursts: what it
    /// recorded before listening began, then as it records. About a minute of packets may wait for
    /// the recognizer; past that the oldest are dropped (the audio itself is always saved).
    public static let backlog = 3_000

    /// The Speech framework's captioner for live audio, or nil before macOS 26 and iOS 26. Captions
    /// count from the first sample of the live audio, whatever was dropped while it started.
    public static func speechCaptioner(allowsDownload: Bool, asksForAuthorization: Bool = false) -> (any LiveCaptioning)? {
        guard #available(macOS 26, iOS 26, *) else { return nil }
        return SpeechCaptioner(allowsDownload: allowsDownload, asksForAuthorization: asksForAuthorization,
                               backlog: backlog, timelineOrigin: 0)
    }
}
