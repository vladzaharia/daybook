import DaybookCore
import Foundation

enum CapturedTrackRole: String, Codable {
    case microphone
    case systemAudio

    /// How a sentence for the person names it.
    var spokenName: String { self == .microphone ? "microphone" : "call audio" }

    /// Daybook's own recording errors already say what happened and what to do; anything else gets
    /// a plain sentence, with the system's words kept in the track's capture notes.
    static func speaksPlainly(_ error: Error) -> Bool { error is RecordingError || error is PCMTrackWriterError }
}

struct CapturedAudioTrack: Codable, Identifiable, Equatable {
    var id: CapturedTrackRole { role }
    var role: CapturedTrackRole
    var url: URL
    var startedAt: Date
    var firstSampleHostTimeSeconds: TimeInterval
    /// Add this to a transcript timestamp to place it on the session timeline.
    var offsetSeconds: TimeInterval
    var sampleRate: Double
    var channelCount: UInt32
    var frameCount: Int64
    /// Host-time observations (about one per second) for measuring this device's clock drift.
    var clockAnchors: [ClockAnchor]?
    /// `microphone`, `process-tap`, or `screen-capture-kit`.
    var method: String?
    /// Device switches and format conversions while recording.
    var notes: [String]?
    var duration: TimeInterval { Double(frameCount) / sampleRate }
    /// Host time of the session anchor, recovered from this track's own timing.
    var sessionHostTimeSeconds: TimeInterval { firstSampleHostTimeSeconds - offsetSeconds }

    /// The track's frame-to-session-time mapping, corrected for measured drift.
    var clock: TrackClock {
        ClockDriftEstimator.fit(anchors: clockAnchors ?? [], nominalRate: sampleRate,
                                sessionHostTime: sessionHostTimeSeconds, fallbackOffset: offsetSeconds).clock
    }
}

/// A track Daybook computed from the captured originals, such as the microphone with the call's echo removed.
struct DerivedCaptureTrack: Codable, Equatable {
    var url: URL
    var derivedFrom: CapturedTrackRole
    /// `echo-cancelled`.
    var processing: String
    var offsetSeconds: TimeInterval
    var startedAt: Date
    var sampleRate: Double
    var frameCount: Int64
    var duration: TimeInterval { Double(frameCount) / sampleRate }
}

/// Which path recorded the call's audio.
struct SystemAudioCaptureInfo: Codable, Equatable {
    enum Method: String, Codable {
        /// A Core Audio process tap on the call app (macOS 14.2+): only the call is recorded.
        case processTap = "process-tap"
        /// ScreenCaptureKit: everything the Mac plays except Daybook.
        case screenCaptureKit = "screen-capture-kit"
    }
    var method: Method
    /// Bundle IDs of the tapped app and its helpers.
    var capturedApps: [String]?
    /// Why the process tap was not used, or why capture switched away from it: one plain sentence.
    var fallbackReason: String?
    /// The system's words for why the process tap failed, kept for the call audio's capture notes.
    var fallbackDetail: String?
    /// Session seconds at which capture switched from the tap to ScreenCaptureKit.
    var switchedAt: TimeInterval?
}

/// What the Mac played audio through, observed when recording started and at every change.
struct AudioRouteEvent: Codable, Equatable {
    /// Session seconds.
    var time: TimeInterval
    var route: AudioOutputRoute
}

struct CaptureResult: Codable, Identifiable, Equatable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date
    var tracks: [CapturedAudioTrack]
    var warnings: [String]
    var directory: URL
    var systemAudio: SystemAudioCaptureInfo?
    var outputRoutes: [AudioRouteEvent]?
    /// Set once the recording has been finalized for transcription.
    var echoRemoval: EchoRemovalReport?
    var derivedTracks: [DerivedCaptureTrack]?

    init(id: UUID, startedAt: Date, endedAt: Date, tracks: [CapturedAudioTrack], warnings: [String], directory: URL,
         systemAudio: SystemAudioCaptureInfo? = nil, outputRoutes: [AudioRouteEvent]? = nil,
         echoRemoval: EchoRemovalReport? = nil, derivedTracks: [DerivedCaptureTrack]? = nil) {
        self.id = id; self.startedAt = startedAt; self.endedAt = endedAt; self.tracks = tracks
        self.warnings = warnings; self.directory = directory; self.systemAudio = systemAudio
        self.outputRoutes = outputRoutes; self.echoRemoval = echoRemoval; self.derivedTracks = derivedTracks
    }

    /// Summary of the output route over the whole recording.
    var outputRouteSummary: AudioOutputRoute.Kind? {
        let kinds = Set((outputRoutes ?? []).map(\.route.kind))
        guard let first = kinds.first else { return nil }
        return kinds.count == 1 ? first : .mixed
    }
}

struct CaptureSessionManifest: Codable {
    var id: UUID
    var startedAt: Date
    var hostTimeSeconds: TimeInterval
    var includeSystemAudio: Bool
    /// The call app the recording was started for, when known.
    var callApp: CallAppTarget?
}

/// The meeting app whose audio a process tap should record.
struct CallAppTarget: Codable, Equatable, Sendable {
    var bundleID: String
    var displayName: String
    var isBrowser: Bool

    init(bundleID: String, displayName: String, isBrowser: Bool) {
        self.bundleID = bundleID; self.displayName = displayName; self.isBrowser = isBrowser
    }

    init(_ candidate: MeetingCandidate) {
        self.init(bundleID: candidate.bundleID, displayName: candidate.appName, isBrowser: candidate.isBrowser)
    }

    /// Bundle-ID prefixes whose processes play this app's audio. Browsers and Electron apps render
    /// audio in helper processes; Safari plays through WebKit's shared GPU process.
    var processBundlePrefixes: [String] {
        var prefixes = [bundleID]
        switch bundleID.lowercased() {
        case "com.apple.safari": prefixes += ["com.apple.WebKit.GPU", "com.apple.WebKit.WebContent"]
        case "org.mozilla.firefox": prefixes += ["org.mozilla.plugincontainer"]
        default: break
        }
        return prefixes
    }

    func owns(bundleID candidate: String) -> Bool {
        let value = candidate.lowercased()
        return processBundlePrefixes.contains { prefix in
            let prefix = prefix.lowercased()
            return value == prefix || value.hasPrefix(prefix + ".")
        }
    }
}

enum RecordingError: LocalizedError {
    case alreadyRecording
    case microphoneDenied
    case noMicrophone
    case noDisplay
    case outputDirectoryInUse
    case invalidAudio
    case audioFormatChanged
    case interrupted(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "A recording is already in progress."
        case .microphoneDenied: return "Allow Daybook to use the microphone in System Settings › Privacy & Security › Microphone."
        case .noMicrophone: return "No microphone is available. Connect an input device and try again."
        case .noDisplay: return "System audio capture needs an active display and Screen & System Audio Recording permission."
        case .outputDirectoryInUse: return "This recording folder is already in use. Start the recording again."
        case .invalidAudio: return "The audio device sent audio Daybook can’t use."
        case .audioFormatChanged: return "The audio device changed. Everything up to then is saved; start a new recording to continue."
        case .interrupted(let reason): return reason
        }
    }
}

enum CaptureJSON {
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

    /// Owner-only, atomic.
    static func persist<T: Encodable>(_ value: T, at url: URL) throws {
        try encoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
