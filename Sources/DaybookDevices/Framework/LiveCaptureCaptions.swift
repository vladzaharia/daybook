import Combine
import DaybookCaptions
import Foundation

/// The captions of recorders recording along with a shared recording, from the live audio each saves
/// into it (`DeviceSession.captureLive`, captioned as Listen Live is): each recorder's whole caption
/// list as it changes, with its name and when its recording began (its live audio starts there), so
/// the recording's own captions can show its lines beside theirs (docs/capture.md, "Live captions").
@MainActor
public final class LiveCaptureCaptions {
    public struct Update: Equatable, Sendable {
        /// The session's ID, stable for the recording.
        public var recorderID: String
        /// The kind's short name ("Soundcore"), which labels lines no person was recognized in.
        public var name: String
        /// When the recorder's recording began, on this device's clock, when it says.
        public var startedAt: Date?
        public var segments: [LiveCaptionSegment]

        public init(recorderID: String, name: String, startedAt: Date?, segments: [LiveCaptionSegment]) {
            self.recorderID = recorderID; self.name = name; self.startedAt = startedAt; self.segments = segments
        }
    }

    private var hub: AnyCancellable?
    private var sessions: [String: AnyCancellable] = [:]

    public init() {}

    /// Follows `hub`'s recorders: whenever one capturing into `conversation()` has new captions,
    /// `deliver` gets them.
    public func follow(_ hub: DeviceHub, conversation: @escaping () -> UUID?, deliver: @escaping (Update) -> Void) {
        follow(hub.$sessions, conversation: conversation, deliver: deliver)
    }

    /// The same, for any list of sessions as it changes (tests).
    public func follow(_ sessions: some Publisher<[DeviceSession], Never>, conversation: @escaping () -> UUID?,
                       deliver: @escaping (Update) -> Void) {
        hub = sessions.sink { [weak self] sessions in
            guard let self else { return }
            let ids = Set(sessions.map(\.id))
            self.sessions = self.sessions.filter { ids.contains($0.key) }
            for session in sessions where self.sessions[session.id] == nil {
                self.sessions[session.id] = session.$liveCaptions.sink { [weak session] segments in
                    guard let session, let id = conversation(), session.liveCaptureConversation == id else { return }
                    deliver(Update(recorderID: session.id, name: session.kind.shortName,
                                   startedAt: session.status?.recordingStartedAt, segments: segments))
                }
            }
        }
    }
}
