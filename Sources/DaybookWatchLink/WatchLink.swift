import Foundation

// What Daybook on iPhone and Daybook on Apple Watch say to each other over WatchConnectivity (docs/watch.md).
// Plain values only (Foundation), so the watch app, the iPhone app, and the package's tests on the Mac read the
// same definitions. The iPhone manages the watch as one of its recorders (`daybook.watch`, DaybookDevices): it
// asks it to start and stop with its shared recording, and the watch's audio arrives as segments it imports into
// that conversation.

/// The protocol's constants.
public enum WatchLink {
    /// Bumped when a message changes in a way the other side can't read. Each side says which it speaks.
    public static let version = 1
    /// The key a WatchConnectivity dictionary carries its JSON under (messages, replies, user info, application
    /// context, and a file transfer's metadata).
    public static let payloadKey = "daybook"
    /// The key for the protocol version beside it.
    public static let versionKey = "v"
}

// MARK: - Messages

/// A message, sent with `WCSession.sendMessage` when the other side is reachable, or queued with `transferUserInfo`
/// when it must arrive eventually (a stop, a receipt).
public enum WatchMessage: Codable, Equatable, Sendable {
    // iPhone → watch

    /// Record along with the iPhone's shared recording. Answered with `.state` once the watch is recording, or
    /// `.refused`.
    case start(WatchStart)
    /// Stop recording: only `recordingID` when given, so a stop that arrives late never ends a newer recording.
    /// Answered with `.state`.
    case stop(WatchStop)
    /// What are you recording? Answered with `.state`.
    case status
    /// A clock sample: answered with `.clock`, the watch's time as it answered.
    case clock(phoneTime: Date)
    /// The segments of a recording the iPhone holds (`WatchReceipt`): what the watch counts as delivered, and, when it
    /// `requestsMissing`, a request to send again every segment it doesn't name. No answer.
    case received(WatchReceipt)

    // watch → iPhone

    /// What is the iPhone recording? Answered with `.context`.
    case context
    /// What the watch is recording changed, and why (`WatchState.change`). No answer.
    case state(WatchState)
}

/// An answer to a message sent with a reply handler.
public enum WatchReply: Codable, Equatable, Sendable {
    case state(WatchState)
    case context(PhoneContext)
    case clock(WatchClockSample)
    /// It couldn't do what was asked, in words for the person ("Open Daybook on your Apple Watch to record there.").
    case refused(String)
}

/// Record along with a shared recording, or on its own.
public struct WatchStart: Codable, Equatable, Sendable {
    /// The conversation the recording joins (the iPhone's, which the watch's segments carry back). Nil for a recording
    /// of the watch's own (Record on the watch's page on the iPhone, with nothing recording there): the watch records it
    /// without a conversation, as if started on the wrist, and the iPhone's context never stops it.
    public var conversationID: UUID?
    public var title: String?
    /// When the shared recording started, on the iPhone's clock.
    public var startedAt: Date?

    public init(conversationID: UUID?, title: String? = nil, startedAt: Date? = nil) {
        self.conversationID = conversationID
        self.title = title
        self.startedAt = startedAt
    }
}

/// Stop recording.
public struct WatchStop: Codable, Equatable, Sendable {
    /// Only this recording. Nil stops whatever the watch is recording.
    public var recordingID: String?
    /// Only a recording made for this conversation. Nil for any.
    public var conversationID: UUID?

    public init(recordingID: String? = nil, conversationID: UUID? = nil) {
        self.recordingID = recordingID
        self.conversationID = conversationID
    }
}

/// The segments of one recording the iPhone holds. A segment is delivered only once a receipt names it: a finished
/// transfer isn't proof the iPhone kept the file. The iPhone sends one after storing each segment (which asks for
/// nothing: later segments may simply not have arrived yet), and, for a finished recording still missing segments, one
/// that `requestsMissing` (at launch, on a refresh, when the watch comes within reach; at most once a minute). Only that
/// one makes the watch send again what it doesn't name, and not a segment it's sending now or whose transfer finished
/// moments ago (the file may still be on its way to the iPhone's handler). The watch deletes nothing until `imported`.
public struct WatchReceipt: Codable, Equatable, Sendable {
    public var recordingID: String
    /// Every segment of the recording the iPhone holds now, by index.
    public var segments: [Int]
    /// The whole recording is in the iPhone's library: the watch forgets it.
    public var imported: Bool
    /// The recording is finished and the iPhone still lacks segments: send again every one this doesn't name.
    public var requestsMissing: Bool

    public init(recordingID: String, segments: [Int], imported: Bool = false, requestsMissing: Bool = false) {
        self.recordingID = recordingID
        self.segments = segments
        self.imported = imported
        self.requestsMissing = requestsMissing
    }

    private enum CodingKeys: String, CodingKey { case recordingID, segments, imported, requestsMissing }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recordingID = try container.decode(String.self, forKey: .recordingID)
        segments = try container.decode([Int].self, forKey: .segments)
        imported = (try? container.decodeIfPresent(Bool.self, forKey: .imported)) ?? false
        requestsMissing = (try? container.decodeIfPresent(Bool.self, forKey: .requestsMissing)) ?? false
    }
}

// MARK: - State

/// What the iPhone tells the watch: its shared recording and whether the watch records along. Sent as the
/// application context whenever it changes (the latest one waits for the watch app), and as the answer to
/// `.context`, stamped when it's sent (`sentAt`). The watch joins or adopts a shared recording only from a fresh
/// one (an answer, or one sent moments ago): a context that waited while the watch was away may name a recording
/// that has ended.
public struct PhoneContext: Codable, Equatable, Sendable {
    public var version = WatchLink.version
    /// The shared recording the iPhone records now (its own, or one it records along with). Nil when none.
    public var sharedRecording: WatchSharedRecording?
    /// The watch's Record Along on the iPhone: when on, the watch joins the shared recording as soon as Daybook
    /// opens on it, and the iPhone asks it to start with each one.
    public var recordsAlong: Bool
    /// "Alex's iPhone", for the watch's words.
    public var phoneName: String?
    public var sentAt: Date

    public init(sharedRecording: WatchSharedRecording? = nil, recordsAlong: Bool = true, phoneName: String? = nil,
                sentAt: Date = Date()) {
        self.sharedRecording = sharedRecording
        self.recordsAlong = recordsAlong
        self.phoneName = phoneName
        self.sentAt = sentAt
    }
}

/// The iPhone's shared recording.
public struct WatchSharedRecording: Codable, Equatable, Sendable {
    public var conversationID: UUID
    public var title: String?
    /// On the iPhone's clock.
    public var startedAt: Date

    public init(conversationID: UUID, title: String? = nil, startedAt: Date) {
        self.conversationID = conversationID
        self.title = title
        self.startedAt = startedAt
    }
}

/// What the watch is recording and what it still holds. The answer to `.start`, `.stop`, and `.status`, and pushed
/// (`.state`) whenever it changes; also the watch's application context, so the iPhone knows it after a relaunch.
public struct WatchState: Codable, Equatable, Sendable {
    public var version = WatchLink.version
    /// The watch app's installation ID (its tracks' serial).
    public var watchID: String
    /// The recording in progress (capturing, or interrupted and waiting to resume). Nil when none.
    public var recording: WatchRecordingInfo?
    /// Whether the microphone is capturing now. False while `recording` waits out an interruption (a call, Siri).
    public var isCapturing: Bool
    /// Finished recordings the iPhone hasn't imported yet, oldest first.
    public var finished: [WatchRecordingInfo]
    /// Why this state was sent, when something changed.
    public var change: WatchChange?
    /// Battery, 0…100, and whether it's charging.
    public var battery: Int?
    public var charging: Bool
    /// Space left for recordings.
    public var freeBytes: UInt64?
    public var totalBytes: UInt64?
    /// The watch app's version ("1.0 (1020)").
    public var appVersion: String?
    /// The watch's model ("Apple Watch Series 12").
    public var model: String?
    /// When this was true, on the watch's clock.
    public var asOf: Date

    public var isRecording: Bool { recording != nil }

    public init(watchID: String, recording: WatchRecordingInfo? = nil, isCapturing: Bool = false, finished: [WatchRecordingInfo] = [],
                change: WatchChange? = nil, battery: Int? = nil, charging: Bool = false, freeBytes: UInt64? = nil,
                totalBytes: UInt64? = nil, appVersion: String? = nil, model: String? = nil, asOf: Date = Date()) {
        self.watchID = watchID
        self.recording = recording
        self.isCapturing = isCapturing
        self.finished = finished
        self.change = change
        self.battery = battery
        self.charging = charging
        self.freeBytes = freeBytes
        self.totalBytes = totalBytes
        self.appVersion = appVersion
        self.model = model
        self.asOf = asOf
    }
}

/// Why the watch's state changed.
public enum WatchChange: String, Codable, Equatable, Sendable {
    /// The person started recording on the watch: the iPhone records too (its recorder button).
    case startedOnWatch
    /// Daybook opened on the watch while the iPhone recorded, and the watch joined (Record Along): the same as
    /// starting on the watch, for the iPhone.
    case joined
    /// The person stopped recording on the watch: the shared recording stops everywhere (its recorder button).
    case stoppedOnWatch
    /// The iPhone's `.start` or `.stop` went through.
    case startedByPhone
    case stoppedByPhone
    /// The microphone stopped for a call or Siri, or came back.
    case interrupted
    case resumed
    /// The recording ended on its own: storage full, the battery, or the microphone failed.
    case endedOnItsOwn
    /// A recording found unfinished at launch (the app was ended while recording) was closed.
    case recovered
}

/// One recording on the watch.
public struct WatchRecordingInfo: Codable, Equatable, Sendable, Identifiable {
    /// Its ID, stable for the recording's life (a UUID string): the track's recording ID.
    public var id: String
    /// The shared recording it records along with, when the iPhone started it or it joined one.
    public var conversationID: UUID?
    /// When it started, on the watch's clock.
    public var startedAt: Date
    /// Its length so far, or in all once finished: from its first sample to its last, gaps included.
    public var duration: TimeInterval
    /// The segments it has, by index, in order. Once finished, every one the iPhone must receive (a segment lost to
    /// the app being ended is left out).
    public var segmentIndices: [Int]
    public var isFinished: Bool
    /// The size of its segments so far.
    public var byteCount: UInt64

    public init(id: String, conversationID: UUID? = nil, startedAt: Date, duration: TimeInterval = 0, segmentIndices: [Int] = [],
                isFinished: Bool = false, byteCount: UInt64 = 0) {
        self.id = id
        self.conversationID = conversationID
        self.startedAt = startedAt
        self.duration = duration
        self.segmentIndices = segmentIndices
        self.isFinished = isFinished
        self.byteCount = byteCount
    }
}

// MARK: - Audio

/// One segment of a recording: an AAC M4A file the watch sends with `WCSession.transferFile` as soon as it's
/// closed, with this as the transfer's metadata. Segments are short, so ending the app costs at most the one being
/// written, and an interruption ends one; the iPhone joins them on the recording's timeline.
public struct WatchSegment: Codable, Equatable, Sendable {
    public var recordingID: String
    public var index: Int
    /// Where it starts, in seconds from the recording's start (its first sample). Gaps between segments (an
    /// interruption) are silence when they're joined.
    public var startOffset: TimeInterval
    public var duration: TimeInterval
    /// Closed by the writer, rather than found unfinished after the app was ended.
    public var cleanlyClosed: Bool
    /// The recording as it was when this segment closed.
    public var recording: WatchRecordingInfo

    public init(recordingID: String, index: Int, startOffset: TimeInterval, duration: TimeInterval, cleanlyClosed: Bool = true,
                recording: WatchRecordingInfo) {
        self.recordingID = recordingID
        self.index = index
        self.startOffset = startOffset
        self.duration = duration
        self.cleanlyClosed = cleanlyClosed
        self.recording = recording
    }

    /// "<recordingID>-<index>.m4a": the segment's file name on both sides.
    public var fileName: String { "\(recordingID)-\(String(format: "%04d", index)).m4a" }
}

/// The audio format the watch records: AAC-LC, mono, variable bit rate near 64 kbps, as the iPhone records, so
/// the iPhone joins segments by copying packets, never encoding again.
public struct WatchAudioFormat: Codable, Equatable, Sendable {
    public var sampleRate: Double
    public var bitRate: Int

    public static let speech = WatchAudioFormat(sampleRate: 48_000, bitRate: 64_000)
    /// How long a segment runs before the next begins.
    public static let segmentLength: TimeInterval = 120

    public init(sampleRate: Double, bitRate: Int) {
        self.sampleRate = sampleRate
        self.bitRate = bitRate
    }
}

// MARK: - Clock

/// One clock sample: the iPhone's time when it asked, the watch's when it answered, and the iPhone's when the
/// answer arrived.
public struct WatchClockSample: Codable, Equatable, Sendable {
    public var phoneSent: Date
    public var watchTime: Date
    public var phoneReceived: Date?

    public init(phoneSent: Date, watchTime: Date, phoneReceived: Date? = nil) {
        self.phoneSent = phoneSent
        self.watchTime = watchTime
        self.phoneReceived = phoneReceived
    }

    /// How far the watch's clock is ahead of the iPhone's, assuming the answer took as long as the question.
    public var offset: TimeInterval? {
        guard let phoneReceived else { return nil }
        let midpoint = phoneSent.addingTimeInterval(phoneReceived.timeIntervalSince(phoneSent) / 2)
        return watchTime.timeIntervalSince(midpoint)
    }

    public var roundTrip: TimeInterval? { phoneReceived.map { $0.timeIntervalSince(phoneSent) } }
}

/// The watch's clock against the iPhone's, from the samples with the shortest round trip (the least delayed).
public struct WatchClock: Codable, Equatable, Sendable {
    public private(set) var samples: [WatchClockSample] = []
    /// Kept: the most recent this many.
    public static let kept = 8

    public init() {}

    public mutating func add(_ sample: WatchClockSample) {
        guard sample.offset != nil else { return }
        samples.append(sample)
        if samples.count > Self.kept { samples.removeFirst(samples.count - Self.kept) }
    }

    /// How far the watch's clock is ahead of the iPhone's. Nil before any sample.
    public var offset: TimeInterval? {
        samples.min { ($0.roundTrip ?? .infinity) < ($1.roundTrip ?? .infinity) }?.offset
    }

    /// A time on the watch's clock, on the iPhone's.
    public func phoneTime(_ watchTime: Date) -> Date { watchTime.addingTimeInterval(-(offset ?? 0)) }
}

// MARK: - Payloads

/// Encodes values into the property-list dictionaries WatchConnectivity carries, and back.
public enum WatchPayload {
    public static func dictionary<T: Encodable>(_ value: T) throws -> [String: Any] {
        [WatchLink.payloadKey: try JSONEncoder().encode(value), WatchLink.versionKey: WatchLink.version]
    }

    /// Nil for a dictionary that isn't Daybook's, or one this side can't read (a newer version's message).
    public static func decode<T: Decodable>(_ type: T.Type, from dictionary: [String: Any]) -> T? {
        guard let data = dictionary[WatchLink.payloadKey] as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
