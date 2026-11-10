import DaybookCaptions
import DaybookCore
import Foundation

/// The captions of recorders recording along with a shared recording, from the live audio each saves
/// into it (`DeviceSession.captureLive`, captioned as Listen Live is): each recorder's whole caption
/// list as it changes, with its name and where its live stream starts (the captions count from there),
/// so the recording's own captions can show its lines beside theirs (docs/capture.md, "Live captions").
@MainActor
public final class LiveCaptureCaptions {
    public struct Update: Equatable, Sendable {
        /// The session's ID, stable for the recording.
        public var recorderID: String
        /// The kind's short name ("Soundcore"), which labels lines no person was recognized in.
        public var name: String
        /// Where the recorder's live stream starts, on this device's clock (`DeviceSession.liveStreamStartedAt`): its
        /// captions count from there. Not its recording's start: a stream that begins now, for a recorder already
        /// recording (or joined by its button), would otherwise be placed early. Nil before its audio arrives.
        public var startedAt: Date?
        public var segments: [LiveCaptionSegment]

        public init(recorderID: String, name: String, startedAt: Date?, segments: [LiveCaptionSegment]) {
            self.recorderID = recorderID; self.name = name; self.startedAt = startedAt; self.segments = segments
        }
    }

    private var hub: ObservationWatch?
    private var sessions: [String: ObservationWatch] = [:]

    public init() {}

    /// Follows `hub`'s recorders: whenever one capturing into `conversation()` has new captions,
    /// `deliver` gets them.
    public func follow(_ hub: DeviceHub, conversation: @escaping () -> UUID?, deliver: @escaping (Update) -> Void) {
        follow({ hub.sessions }, conversation: conversation, deliver: deliver)
    }

    /// The same, for any list of sessions as it changes, read from `@Observable` models (tests).
    public func follow(_ sessions: @escaping @MainActor () -> [DeviceSession], conversation: @escaping () -> UUID?,
                       deliver: @escaping (Update) -> Void) {
        hub = ObservationWatch.values(of: sessions) { [weak self] sessions in
            guard let self else { return }
            let ids = Set(sessions.map(\.id))
            self.sessions = self.sessions.filter { ids.contains($0.key) }
            for session in sessions where self.sessions[session.id] == nil {
                self.sessions[session.id] = ObservationWatch.distinctValues(of: { [weak session] in session?.liveCaptions ?? [] }) {
                    [weak session] segments in
                    guard let session, let id = conversation(), session.liveCaptureConversation == id else { return }
                    deliver(Update(recorderID: session.id, name: session.kind.shortName,
                                   startedAt: session.liveStreamStartedAt, segments: segments))
                }
            }
        }
    }
}
