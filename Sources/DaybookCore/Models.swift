import Foundation

public enum MeetingKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto, general, oneOnOne, scrum, therapy, personal, interview, lecture
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .auto: return "Automatic"
        case .general: return "Meeting"
        case .oneOnOne: return "1:1"
        case .scrum: return "Standup"
        case .therapy: return "Therapy"
        case .personal: return "Personal conversation"
        case .interview: return "Interview"
        case .lecture: return "Lecture"
        }
    }
}

/// Where a conversation shows in the library when the person overrides the automatic choice.
public enum LibraryPlacement: String, Codable, CaseIterable, Sendable {
    case work, personal
}

public enum MeetingStatus: String, Codable, Sendable {
    case draft, recording, imported, transcribing, summarizing, ready, failed
}

public enum AudioSource: String, Codable, CaseIterable, Sendable {
    case microphone, systemAudio, soundcore, imported
    public var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .systemAudio: return "Computer audio"
        case .soundcore: return "Soundcore Work"
        case .imported: return "Imported recording"
        }
    }
}

public struct RecordingTrack: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var source: AudioSource
    public var relativePath: String
    public var fileName: String
    public var createdAt: Date
    public var duration: TimeInterval?
    /// Start time on the common meeting timeline. Nil requires transcript alignment.
    public var offset: TimeInterval?
    public var sha256: String
    /// Where the recording came from when a recorder (a "device") supplied it, kept so the library
    /// knows what it already imported. Derived from the library, so it survives sync and works on
    /// another Mac. All optional: libraries written before devices existed decode unchanged.
    /// The device kind, such as `soundcore.work`.
    public var deviceKind: String?
    /// The recorder's serial number, when it reports one.
    public var deviceSerial: String?
    /// The recording's stable ID on the recorder or in its export folder.
    public var deviceRecordingID: String?
    /// Set on a track Daybook made from another one (for example, the microphone with the call's
    /// echo removed). The original is always kept; a derived track is transcribed in its place.
    public var derivedFrom: UUID?
    /// What produced a derived track, such as `echo-cancelled`. Nil for originals.
    public var processing: String?
    /// When the recording started by its own clock (this Mac's, or the recorder's), when known.
    public var startedAt: Date?
    /// Where the recording sits on the conversation's timeline and how that was found. Nil for
    /// recordings placed the way they were before multipoint recording (capture offset or transcript).
    public var alignment: SourceAlignment?
    /// How Daybook captured this track (capture path, measured clock rate, echo removal). Nil for imports.
    public var capture: TrackCaptureDetails?
    public init(id: UUID = UUID(), source: AudioSource = .imported, relativePath: String,
                fileName: String, createdAt: Date = Date(), duration: TimeInterval? = nil,
                offset: TimeInterval? = nil, sha256: String = "", device: DeviceRecordingIdentity? = nil,
                derivedFrom: UUID? = nil, processing: String? = nil, startedAt: Date? = nil,
                alignment: SourceAlignment? = nil) {
        self.id = id; self.source = source; self.relativePath = relativePath; self.fileName = fileName
        self.createdAt = createdAt; self.duration = duration; self.offset = offset; self.sha256 = sha256
        self.deviceKind = device?.kind; self.deviceSerial = device?.serial; self.deviceRecordingID = device?.recordingID
        self.derivedFrom = derivedFrom; self.processing = processing
        self.startedAt = startedAt; self.alignment = alignment
    }

    /// The recorder identity, when the track came from one.
    public var device: DeviceRecordingIdentity? {
        get {
            guard let deviceKind, let deviceRecordingID else { return nil }
            return DeviceRecordingIdentity(kind: deviceKind, serial: deviceSerial, recordingID: deviceRecordingID)
        }
        set { deviceKind = newValue?.kind; deviceSerial = newValue?.serial; deviceRecordingID = newValue?.recordingID }
    }
}

/// One recording on one recorder: the device kind (`soundcore.work`), the recorder's serial number
/// when known, and the recording's stable ID there.
public struct DeviceRecordingIdentity: Codable, Hashable, Sendable {
    public var kind: String
    public var serial: String?
    public var recordingID: String
    public init(kind: String, serial: String? = nil, recordingID: String) {
        self.kind = kind; self.serial = serial; self.recordingID = recordingID
    }
}

public struct SegmentProvenance: Codable, Equatable, Sendable {
    public var trackID: UUID
    public var segmentID: UUID
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    public var confidence: Double?
    /// Positions (in the unified passage's whitespace-separated words, as fused) of the words this
    /// source supplied or agreed with. Nil when the passage is this source's own wording.
    public var wordIndices: [Int]?
    public init(trackID: UUID, segmentID: UUID, start: TimeInterval, end: TimeInterval,
                text: String, confidence: Double? = nil, wordIndices: [Int]? = nil) {
        self.trackID = trackID; self.segmentID = segmentID; self.start = start; self.end = end
        self.text = text; self.confidence = confidence; self.wordIndices = wordIndices
    }
}

public struct TranscriptSegment: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var trackID: UUID
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    public var speakerID: String?
    public var confidence: Double?
    public var provenance: [SegmentProvenance]
    public init(id: UUID = UUID(), trackID: UUID, start: TimeInterval, end: TimeInterval,
                text: String, speakerID: String? = nil, confidence: Double? = nil,
                provenance: [SegmentProvenance] = []) {
        self.id = id; self.trackID = trackID; self.start = start; self.end = end
        self.text = text; self.speakerID = speakerID; self.confidence = confidence; self.provenance = provenance
    }
}

/// Records the settings actually applied by an inference run; typed engine configuration lives in the app.
public struct ProcessingSettings: Codable, Equatable, Sendable {
    public var modelID: String
    public var parameters: [String: String]
    public var createdAt: Date
    /// Exactly which model produced the result: family, variant, revision, and engine version
    /// (docs/models.md). Nil for results made before the model system recorded it; those name their
    /// model through `modelID`, which the catalog's migration table still resolves.
    public var model: ModelProvenance?
    public init(modelID: String, parameters: [String: String] = [:], createdAt: Date = Date(), model: ModelProvenance? = nil) {
        self.modelID = modelID; self.parameters = parameters; self.createdAt = createdAt; self.model = model
    }

    private enum CodingKeys: String, CodingKey { case modelID, parameters, createdAt, model }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        modelID = try values.decode(String.self, forKey: .modelID)
        parameters = try values.decode([String: String].self, forKey: .parameters)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        // Provenance a newer Daybook wrote differently is dropped, never a reason to reject the meeting.
        model = (try? values.decodeIfPresent(ModelProvenance.self, forKey: .model)) ?? nil
    }
}

public struct TranscriptWord: Codable, Equatable, Sendable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var confidence: Double?
    public init(text: String, start: TimeInterval, end: TimeInterval, confidence: Double? = nil) {
        self.text = text; self.start = start; self.end = end; self.confidence = confidence
    }
}

public struct TrackTranscript: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var trackID: UUID
    public var segments: [TranscriptSegment]
    public var language: String?
    public var modelID: String
    public var createdAt: Date
    /// Explicitly established by capture timing or the user; never inferred from import date.
    public var knownOffset: TimeInterval?
    public var processingSettings: ProcessingSettings?
    /// Raw ASR words in source-local time, retained for speaker-only reprocessing.
    public var words: [TranscriptWord]?
    public init(id: UUID = UUID(), trackID: UUID, segments: [TranscriptSegment], language: String? = nil,
                modelID: String = "", createdAt: Date = Date(), knownOffset: TimeInterval? = nil,
                processingSettings: ProcessingSettings? = nil, words: [TranscriptWord]? = nil) {
        self.id = id; self.trackID = trackID; self.segments = segments; self.language = language
        self.modelID = modelID; self.createdAt = createdAt; self.knownOffset = knownOffset
        self.processingSettings = processingSettings; self.words = words
    }
}

public struct Speaker: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var sourceTrackID: UUID?
    public var embedding: [Float]?
    public var embeddingModelID: String?
    public var analysisSettings: ProcessingSettings?
    public init(id: String, name: String, sourceTrackID: UUID? = nil, embedding: [Float]? = nil,
                embeddingModelID: String? = nil, analysisSettings: ProcessingSettings? = nil) {
        self.id = id; self.name = name; self.sourceTrackID = sourceTrackID
        self.embedding = embedding; self.embeddingModelID = embeddingModelID; self.analysisSettings = analysisSettings
    }
}

public struct Highlight: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var trackID: UUID?
    public var time: TimeInterval
    public var text: String
    public var duration: TimeInterval?
    public init(id: UUID = UUID(), trackID: UUID? = nil, time: TimeInterval, text: String = "", duration: TimeInterval? = nil) {
        self.id = id; self.trackID = trackID; self.time = time; self.text = text
        self.duration = duration
    }
}

public struct SummarySection: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var heading: String
    public var body: String
    /// Photos this section shows (`MeetingPhoto.id`), in order. Nil for none, and in summaries
    /// written before photos.
    public var photoIDs: [UUID]?
    public init(id: UUID = UUID(), heading: String, body: String, photoIDs: [UUID]? = nil) {
        self.id = id; self.heading = heading; self.body = body
        self.photoIDs = photoIDs?.isEmpty == true ? nil : photoIDs
    }
}

public struct ActionItem: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var text: String
    public var owner: String?
    public var completed: Bool
    public init(id: UUID = UUID(), text: String, owner: String? = nil, completed: Bool = false) {
        self.id = id; self.text = text; self.owner = owner; self.completed = completed
    }
}

public struct MeetingSummary: Codable, Equatable, Sendable {
    public var kind: MeetingKind
    public var title: String
    public var overview: String
    public var sections: [SummarySection]
    public var actionItems: [ActionItem]
    public var modelID: String
    public var createdAt: Date
    public var processingSettings: ProcessingSettings?
    public init(kind: MeetingKind = .general, title: String = "", overview: String,
                sections: [SummarySection] = [], actionItems: [ActionItem] = [],
                modelID: String = "", createdAt: Date = Date(), processingSettings: ProcessingSettings? = nil) {
        self.kind = kind; self.title = title; self.overview = overview; self.sections = sections
        self.actionItems = actionItems; self.modelID = modelID; self.createdAt = createdAt
        self.processingSettings = processingSettings
    }
}

public struct MeetingRevision: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    public var field: String
    public var oldValue: String
    public var newValue: String
    public init(id: UUID = UUID(), date: Date = Date(), field: String, oldValue: String, newValue: String) {
        self.id = id; self.date = date; self.field = field; self.oldValue = oldValue; self.newValue = newValue
    }
}

public struct Meeting: Codable, Equatable, Identifiable, Sendable {
    public var schemaVersion: Int
    public var id: UUID
    public var title: String
    public var date: Date
    public var updatedAt: Date
    public var kind: MeetingKind
    public var notes: String
    public var timedNotes: [TimedNote]?
    public var folderID: UUID?
    public var tags: [String]?
    public var templateID: String?
    /// Nil follows the detected kind; set when the person moves the conversation to Work or Personal.
    /// It never changes the kind or the template.
    public var placement: LibraryPlacement?
    public var tracks: [RecordingTrack]
    /// Original model output remains intact when the unified transcript is corrected.
    public var transcripts: [TrackTranscript]
    public var unifiedTranscript: [TranscriptSegment]
    public var alignmentReports: [TrackAlignment]
    public var summary: MeetingSummary?
    public var revisions: [MeetingRevision]
    public var highlights: [Highlight]
    public var speakers: [Speaker]
    public var status: MeetingStatus
    public var errorMessage: String?
    public var correctionTransferIssues: [CorrectionTransferIssue]?
    public var speakerMatches: [SpeakerMatch]?
    /// Recorders asked to record alongside this Mac (multipoint); their recordings join this conversation.
    public var companions: [CompanionRecording]?
    /// Recordings in this conversation that may belong with another one, waiting for the person.
    public var sourceSuggestions: [SourceSuggestion]?
    /// Audio alignments measured between this meeting's recordings, reused by fusion.
    public var audioAlignments: [TrackAudioAlignment]?
    /// What the latest fusion did: sources, their timing, and how many words each contributed.
    public var fusionSummary: FusionSummary?
    /// Processing asked for on one device for another to carry out (the iPhone asks, a Mac runs it).
    /// Nil until the first request; merged by ID across devices (`ProcessingRequest.merged`).
    public var processingRequests: [ProcessingRequest]?
    /// Photos taken or added for the conversation (`Photos.swift`), deleted ones included. Nil until
    /// the first photo.
    public var photos: [MeetingPhoto]?
    public init(id: UUID = UUID(), title: String = "Untitled meeting", date: Date = Date(),
                updatedAt: Date = Date(), kind: MeetingKind = .auto, notes: String = "",
                tracks: [RecordingTrack] = [], transcripts: [TrackTranscript] = [],
                unifiedTranscript: [TranscriptSegment] = [], alignmentReports: [TrackAlignment] = [],
                summary: MeetingSummary? = nil, revisions: [MeetingRevision] = [],
                highlights: [Highlight] = [], speakers: [Speaker] = [], status: MeetingStatus = .draft,
                errorMessage: String? = nil, correctionTransferIssues: [CorrectionTransferIssue]? = nil,
                speakerMatches: [SpeakerMatch]? = nil, timedNotes: [TimedNote]? = nil,
                folderID: UUID? = nil, tags: [String]? = nil, templateID: String? = nil, placement: LibraryPlacement? = nil) {
        self.schemaVersion = 1; self.id = id; self.title = title; self.date = date; self.updatedAt = updatedAt
        self.kind = kind; self.notes = notes; self.tracks = tracks; self.transcripts = transcripts
        self.timedNotes = timedNotes
        self.folderID = folderID; self.tags = tags; self.templateID = templateID; self.placement = placement
        self.unifiedTranscript = unifiedTranscript; self.alignmentReports = alignmentReports
        self.summary = summary; self.revisions = revisions; self.highlights = highlights
        self.speakers = speakers; self.status = status; self.errorMessage = errorMessage
        self.correctionTransferIssues = correctionTransferIssues; self.speakerMatches = speakerMatches
    }
    public mutating func setNotes(_ value: String) {
        guard notes != value else { return }
        revisions.append(MeetingRevision(field: "notes", oldValue: notes, newValue: value))
        notes = value; updatedAt = Date()
    }
    public mutating func correctSegment(id: UUID, text: String) {
        guard let index = unifiedTranscript.firstIndex(where: { $0.id == id }), unifiedTranscript[index].text != text else { return }
        revisions.append(MeetingRevision(field: "segment:\(id.uuidString)", oldValue: unifiedTranscript[index].text, newValue: text))
        unifiedTranscript[index].text = text; updatedAt = Date()
    }
    public mutating func renameSpeaker(id: String, name: String) {
        guard let index = speakers.firstIndex(where: { $0.id == id }), speakers[index].name != name else { return }
        revisions.append(MeetingRevision(field: "speaker:\(id)", oldValue: speakers[index].name, newValue: name))
        speakers[index].name = name; updatedAt = Date()
    }
    public mutating func setSummary(_ value: MeetingSummary) {
        var value = value
        // A refreshed summary must not reopen a task the user already completed.
        for index in value.actionItems.indices {
            let item = value.actionItems[index]
            let matches = summary?.actionItems.filter { $0.text == item.text && $0.owner == item.owner } ?? []
            if matches.count == 1 { value.actionItems[index].completed = matches[0].completed }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let old = summary.flatMap { try? encoder.encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let new = (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        if old != new { revisions.append(MeetingRevision(field: "summary", oldValue: old, newValue: new)) }
        summary = value; updatedAt = Date()
    }
    @discardableResult public mutating func applyFusion(_ result: FusionResult) -> [CorrectionTransferIssue] {
        applyFusion(result, transferred: CorrectionTransfer.apply(to: result.segments, in: self))
    }
    @discardableResult mutating func applyFusion(_ result: FusionResult, transferred: CorrectionTransfer.Result) -> [CorrectionTransferIssue] {
        unifiedTranscript = transferred.segments
        correctionTransferIssues = transferred.issues.isEmpty ? nil : transferred.issues
        alignmentReports = result.alignments; updatedAt = Date()
        fusionSummary = result.summary
        speakers += result.addedSpeakers.filter { added in !speakers.contains { $0.id == added.id } }
        return transferred.issues
    }
    /// Explicit review either applies the saved correction to a chosen passage or dismisses transfer.
    /// The original correction remains in revision history in both cases.
    @discardableResult public mutating func resolveCorrectionTransfer(id: UUID, targetSegmentID: UUID?) -> Bool {
        guard let issue = correctionTransferIssues?.first(where: { $0.id == id }) else { return false }
        if let targetSegmentID {
            guard unifiedTranscript.contains(where: { $0.id == targetSegmentID }) else { return false }
            correctSegment(id: targetSegmentID, text: issue.originalSegment.text)
        }
        revisions.append(MeetingRevision(field: "correction-transfer:\(id.uuidString)", oldValue: issue.originalSegment.text,
            newValue: targetSegmentID.map { "applied:\($0.uuidString)" } ?? "dismissed"))
        correctionTransferIssues?.removeAll { $0.id == id }
        if correctionTransferIssues?.isEmpty == true { correctionTransferIssues = nil }
        updatedAt = Date()
        return true
    }
    public func alignedTime(for highlight: Highlight) -> TimeInterval? {
        guard let trackID = highlight.trackID else { return highlight.time }
        guard let alignment = alignmentReports.first(where: { $0.trackID == trackID }), alignment.method != .unaligned else { return nil }
        return highlight.time * alignment.rate + alignment.offset
    }
}

public struct GlossaryTerm: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var term: String
    public var aliases: [String]
    public var definition: String
    public var approved: Bool
    /// A proposed term stays scoped to its originating meeting unless explicitly approved.
    public var sourceMeetingIDs: [UUID]
    public var occurrences: Int
    public var updatedAt: Date
    public init(id: UUID = UUID(), term: String, aliases: [String] = [], definition: String = "",
                approved: Bool = false, sourceMeetingIDs: [UUID] = [], occurrences: Int = 1, updatedAt: Date = Date()) {
        self.id = id; self.term = term; self.aliases = aliases; self.definition = definition
        self.approved = approved; self.sourceMeetingIDs = sourceMeetingIDs; self.occurrences = occurrences; self.updatedAt = updatedAt
    }
}
