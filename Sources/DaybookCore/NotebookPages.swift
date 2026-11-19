import Foundation

// Notebook pages: fixed-size pages of handwriting beside a conversation's typed notes. The strokes are the original,
// kept as content-addressed files (`PageDrawing`); what was read from them (`PageReading`, `NotebookPassage`) is
// derived and can be made again. Everything here is optional on `Meeting`, so a conversation without pages encodes
// exactly as it did before, and a Daybook that doesn't know pages keeps them as an unknown key and writes them back.

/// The paper a page is drawn on. Only how the page looks; never part of the strokes.
public enum PagePaper: String, CaseIterable, ExtensibleSyncEnum {
    case plain, ruled, grid, dots
    public static var syncFallback: PagePaper { .plain }
}

/// What a passage is, decided when it's read (`PassageKind.decide`).
public enum PassageKind: String, CaseIterable, ExtensibleSyncEnum {
    /// Words: they reach summaries as the person's notes.
    case writing
    /// A drawing (possibly with words in it): it reaches summaries as a picture, described on device.
    case sketch
    /// A kind a newer Daybook wrote reads as writing, so its words still count.
    public static var syncFallback: PassageKind { .writing }
}

/// One committed version of a page's strokes: `PKDrawing.dataRepresentation()` bytes in a file of their own.
public struct PageDrawing: Codable, Equatable, Sendable {
    /// `Originals/Pages/<page UUID>-<first 16 hex of sha256>.pkdrawing` (`relativePath(page:sha256:)`).
    public var relativePath: String
    public var sha256: String
    public var byteCount: Int
    public var strokeCount: Int
    /// When these strokes were committed, by the committing device's clock, stamped after the drawing it replaces
    /// (`NotebookPage.stamp`), so a device whose clock is behind can't make a later commit look older.
    public var editedAt: Date
    /// `PKDrawing.requiredContentVersion.rawValue`. A reader that supports less shows the words, not the strokes.
    public var contentVersion: Int?
    /// The committing device's name ("Alex's iPhone"), for Version History.
    public var device: String?
    /// Keys a newer Daybook wrote that this version doesn't know, written back as they came.
    public var unknownFields = UnknownFields()

    public init(relativePath: String, sha256: String, byteCount: Int, strokeCount: Int, editedAt: Date,
                contentVersion: Int? = nil, device: String? = nil) {
        self.relativePath = relativePath; self.sha256 = sha256; self.byteCount = byteCount; self.strokeCount = strokeCount
        self.editedAt = editedAt; self.contentVersion = contentVersion; self.device = device
    }

    /// Where page drawings live in a conversation's folder.
    public static let folder = "Originals/Pages"
    public static let fileExtension = "pkdrawing"

    /// The library path for a page's drawing with this digest. Each version has its own path, so a changed page never
    /// collides with an installed file at the same path.
    public static func relativePath(page: UUID, sha256: String) -> String {
        "\(folder)/\(page.uuidString)-\(sha256.prefix(16)).\(fileExtension)"
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case relativePath, sha256, byteCount, strokeCount, editedAt, contentVersion, device
    }
    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        relativePath = try values.decode(String.self, forKey: .relativePath)
        sha256 = try values.decode(String.self, forKey: .sha256)
        byteCount = try values.decode(Int.self, forKey: .byteCount)
        strokeCount = try values.decode(Int.self, forKey: .strokeCount)
        editedAt = try values.decode(Date.self, forKey: .editedAt)
        contentVersion = try values.decodeIfPresent(Int.self, forKey: .contentVersion)
        device = try values.decodeIfPresent(String.self, forKey: .device)
        unknownFields = try UnknownFields(from: decoder, known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(relativePath, forKey: .relativePath)
        try values.encode(sha256, forKey: .sha256)
        try values.encode(byteCount, forKey: .byteCount)
        try values.encode(strokeCount, forKey: .strokeCount)
        try values.encode(editedAt, forKey: .editedAt)
        try values.encodeIfPresent(contentVersion, forKey: .contentVersion)
        try values.encodeIfPresent(device, forKey: .device)
        try unknownFields.encode(to: encoder)
    }
}

/// One passage: strokes grouped by time and place (`PassageGrouping`), read together.
public struct NotebookPassage: Codable, Equatable, Identifiable, Sendable {
    /// `NotebookPassage.id(page:firstStroke:)`: the same strokes give the same ID on every device.
    public var id: UUID
    @Extensible public var kind: PassageKind
    /// Its strokes' bounds on the page, in page points (origin top-left).
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var strokeCount: Int
    /// `PassageGrouping.digest(of:)` of its stroke keys: what corrections and sketch readings are checked against.
    public var strokeDigest: String
    /// Its first stroke began, and its last ended, by the writing device's clock.
    public var start: Date
    public var end: Date
    /// Written during a recording: with `trackID`, seconds into that recording (it follows the recording's placement,
    /// like a bookmark on a recording); without, seconds on the conversation's timeline (like `MeetingPhoto.time`).
    /// Nil when no recording was running; the timeline then places it by `start` (`Meeting.timelineTime`).
    public var trackID: UUID?
    public var time: TimeInterval?
    /// What was read: nil when nothing could read it, "" when it has no words. Lines joined by "\n".
    public var words: String?
    /// Keys a newer Daybook wrote that this version doesn't know, written back as they came.
    public var unknownFields = UnknownFields()

    public init(id: UUID, kind: PassageKind, x: Double, y: Double, width: Double, height: Double, strokeCount: Int,
                strokeDigest: String, start: Date, end: Date, trackID: UUID? = nil, time: TimeInterval? = nil, words: String? = nil) {
        self.id = id; self.kind = kind; self.x = x; self.y = y; self.width = width; self.height = height
        self.strokeCount = strokeCount; self.strokeDigest = strokeDigest; self.start = start; self.end = end
        self.trackID = trackID; self.time = time.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }; self.words = words
    }

    public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    /// The same strokes give the same ID on every device: it comes from the page and the passage's first stroke.
    public static func id(page: UUID, firstStroke key: String) -> UUID {
        SyncEncoding.uuid("notebook-passage:\(page.uuidString):\(key)")
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, kind, x, y, width, height, strokeCount, strokeDigest, start, end, trackID, time, words
    }
    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        _kind = try values.decode(Extensible<PassageKind>.self, forKey: .kind)
        x = try values.decode(Double.self, forKey: .x)
        y = try values.decode(Double.self, forKey: .y)
        width = try values.decode(Double.self, forKey: .width)
        height = try values.decode(Double.self, forKey: .height)
        strokeCount = try values.decode(Int.self, forKey: .strokeCount)
        strokeDigest = try values.decode(String.self, forKey: .strokeDigest)
        start = try values.decode(Date.self, forKey: .start)
        end = try values.decode(Date.self, forKey: .end)
        trackID = try values.decodeIfPresent(UUID.self, forKey: .trackID)
        time = try values.decodeIfPresent(TimeInterval.self, forKey: .time)
        words = try values.decodeIfPresent(String.self, forKey: .words)
        unknownFields = try UnknownFields(from: decoder, known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(_kind, forKey: .kind)
        try values.encode(x, forKey: .x)
        try values.encode(y, forKey: .y)
        try values.encode(width, forKey: .width)
        try values.encode(height, forKey: .height)
        try values.encode(strokeCount, forKey: .strokeCount)
        try values.encode(strokeDigest, forKey: .strokeDigest)
        try values.encode(start, forKey: .start)
        try values.encode(end, forKey: .end)
        try values.encodeIfPresent(trackID, forKey: .trackID)
        try values.encodeIfPresent(time, forKey: .time)
        try values.encodeIfPresent(words, forKey: .words)
        try unknownFields.encode(to: encoder)
    }
}

/// What reading one drawing of a page found. Readings are measurements: a newer one replaces an older one whole.
public struct PageReading: Codable, Equatable, Sendable {
    /// The `PageDrawing.sha256` this reading read.
    public var drawingSHA256: String
    /// In reading order: top to bottom, then left to right.
    public var passages: [NotebookPassage]
    public var readAt: Date
    /// The reader: `modelID` "pencilkit/stroke-recognizer" or `PhotoReading.visionModel` ("apple-vision/system");
    /// `parameters["recognitionVersion"]` (PKStrokeRecognizer's), `["languages"]`, `["grouping"]` (`PassageGrouping.version`).
    public var settings: ProcessingSettings?
    /// Keys a newer Daybook wrote that this version doesn't know, written back as they came.
    public var unknownFields = UnknownFields()

    public init(drawingSHA256: String, passages: [NotebookPassage], readAt: Date = Date(), settings: ProcessingSettings? = nil) {
        self.drawingSHA256 = drawingSHA256; self.passages = passages; self.readAt = readAt; self.settings = settings
    }

    /// The grouping that made the passages (0 when none is recorded). A newer version's grouping stands here: a page is
    /// read again only by an older grouping than this version's, never by a newer one, so two versions never undo each
    /// other's readings.
    public var groupingVersion: Int { Int(settings?.parameters["grouping"] ?? "") ?? 0 }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case drawingSHA256, passages, readAt, settings
    }
    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        drawingSHA256 = try values.decode(String.self, forKey: .drawingSHA256)
        passages = try values.decode([NotebookPassage].self, forKey: .passages)
        readAt = try values.decode(Date.self, forKey: .readAt)
        settings = try values.decodeIfPresent(ProcessingSettings.self, forKey: .settings)
        unknownFields = try UnknownFields(from: decoder, known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(drawingSHA256, forKey: .drawingSHA256)
        try values.encode(passages, forKey: .passages)
        try values.encode(readAt, forKey: .readAt)
        try values.encodeIfPresent(settings, forKey: .settings)
        try unknownFields.encode(to: encoder)
    }
}

/// The person's own words for a passage. They stand while the passage has the strokes they were typed for.
public struct PassageCorrection: Codable, Equatable, Sendable {
    public var passageID: UUID
    public var strokeDigest: String
    public var text: String
    public var editedAt: Date
    /// Keys a newer Daybook wrote that this version doesn't know, written back as they came.
    public var unknownFields = UnknownFields()

    public init(passageID: UUID, strokeDigest: String, text: String, editedAt: Date = Date()) {
        self.passageID = passageID; self.strokeDigest = strokeDigest; self.text = text; self.editedAt = editedAt
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case passageID, strokeDigest, text, editedAt
    }
    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        passageID = try values.decode(UUID.self, forKey: .passageID)
        strokeDigest = try values.decode(String.self, forKey: .strokeDigest)
        text = try values.decode(String.self, forKey: .text)
        editedAt = try values.decode(Date.self, forKey: .editedAt)
        unknownFields = try UnknownFields(from: decoder, known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(passageID, forKey: .passageID)
        try values.encode(strokeDigest, forKey: .strokeDigest)
        try values.encode(text, forKey: .text)
        try values.encode(editedAt, forKey: .editedAt)
        try unknownFields.encode(to: encoder)
    }
}

/// What on-device image reading found in a sketch passage (a crop of the page picture), with the models that found it.
public struct SketchAnalysis: Codable, Equatable, Sendable {
    public var passageID: UUID
    /// The passage's strokes when it was read; a reading of other strokes is out of date.
    public var strokeDigest: String
    /// `caption`, `recognizedText`, `labels`, `isInformative`, `settings`, `createdAt`; `sharpness` and `duplicateOf` unused.
    public var analysis: PhotoAnalysis
    /// Keys a newer Daybook wrote that this version doesn't know, written back as they came.
    public var unknownFields = UnknownFields()

    public init(passageID: UUID, strokeDigest: String, analysis: PhotoAnalysis) {
        self.passageID = passageID; self.strokeDigest = strokeDigest; self.analysis = analysis
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case passageID, strokeDigest, analysis
    }
    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        passageID = try values.decode(UUID.self, forKey: .passageID)
        strokeDigest = try values.decode(String.self, forKey: .strokeDigest)
        analysis = try values.decode(PhotoAnalysis.self, forKey: .analysis)
        unknownFields = try UnknownFields(from: decoder, known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(passageID, forKey: .passageID)
        try values.encode(strokeDigest, forKey: .strokeDigest)
        try values.encode(analysis, forKey: .analysis)
        try unknownFields.encode(to: encoder)
    }
}

/// A notebook page.
public struct NotebookPage: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// Pages sort by `order`, then `createdAt`, then `id` (`Meeting.visiblePages`). A new page's order is one more than
    /// the largest of any page's, deleted ones included; one moved between two takes the midpoint.
    public var order: Double
    /// In points. Every page this version makes is A5: 420 × 595.
    public var width: Double
    public var height: Double
    @Extensible public var paper: PagePaper
    public var createdAt: Date
    /// The device that made the page, as photos record it (`PhotoOrigin`): places passages by wall clock when they have
    /// no recording time.
    public var origin: PhotoOrigin?
    /// The strokes. Nil until the first commit.
    public var drawing: PageDrawing?
    /// Drawings a merge didn't choose (two devices changed this page apart), newest first. Their files stay, so Version
    /// History can put one back. Nil when none.
    public var setAside: [PageDrawing]?
    /// What was read from `drawing`, or from an earlier drawing while it waits to be read again (`isReadingCurrent`).
    public var reading: PageReading?
    /// Nil when none.
    public var corrections: [PassageCorrection]?
    /// Nil when none.
    public var sketches: [SketchAnalysis]?
    /// The person took it out of summaries.
    public var hiddenFromSummary: Bool?
    /// When it was deleted. A deleted page keeps its record and files so it can be put back, and so an older copy of the
    /// conversation can't bring it back by itself.
    public var removedAt: Date?
    public var updatedAt: Date
    /// Keys a newer Daybook wrote that this version doesn't know, written back as they came.
    public var unknownFields = UnknownFields()

    public static let a5 = (width: 420.0, height: 595.0)
    public static let ruleSpacing = 28.0

    public init(id: UUID = UUID(), order: Double, paper: PagePaper = .ruled, origin: PhotoOrigin? = nil, now: Date = Date()) {
        self.id = id; self.order = order; self.width = Self.a5.width; self.height = Self.a5.height
        self.paper = paper; self.createdAt = now; self.origin = origin; self.updatedAt = now
    }

    public var isRemoved: Bool { removedAt != nil }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, order, width, height, paper, createdAt, origin, drawing, setAside, reading, corrections, sketches,
            hiddenFromSummary, removedAt, updatedAt
    }
    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        order = try values.decode(Double.self, forKey: .order)
        width = try values.decode(Double.self, forKey: .width)
        height = try values.decode(Double.self, forKey: .height)
        _paper = try values.decode(Extensible<PagePaper>.self, forKey: .paper)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        origin = try values.decodeIfPresent(PhotoOrigin.self, forKey: .origin)
        drawing = try values.decodeIfPresent(PageDrawing.self, forKey: .drawing)
        setAside = try values.decodeIfPresent([PageDrawing].self, forKey: .setAside)
        reading = try values.decodeIfPresent(PageReading.self, forKey: .reading)
        corrections = try values.decodeIfPresent([PassageCorrection].self, forKey: .corrections)
        sketches = try values.decodeIfPresent([SketchAnalysis].self, forKey: .sketches)
        hiddenFromSummary = try values.decodeIfPresent(Bool.self, forKey: .hiddenFromSummary)
        removedAt = try values.decodeIfPresent(Date.self, forKey: .removedAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        unknownFields = try UnknownFields(from: decoder, known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(order, forKey: .order)
        try values.encode(width, forKey: .width)
        try values.encode(height, forKey: .height)
        try values.encode(_paper, forKey: .paper)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encodeIfPresent(origin, forKey: .origin)
        try values.encodeIfPresent(drawing, forKey: .drawing)
        try values.encodeIfPresent(setAside, forKey: .setAside)
        try values.encodeIfPresent(reading, forKey: .reading)
        try values.encodeIfPresent(corrections, forKey: .corrections)
        try values.encodeIfPresent(sketches, forKey: .sketches)
        try values.encodeIfPresent(hiddenFromSummary, forKey: .hiddenFromSummary)
        try values.encodeIfPresent(removedAt, forKey: .removedAt)
        try values.encode(updatedAt, forKey: .updatedAt)
        try unknownFields.encode(to: encoder)
    }
}

// MARK: Derived values

extension NotebookPage {
    /// The reading was made from the current strokes, by this version's grouping.
    public var isReadingCurrent: Bool {
        guard let reading, let drawing else { return false }
        return reading.drawingSHA256 == drawing.sha256 && reading.groupingVersion >= PassageGrouping.version
    }

    /// There are strokes, and no reading of them by this version's grouping yet.
    public var needsReading: Bool { drawing != nil && !isReadingCurrent }

    public var passages: [NotebookPassage] { reading?.passages ?? [] }

    /// The words a passage shows: the person's correction while its strokes are unchanged, else what was read.
    public func words(of passage: NotebookPassage) -> String? {
        correction(for: passage)?.text ?? passage.words
    }

    /// The person's words for a passage, while its strokes are the ones they were typed for.
    public func correction(for passage: NotebookPassage) -> PassageCorrection? {
        corrections?.first { $0.passageID == passage.id && $0.strokeDigest == passage.strokeDigest }
    }

    /// What image reading found in a sketch passage, while its strokes are the ones it read.
    public func sketch(for passage: NotebookPassage) -> SketchAnalysis? {
        sketches?.first { $0.passageID == passage.id && $0.strokeDigest == passage.strokeDigest }
    }

    /// `max(now, previous + 0.001)`, as `LibraryValue.edit` stamps settings: a clock that is behind can't make a later
    /// change look older.
    public static func stamp(after previous: Date?, now: Date) -> Date {
        guard let previous else { return now }
        return max(now, previous.addingTimeInterval(0.001))
    }
}

extension Meeting {
    /// Pages that aren't deleted, by `order`, `createdAt`, then `id`.
    public var visiblePages: [NotebookPage] {
        (pages ?? []).filter { !$0.isRemoved }.sorted(by: NotebookPage.precedes)
    }

    public func page(_ id: UUID) -> NotebookPage? { pages?.first { $0.id == id } }

    /// 1-based, among `visiblePages`.
    public func pageNumber(of id: UUID) -> Int? { visiblePages.firstIndex { $0.id == id }.map { $0 + 1 } }

    /// The order a new page at the end takes: one more than the largest of any page's, deleted ones included.
    public var nextPageOrder: Double { ((pages ?? []).map(\.order).max() ?? 0) + 1 }

    /// Where a passage falls on the timeline, placed as a photo taken at its start would be.
    public func timelineTime(of passage: NotebookPassage, on page: NotebookPage) -> TimeInterval? {
        timelineTime(trackID: passage.trackID, time: passage.time, moment: passage.start, origin: page.origin)
    }
}

extension NotebookPage {
    /// Page order: `order`, then `createdAt`, then `id`.
    static func precedes(_ lhs: NotebookPage, _ rhs: NotebookPage) -> Bool {
        if lhs.order != rhs.order { return lhs.order < rhs.order }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
