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
    /// Frame/host-time pairs for measuring the microphone clock's drift: about once a second for a run's first minute,
    /// then about every ten seconds (`ClockAnchorSchedule`).
    var clockAnchors: [ClockAnchor]
    /// Format conversions and device switches inside this segment.
    var notes: [String]?

    /// The file a segment is written to: "segment-000.m4a", "segment-001.m4a"…
    static func fileName(index: Int) -> String { String(format: "segment-%03d.m4a", index) }

    /// The index a segment's file name carries; nil for a file that isn't a segment's.
    static func index(fromFileName name: String) -> Int? {
        guard name.hasPrefix(filePrefix), name.hasSuffix(fileSuffix), name.count > filePrefix.count + fileSuffix.count else { return nil }
        let digits = name.dropFirst(filePrefix.count).dropLast(fileSuffix.count)
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }

    private static let filePrefix = "segment-"
    private static let fileSuffix = ".m4a"
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

    /// Who leads the recording, written "macLed" or "phoneLed" as journals always were.
    enum Role: String, Codable, Sendable {
        /// A Mac asked this iPhone to record its conversation.
        case macLed
        /// This iPhone started; any Macs record along.
        case phoneLed

        /// A role a later build wrote reads as this iPhone's own, so its recording is still recovered.
        init(from decoder: Decoder) throws {
            self = Role(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .phoneLed
        }
    }

    var role: Role
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
    enum State: String, Codable, Sendable {
        case recording, paused
        /// Stop has ended the capture (every segment closed, `endedAt` set) and the recording is being joined and filed:
        /// written before the audio session is given back, so a recording iOS ends Daybook during is recovered as
        /// saved, not as cut short while recording (`PhoneRecording.Recovery`).
        case stopping
        case stopped
    }

    struct FinalFile: Codable, Equatable, Sendable {
        var fileName: String
        var frameCount: Int64
        /// True when segments were joined: their packets copied into one file in order, with silence in the gaps.
        var joined: Bool
        /// True when joining decoded and encoded them again, because their formats differed. Nil otherwise, and in
        /// journals written before joining copied packets.
        var reencoded: Bool? = nil
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
    /// Handwriting in the notes. Optional, so journals written before handwriting still load.
    var ink: [NoteInk]?
    var highlights: [Highlight] = []
    /// Optional, so journals written before photos still load.
    var photos: [CapturePhoto]?
    /// The Macs it's recorded with; nil when none (and in journals written before multipoint was kept).
    var multipoint: CaptureMultipoint?
    /// Paragraphs and bookmarks a Mac recording this conversation too wrote over the link, as that Mac
    /// files them (its time on the conversation's timeline, no track): they're filed so, never held by
    /// this recording. `timedNotes` and `highlights` have them too, on this recording's time, for the
    /// recording screen. Nil when none (and in journals written before shared notes).
    var sharedNotes: [TimedNote]?
    var sharedBookmarks: [Highlight]?
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

    /// Throws `PhoneRecorderError.locked` when the journal is there but can't be read now (the iPhone is locked).
    static func load(from directory: URL) throws -> PhoneCaptureJournal {
        let url = url(in: directory)
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw StagingProtection.isUnreadable(error) || StagingProtection.cannotOpen(url) ? PhoneRecorderError.locked : error
        }
        return try JournalCoding.decoder().decode(PhoneCaptureJournal.self, from: data)
    }

    /// Owner-only, atomic, and kept until unlock (`StagingProtection`): a locked iPhone can write it, a new file each
    /// time, but not read it back.
    func write(to directory: URL) throws {
        let url = Self.url(in: directory)
        try JournalCoding.encoder().encode(self).write(to: url, options: [.atomic, StagingProtection.writing])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum JournalCoding {
    /// Compact: the journal is rewritten every few seconds while recording. Earlier, pretty-printed journals read the same.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
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
    /// How the run that made it ended, for a recording rebuilt at launch from what that run left; nil for one Stop
    /// finished.
    var recovery: Recovery?
    /// Photos taken while recording; their files are in `stagingDirectory`.
    var photos: [CapturePhoto] = []
    /// Handwriting in the notes.
    var ink: [NoteInk] = []
    /// The Macs it was recorded with, as the journal kept them (for a recovered recording).
    var multipoint: CaptureMultipoint?
    /// What a Mac recording along wrote over the link, as that Mac files it (`PhoneCaptureJournal.sharedNotes`).
    var sharedNotes: [TimedNote] = []
    var sharedBookmarks: [Highlight] = []

    /// How a recording rebuilt at launch had ended (`PhoneCaptureJournal.state`).
    enum Recovery: Equatable, Sendable {
        /// Daybook ended while it recorded or was paused: the last seconds may be missing.
        case quitWhileRecording
        /// Stop had ended it, and Daybook was ended before it was saved: it's whole.
        case interruptedWhileSaving
    }

    /// Rebuilt at launch from what an earlier run left.
    var recovered: Bool { recovery != nil }
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
    /// The recording's files are there but can't be read until the iPhone is unlocked: never "No audio was recorded".
    case locked

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "A recording is already in progress."
        case .notRecording: return "Daybook isn’t recording."
        case .microphoneDenied: return "Allow Daybook to use the microphone in Settings › Privacy & Security › Microphone."
        case .noMicrophone: return "No microphone is available."
        case .directoryInUse: return "This recording folder is already in use. Start the recording again."
        case .encoderUnavailable: return "Recording couldn’t continue. Everything up to then is saved."
        case .diskBacklog: return "Storage couldn’t keep up with the recording. Everything up to then is saved."
        case .nothingRecorded: return "No audio was recorded."
        case .locked: return "The recording’s files can’t be opened until iPhone is unlocked."
        }
    }

    /// What went wrong, for Details: the encoder's step that failed.
    var details: String? {
        if case .encoderUnavailable(let detail) = self { return "The audio encoder stopped (\(detail))." }
        return nil
    }
}

extension PhoneRecorderError: PlainSentenceError {
    var plainDetails: String? { details }
}
