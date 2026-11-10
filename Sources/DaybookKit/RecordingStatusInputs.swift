import DaybookCore
import Foundation

// The facts a recording's status is worded from, on both apps: the phase, the input, the call, the room left, and the
// devices that can record along. DaybookUI's `RecordingStatusWords` words them; the status overview lists the same
// recorders and peers (`StatusOverviewInputs`).

/// The facts a recording's status is worded from.
public struct RecordingStatusInputs: Equatable {
    public enum Phase: Equatable, Sendable {
        case idle, starting, recording, paused, saving
        /// After a Stop seen on this surface.
        case saved
        /// The recording ended short: nothing reached the conversation, or the capture stopped on its own.
        case stopped
    }

    /// The call track, while recording (the Mac).
    public enum CallAudio: Equatable, Sendable {
        /// Computer audio isn't part of this recording (turned off in Settings).
        case off
        /// Captured, but silent for the last few seconds.
        case quiet
        case detected
        /// It should be captured and isn't.
        case missing
    }

    /// Another Daybook that can record along: a paired iPhone seen from a Mac, a Mac seen from an iPhone.
    public struct Peer: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case iPhone, mac }
        public enum Activity: Equatable, Sendable { case idle, recording, paused }

        public var id: String
        public var name: String
        public var kind: Kind
        public var isConnected: Bool
        public var activity: Activity
        /// Its link to this recording (multipoint): recording along, or leading it.
        public var along: CompanionRecording.State?
        public var lastConnected: Date?
        /// Its levels reach this device (an iPhone's, over the link to a Mac), so it gets a meter.
        public var hasMeter: Bool
        /// It leads this recording and hasn't been heard from for a while; this device keeps recording (`LeaderWatch`).
        public var outOfReach: Bool

        public init(id: String, name: String, kind: Kind, isConnected: Bool = false, activity: Activity = .idle,
                    along: CompanionRecording.State? = nil, lastConnected: Date? = nil, hasMeter: Bool? = nil, outOfReach: Bool = false) {
            self.id = id; self.name = name; self.kind = kind; self.isConnected = isConnected; self.activity = activity
            self.along = along; self.lastConnected = lastConnected; self.hasMeter = hasMeter ?? (kind == .iPhone)
            self.outOfReach = outOfReach
        }

        /// Its glyph, and what a narrow chip calls it.
        public var symbol: String { kind == .iPhone ? "iphone" : "desktopcomputer" }
        public var shortName: String { kind == .iPhone ? "iPhone" : "Mac" }
    }

    public var phase: Phase = .idle
    /// The conversation's length, once saved.
    public var duration: TimeInterval?
    /// Saving, a recording stopped while the iPhone was locked waits for it to be unlocked to be finished: it's saved.
    public var waitsForUnlock = false
    /// What it records from: "MacBook Pro Microphone".
    public var inputDevice: String?
    /// The input can be changed where the phase is drawn (Floating Notes' input menu, the iPhone's input picker), so
    /// the phase says so: "MacBook Pro Microphone ▾".
    public var choosesInput = false
    public var microphoneSilent = false
    /// Computer audio is part of this recording (Settings › General), so it has a Call meter.
    public var includesCall = false
    public var call: CallAudio = .off
    /// Seconds of recording the disk still has room for, once that's under half an hour (the Mac); nil above.
    public var spaceLeft: TimeInterval?
    /// Call audio stopped to leave the disk's last minutes to the microphone (the Mac).
    public var callStoppedForSpace = false
    public var recorders: [RecorderFacts] = []
    public var peers: [Peer] = []
    /// How this device calls itself in a sentence: "this Mac", "this iPhone".
    public var here = "this Mac"

    public init() {}
}

extension PeerFacts {
    /// Another Daybook that can record along, as its status line words it (`PeerStatusWords`).
    public init(_ peer: RecordingStatusInputs.Peer) {
        let activity: Activity
        switch peer.activity {
        case .idle: activity = .idle
        case .recording: activity = .recording
        case .paused: activity = .paused
        }
        self.init(id: peer.id, name: peer.name, kind: peer.kind == .iPhone ? .iPhone : .mac, isConnected: peer.isConnected,
                  activity: activity, lastSeen: peer.lastConnected)
    }
}
