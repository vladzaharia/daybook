import Foundation

// Optional records beside a page's strokes that nothing reads yet but that can't be recovered later, so they're kept
// from the first version: the strokes a page lost, the picture drawn under it, and when the notebook's pages were turned.
// Each is optional (a conversation without them encodes as it did before), carries `unknownFields`, and is bounded.

/// A stroke taken out of a page. PencilKit keeps only the strokes a drawing has now, so this is the only record of the
/// others: which stroke (`NotebookStroke.key`), when it was made, when it was erased, and where in the recording.
public struct ErasedStroke: Codable, Equatable, Sendable {
    /// `NotebookStroke.key` of the stroke.
    public var key: String
    /// When it was made, by the writing device's clock (the stroke's `creationDate`).
    public var madeAt: Date
    /// When it was taken out, by the same clock.
    public var erasedAt: Date
    /// Erased during a recording: with `trackID`, seconds into that recording; without, seconds on the conversation's
    /// timeline (as `NotebookPassage.trackID` and `time`). Nil when no recording ran, or its clock wasn't known.
    public var trackID: UUID?
    public var time: TimeInterval?
    /// Keys a newer Daybook wrote that this version doesn't know, written back as they came.
    public var unknownFields = UnknownFields()

    /// How many a page keeps. Past that the oldest erasures go: they ride in every snapshot of the conversation.
    public static let capacity = 200

    public init(key: String, madeAt: Date, erasedAt: Date, trackID: UUID? = nil, time: TimeInterval? = nil) {
        self.key = key; self.madeAt = madeAt; self.erasedAt = erasedAt; self.trackID = trackID
        self.time = time.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case key, madeAt, erasedAt, trackID, time
    }
    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decode(String.self, forKey: .key)
        madeAt = try values.decode(Date.self, forKey: .madeAt)
        erasedAt = try values.decode(Date.self, forKey: .erasedAt)
        trackID = try values.decodeIfPresent(UUID.self, forKey: .trackID)
        time = try values.decodeIfPresent(TimeInterval.self, forKey: .time)
        unknownFields = try UnknownFields(from: decoder, known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(key, forKey: .key)
        try values.encode(madeAt, forKey: .madeAt)
        try values.encode(erasedAt, forKey: .erasedAt)
        try values.encodeIfPresent(trackID, forKey: .trackID)
        try values.encodeIfPresent(time, forKey: .time)
        try unknownFields.encode(to: encoder)
    }

    /// Both copies' erasures, one per stroke: of two for the same stroke, the one that knows where in the recording it was,
    /// then the earlier erasure, then the greater encoding, so either copy being local gives the same list. Oldest erasure
    /// first, at most `capacity` (the oldest go). Nil when there are none.
    static func merged(_ a: [ErasedStroke]?, _ b: [ErasedStroke]?) -> [ErasedStroke]? {
        var chosen: [String: ErasedStroke] = [:]
        for stroke in (a ?? []) + (b ?? []) {
            if let held = chosen[stroke.key] {
                // Known time first; then the earlier erasure (a later duplicate can't move it); then the greater encoding.
                let known = (held.time != nil, stroke.time != nil)
                if known.0 != known.1 { if known.0 { continue } }
                else if held.erasedAt != stroke.erasedAt { if held.erasedAt < stroke.erasedAt { continue } }
                else if SyncEncoding.string(held) >= SyncEncoding.string(stroke) { continue }
            }
            chosen[stroke.key] = stroke
        }
        let ordered = chosen.values.sorted { $0.erasedAt != $1.erasedAt ? $0.erasedAt < $1.erasedAt : $0.key < $1.key }
        return ordered.isEmpty ? nil : Array(ordered.suffix(capacity))
    }
}

/// What a page's background file is.
public enum PageBackgroundKind: String, CaseIterable, ExtensibleSyncEnum {
    case image, pdf
    /// A kind a newer Daybook wrote reads as an image: the strokes still show, on paper.
    public static var syncFallback: PageBackgroundKind { .image }
}

/// A picture or a PDF page drawn under a page's strokes, kept in a file of its own, content-addressed like a drawing
/// (`Originals/Pages/<page UUID>-background-<first 16 hex of sha256>.<ext>`). A page with one takes its aspect, within the
/// A5 width (`NotebookPage.size(for:)`).
public struct PageBackground: Codable, Equatable, Sendable {
    public var relativePath: String
    public var sha256: String
    public var byteCount: Int
    @Extensible public var kind: PageBackgroundKind
    /// The file's extension, lowercase letters and digits ("jpg", "png", "heic", "pdf"): part of the path, so the path is
    /// derived from the page, the digest, and this.
    public var fileExtension: String
    /// The PDF page drawn, counting from 0. Nil for an image.
    public var pageIndex: Int?
    /// The picture's size in any one unit (pixels, or a PDF page's points): only its aspect matters.
    public var width: Double
    public var height: Double
    /// When it was set, by the setting device's clock, stamped after the one it replaces: the later of two stands.
    public var editedAt: Date
    /// Keys a newer Daybook wrote that this version doesn't know, written back as they came.
    public var unknownFields = UnknownFields()

    public init(relativePath: String, sha256: String, byteCount: Int, kind: PageBackgroundKind, fileExtension: String,
                pageIndex: Int? = nil, width: Double, height: Double, editedAt: Date) {
        self.relativePath = relativePath; self.sha256 = sha256; self.byteCount = byteCount; self.kind = kind
        self.fileExtension = fileExtension; self.pageIndex = pageIndex; self.width = width; self.height = height; self.editedAt = editedAt
    }

    /// The library path for a page's background with this digest and extension.
    public static func relativePath(page: UUID, sha256: String, fileExtension: String) -> String {
        "\(PageDrawing.folder)/\(page.uuidString)-background-\(sha256.prefix(16)).\(fileExtension)"
    }

    /// Whether the extension is one a path can carry: one to eight lowercase letters or digits.
    static func isFileExtension(_ value: String) -> Bool {
        (1...8).contains(value.count) && value.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber) }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case relativePath, sha256, byteCount, kind, fileExtension, pageIndex, width, height, editedAt
    }
    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        relativePath = try values.decode(String.self, forKey: .relativePath)
        sha256 = try values.decode(String.self, forKey: .sha256)
        byteCount = try values.decode(Int.self, forKey: .byteCount)
        _kind = try values.decode(Extensible<PageBackgroundKind>.self, forKey: .kind)
        fileExtension = try values.decode(String.self, forKey: .fileExtension)
        pageIndex = try values.decodeIfPresent(Int.self, forKey: .pageIndex)
        width = try values.decode(Double.self, forKey: .width)
        height = try values.decode(Double.self, forKey: .height)
        editedAt = try values.decode(Date.self, forKey: .editedAt)
        unknownFields = try UnknownFields(from: decoder, known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(relativePath, forKey: .relativePath)
        try values.encode(sha256, forKey: .sha256)
        try values.encode(byteCount, forKey: .byteCount)
        try values.encode(_kind, forKey: .kind)
        try values.encode(fileExtension, forKey: .fileExtension)
        try values.encodeIfPresent(pageIndex, forKey: .pageIndex)
        try values.encode(width, forKey: .width)
        try values.encode(height, forKey: .height)
        try values.encode(editedAt, forKey: .editedAt)
        try unknownFields.encode(to: encoder)
    }
}

extension NotebookPage {
    /// The tallest and widest a page may be made by its background, as a multiple of the A5 width: a long receipt scanned
    /// as a PDF page is drawn scaled to fit, not as a page that never ends.
    public static let backgroundAspect: ClosedRange<Double> = 0.25...4

    /// The size of a page with this background: the A5 width, and the height its aspect gives (kept within
    /// `backgroundAspect`). A5 when it has none.
    public static func size(for background: PageBackground?) -> (width: Double, height: Double) {
        guard let background, background.width.isFinite, background.width > 0, background.height.isFinite, background.height > 0 else { return a5 }
        let aspect = min(max(background.height / background.width, backgroundAspect.lowerBound), backgroundAspect.upperBound)
        return (a5.width, (a5.width * aspect * 100).rounded() / 100)
    }

    /// Puts a background under the strokes, and takes the size it gives (`size(for:)`), stamped after the one it replaces.
    /// A page's strokes are unchanged: they're drawn in points of the page, from its top-left corner.
    public mutating func setBackground(_ background: PageBackground?, now: Date = Date()) {
        var stamped = background
        stamped?.editedAt = NotebookPage.stamp(after: self.background?.editedAt, now: now)
        self.background = stamped
        (width, height) = Self.size(for: stamped)
        updatedAt = now
    }

    /// Whether the page's size is the one its background gives. A page without a background is any size.
    var hasBackgroundSize: Bool {
        guard let background else { return true }
        let size = Self.size(for: background)
        return width == size.width && abs(height - size.height) <= 0.01
    }
}

/// The notebook's open pages changing: a turn to other pages, or the notebook closing, with where in the recording that was,
/// so playback can show the page that was open.
public struct PageTurn: Codable, Equatable, Identifiable, Sendable {
    /// `PageTurn.id(at:pages:)`: the same turn is one entry on every device.
    public var id: UUID
    /// When, by the device's clock.
    public var at: Date
    /// The pages open from then on, left to right (one in a single layout, two in a spread). None when the notebook closed.
    public var pages: [UUID]
    /// Written during a recording: with `trackID`, seconds into that recording; without, seconds on the conversation's
    /// timeline (as `NotebookPassage.trackID` and `time`). Nil when no recording ran, or its clock wasn't known.
    public var trackID: UUID?
    public var time: TimeInterval?
    /// Keys a newer Daybook wrote that this version doesn't know, written back as they came.
    public var unknownFields = UnknownFields()

    /// How many a conversation keeps. Past that the oldest turns go.
    public static let capacity = 200

    public init(at: Date, pages: [UUID], trackID: UUID? = nil, time: TimeInterval? = nil) {
        self.id = Self.id(at: at, pages: pages); self.at = at; self.pages = pages; self.trackID = trackID
        self.time = time.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }

    /// From the moment (to the millisecond) and the pages, so a turn logged twice, or on two devices, is one.
    public static func id(at: Date, pages: [UUID]) -> UUID {
        let milliseconds = Int64((at.timeIntervalSince1970 * 1000).rounded())
        return SyncEncoding.uuid("page-turn:\(milliseconds):\(pages.map(\.uuidString).joined(separator: ","))")
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, at, pages, trackID, time
    }
    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        at = try values.decode(Date.self, forKey: .at)
        pages = try values.decode([UUID].self, forKey: .pages)
        trackID = try values.decodeIfPresent(UUID.self, forKey: .trackID)
        time = try values.decodeIfPresent(TimeInterval.self, forKey: .time)
        unknownFields = try UnknownFields(from: decoder, known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(at, forKey: .at)
        try values.encode(pages, forKey: .pages)
        try values.encodeIfPresent(trackID, forKey: .trackID)
        try values.encodeIfPresent(time, forKey: .time)
        try unknownFields.encode(to: encoder)
    }

    /// Both copies' turns, one per ID: of two for the same turn, the one that knows where in the recording it was, then the
    /// greater encoding. Oldest first, at most `capacity` (the oldest go). Nil when there are none.
    static func merged(_ a: [PageTurn]?, _ b: [PageTurn]?) -> [PageTurn]? {
        var chosen: [UUID: PageTurn] = [:]
        for turn in (a ?? []) + (b ?? []) {
            if let held = chosen[turn.id] {
                let known = (held.time != nil, turn.time != nil)
                if known.0 != known.1 ? known.0 : SyncEncoding.string(held) >= SyncEncoding.string(turn) { continue }
            }
            chosen[turn.id] = turn
        }
        let ordered = chosen.values.sorted { $0.at != $1.at ? $0.at < $1.at : $0.id.uuidString < $1.id.uuidString }
        return ordered.isEmpty ? nil : Array(ordered.suffix(capacity))
    }
}

extension RecordingClockSample {
    /// A track's clock samples are written once, when its recording is filed: a copy with samples beats one without, and of
    /// two with samples (a filing tried again) the longer, then the greater encoding, the same either way round.
    static func merged(_ a: [RecordingClockSample]?, _ b: [RecordingClockSample]?) -> [RecordingClockSample]? {
        guard let a, !a.isEmpty else { return b?.isEmpty == false ? b : nil }
        guard let b, !b.isEmpty else { return a }
        if a == b { return a }
        if a.count != b.count { return a.count > b.count ? a : b }
        return SyncEncoding.string(a) >= SyncEncoding.string(b) ? a : b
    }
}
