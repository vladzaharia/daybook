import DaybookCore
import Foundation

/// One continuous run of audio in one M4A file. A recording has one segment unless something
/// stopped the input (an interruption or a media-services reset).
struct CaptureSegment: Codable, Equatable, Sendable {
    var index: Int
    var fileName: String
    /// Seconds on the conversation's timeline where this segment's first sample falls.
    var startOffset: TimeInterval
    /// Frames handed to the encoder. Can trail or lead durable audio after a crash; the file is
    /// authoritative.
    var frameCount: Int64
    /// The file was finished normally. False while writing, or after a crash.
    var closed: Bool
    /// Host time (seconds) of the first sample.
    var firstSampleHostTime: TimeInterval
    /// Frame/host-time pairs about once a second, for measuring the microphone clock's drift.
    var clockAnchors: [ClockAnchor]
    /// Format conversions and device switches inside this segment.
    var notes: [String]?
}

/// A pause in the recording.
struct CaptureInterruption: Codable, Equatable, Sendable {
    /// Conversation seconds when input stopped.
    var began: TimeInterval
    /// Conversation seconds when the interruption ended (input may still be paused).
    var ended: TimeInterval?
    var reason: String?
    /// True once recording continued.
    var resumed: Bool?
}

/// What the microphone was, at the start and at every route change.
struct CaptureRouteEvent: Codable, Equatable, Sendable {
    /// Conversation seconds.
    var time: TimeInterval
    var input: AudioInputRoute?
    /// `start`, `new-device`, `device-removed`, `configuration`…
    var reason: String
}

/// A photo taken during the recording, kept in the staging folder until the recording is filed.
struct CapturePhoto: Codable, Equatable, Sendable {
    var fileName: String
    /// The shutter moment.
    var capturedAt: Date
    /// Conversation seconds at the shutter.
    var time: TimeInterval
}

/// The Macs a recording is made with (docs/multipoint.md), kept in its journal so that one
/// recovered after Daybook was killed still joins its conversation and its Macs are still stopped.
struct CaptureMultipoint: Codable, Equatable, Sendable {
    struct Mac: Codable, Equatable, Sendable {
        var id: UUID
        var name: String
        /// This iPhone asked it to record, so this iPhone stops it.
        var startedByPhone: Bool
        /// It recorded too, or may have (it never answered).
        var mayHaveRecorded: Bool
    }

    /// `macLed` (a Mac asked this iPhone to record its conversation) or `phoneLed`.
    var role: String
    /// The Mac that leads, when one does.
    var leadMacID: UUID?
    /// When that Mac's recording started, and the conversation's timeline zero, on its clock.
    var leadStartedAt: Date?
    var timelineStart: Date?
    /// That Mac's clock − this iPhone's.
    var leadClockOffset: TimeInterval?
    /// The conversation as that Mac has it.
    var title: String?
    var date: Date?
    var macs: [Mac] = []
}

/// The recording's crash-safe sidecar, rewritten atomically as it changes: everything needed to
/// rebuild the recording, with its notes and bookmarks, if Daybook is killed. The phone's
/// counterpart of the Mac's capture-session.json and per-track sidecars.
struct PhoneCaptureJournal: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case recording, paused, stopped }

    struct FinalFile: Codable, Equatable, Sendable {
        var fileName: String
        var frameCount: Int64
        /// True when segments were joined (decoded, padded, encoded once).
        var joined: Bool
    }

    static let fileName = "phone-capture.json"
    static let finalFileName = "iPhone recording.m4a"

    var schemaVersion = 1
    /// The conversation's ID.
    var id: UUID
    /// This recording's own ID, the one its track and the link name it by: one conversation can hold
    /// several of this iPhone's recordings (a Mac recording into it again). Nil in journals written
    /// before it, whose recordings were named by the conversation's ID.
    var recordingID: UUID?
    var title: String
    /// When Record was pressed.
    var createdAt: Date
    /// The first sample on the wall clock: the conversation's start for multipoint alignment.
    var startedAt: Date?
    /// The first sample on the host clock (`mach_absolute_time` seconds).
    var hostTimeSeconds: TimeInterval?
    /// The first sample on the continuous clock (`mach_continuous_time` seconds).
    var continuousTimeSeconds: TimeInterval?
    var sampleRate: Double
    var bitRate: Int
    var state: State = .recording
    var endedAt: Date?
    var segments: [CaptureSegment] = []
    var interruptions: [CaptureInterruption] = []
    var routes: [CaptureRouteEvent] = []
    var warnings: [String] = []
    var notes = ""
    var timedNotes: [TimedNote] = []
    var highlights: [Highlight] = []
    /// Optional, so journals written before photos still load.
    var photos: [CapturePhoto]?
    /// The Macs it's recorded with; nil when none (and in journals written before multipoint was kept).
    var multipoint: CaptureMultipoint?
    var finalFile: FinalFile?

    init(id: UUID, title: String, createdAt: Date, format: RecordingFormat) {
        self.id = id; self.title = title; self.createdAt = createdAt
        self.sampleRate = format.sampleRate; self.bitRate = format.bitRate
    }

    var format: RecordingFormat {
        var format = RecordingFormat.speech
        format.sampleRate = sampleRate
        format.bitRate = bitRate
        return format
    }

    static func url(in directory: URL) -> URL { directory.appendingPathComponent(fileName) }

    static func load(from directory: URL) throws -> PhoneCaptureJournal {
        try JournalCoding.decoder().decode(PhoneCaptureJournal.self, from: Data(contentsOf: url(in: directory)))
    }

    /// Owner-only, atomic.
    func write(to directory: URL) throws {
        let url = Self.url(in: directory)
        try JournalCoding.encoder().encode(self).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum JournalCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

/// A finished phone recording, ready to be filed in the library as a new conversation.
struct PhoneRecording: Sendable, Equatable {
    /// The conversation's ID.
    var id: UUID
    /// This recording's own ID (`PhoneCaptureJournal.recordingID`): its track's device recording ID.
    var recordingID: UUID
    var title: String
    /// One AAC M4A whose timeline is the conversation's: interruptions are silent gaps.
    var audioURL: URL
    var startedAt: Date
    var endedAt: Date
    var duration: TimeInterval
    /// The first sample on the host clock, for multipoint alignment.
    var hostTimeSeconds: TimeInterval?
    var notes: String
    var timedNotes: [TimedNote]
    var highlights: [Highlight]
    var capture: TrackCaptureDetails
    var warnings: [String]
    /// The staging folder; the library removes it once the recording is filed.
    var stagingDirectory: URL
    var recovered: Bool
    /// Photos taken while recording; their files are in `stagingDirectory`.
    var photos: [CapturePhoto] = []
    /// The Macs it was recorded with, as the journal kept them (for a recovered recording).
    var multipoint: CaptureMultipoint?
}

enum PhoneRecorderError: LocalizedError, Equatable {
    case alreadyRecording
    case notRecording
    case microphoneDenied
    case noMicrophone
    case directoryInUse
    case encoderUnavailable(String)
    case diskBacklog
    case nothingRecorded

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "A recording is already in progress."
        case .notRecording: return "Daybook isn’t recording."
        case .microphoneDenied: return "Allow Daybook to use the microphone in Settings › Privacy & Security › Microphone."
        case .noMicrophone: return "No microphone is available."
        case .directoryInUse: return "This recording folder is already in use. Start the recording again."
        case .encoderUnavailable(let detail): return "Recording couldn’t continue (\(detail)). Everything up to then is saved."
        case .diskBacklog: return "Storage couldn’t keep up with the recording. Everything up to then is saved."
        case .nothingRecorded: return "No audio was recorded."
        }
    }
}
