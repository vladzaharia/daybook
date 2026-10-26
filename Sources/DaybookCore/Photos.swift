import Foundation

// Photos taken or added for a conversation (docs/architecture.md, "Photos"). Each keeps its original
// image file byte for byte, the moment it was taken, and, when it was taken during a recording, where
// it falls in that recording, so it lands on the conversation's timeline the way a bookmark does and
// follows the recording's placement in a multipoint conversation. Everything here is optional on
// `Meeting`, so libraries written before photos decode unchanged.

/// How a photo's `capturedAt` was found.
public enum PhotoCaptureDateSource: String, Codable, Sendable {
    /// Daybook's own camera: the moment the shutter fired.
    case camera
    /// The file's own capture date (EXIF `DateTimeOriginal`, with its offset when the file has one).
    case metadata
    /// Nothing in the file said, so the moment it was added.
    case added

    /// Unknown values a newer Daybook wrote read as `.added`, the least specific.
    public init(from decoder: Decoder) throws {
        self = PhotoCaptureDateSource(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .added
    }
}

/// The device that added a photo. For Daybook on iPhone, `kind` and `serial` match the identity on that
/// iPhone's recordings (`daybook.iphone` and its installation ID), so the photo can be placed by the
/// same clock as its recordings.
public struct PhotoOrigin: Codable, Equatable, Hashable, Sendable {
    /// `mac`, or a recorder kind such as `daybook.iphone`.
    public var kind: String
    public var serial: String?
    /// "Studio Mac", "Alex's iPhone".
    public var name: String?

    public init(kind: String, serial: String? = nil, name: String? = nil) {
        self.kind = kind; self.serial = serial; self.name = name
    }

    public static let macKind = "mac"

    /// Whether `track` was recorded by this device.
    public func recorded(_ track: RecordingTrack) -> Bool {
        if kind == Self.macKind {
            return track.deviceKind == nil && track.capture != nil && (track.source == .microphone || track.source == .systemAudio)
        }
        return track.deviceKind == kind && (serial == nil || track.deviceSerial == serial)
    }
}

/// What processing found in a photo, with the models that found it.
public struct PhotoAnalysis: Codable, Equatable, Sendable {
    /// A short description ("Whiteboard with the Q3 launch plan").
    public var caption: String?
    /// The text in the picture, line by line.
    public var recognizedText: String?
    /// What it shows, most likely first ("whiteboard", "document").
    public var labels: [String]?
    /// From 0 (blurred) to 1 (sharp), when measured.
    public var sharpness: Double?
    /// A near copy of this earlier photo in the same conversation.
    public var duplicateOf: UUID?
    /// Worth a place in a summary: false for a blurred shot, a near copy, or a picture with nothing in it.
    public var isInformative: Bool
    /// The models that made it: `modelID` is the caption model's key, `parameters["textModel"]` the
    /// text reader's, and `model` the caption model's exact provenance.
    public var settings: ProcessingSettings?
    public var createdAt: Date

    public init(caption: String? = nil, recognizedText: String? = nil, labels: [String]? = nil, sharpness: Double? = nil,
                duplicateOf: UUID? = nil, isInformative: Bool = true, settings: ProcessingSettings? = nil, createdAt: Date = Date()) {
        self.caption = caption; self.recognizedText = recognizedText; self.labels = labels; self.sharpness = sharpness
        self.duplicateOf = duplicateOf; self.isInformative = isInformative; self.settings = settings; self.createdAt = createdAt
    }
}

/// A photo taken or added for a conversation. The image file is the original, kept as it arrived
/// (HEIC, JPEG, or PNG) at `relativePath` inside the conversation's folder, and synced as a
/// content-addressed blob like recordings are.
public struct MeetingPhoto: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// `Originals/Photos/<id>.<ext>`.
    public var relativePath: String
    /// The name it arrived with ("IMG_0412.HEIC"), or a generated one for a camera capture.
    public var fileName: String
    public var sha256: String
    /// The file's type identifier ("public.heic", "public.jpeg", "public.png").
    public var contentType: String?
    public var byteCount: Int?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    /// The exact moment it was taken, by the adding device's clock.
    public var capturedAt: Date
    @Extensible public var capturedAtSource: PhotoCaptureDateSource
    public var addedAt: Date
    /// Taken during a recording: with `trackID`, seconds into that recording (it then follows the
    /// recording's placement on the timeline, like a bookmark on a recording); without, seconds on the
    /// conversation's timeline (this device's recording is the timeline). Nil when no recording was
    /// running; the timeline then places it by `capturedAt`.
    public var trackID: UUID?
    public var time: TimeInterval?
    public var origin: PhotoOrigin?
    /// The person's own caption.
    public var caption: String?
    /// What processing found. Nil until a Mac processes it.
    public var analysis: PhotoAnalysis?
    /// The person took it out of the summary; summaries leave it out until it's put back.
    public var hiddenFromSummary: Bool?
    /// When it was deleted. A deleted photo keeps its file and its record, so Undo and Version History
    /// can put it back, and an older copy of the conversation can't bring it back by itself.
    public var removedAt: Date?
    /// Keys a newer Daybook wrote that this version doesn't know, written back as they came.
    public var unknownFields = UnknownFields()

    public init(id: UUID = UUID(), relativePath: String, fileName: String, sha256: String, contentType: String? = nil,
                byteCount: Int? = nil, pixelWidth: Int? = nil, pixelHeight: Int? = nil, capturedAt: Date,
                capturedAtSource: PhotoCaptureDateSource = .added, addedAt: Date = Date(), trackID: UUID? = nil,
                time: TimeInterval? = nil, origin: PhotoOrigin? = nil, caption: String? = nil, analysis: PhotoAnalysis? = nil) {
        self.id = id; self.relativePath = relativePath; self.fileName = fileName; self.sha256 = sha256
        self.contentType = contentType; self.byteCount = byteCount; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.capturedAt = capturedAt; self.capturedAtSource = capturedAtSource; self.addedAt = addedAt
        self.trackID = trackID; self.time = time.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.origin = origin; self.caption = caption; self.analysis = analysis
    }

    public var isRemoved: Bool { removedAt != nil }

    /// The caption to show: the person's, else the one processing wrote.
    public var displayCaption: String? {
        let own = caption?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let own, !own.isEmpty { return own }
        let found = analysis?.caption?.trimmingCharacters(in: .whitespacesAndNewlines)
        return found?.isEmpty == false ? found : nil
    }

    /// Where photo originals live in a conversation's folder.
    public static let folder = "Originals/Photos"

    /// The library path for a photo with this ID and file extension.
    public static func relativePath(id: UUID, extension ext: String) -> String {
        let clean = ext.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(8)
        return "\(folder)/\(id.uuidString)" + (clean.isEmpty ? "" : ".\(clean)")
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, relativePath, fileName, sha256, contentType, byteCount, pixelWidth, pixelHeight, capturedAt,
            capturedAtSource, addedAt, trackID, time, origin, caption, analysis, hiddenFromSummary, removedAt
    }
    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        relativePath = try values.decode(String.self, forKey: .relativePath)
        fileName = try values.decode(String.self, forKey: .fileName)
        sha256 = try values.decode(String.self, forKey: .sha256)
        contentType = try values.decodeIfPresent(String.self, forKey: .contentType)
        byteCount = try values.decodeIfPresent(Int.self, forKey: .byteCount)
        pixelWidth = try values.decodeIfPresent(Int.self, forKey: .pixelWidth)
        pixelHeight = try values.decodeIfPresent(Int.self, forKey: .pixelHeight)
        capturedAt = try values.decode(Date.self, forKey: .capturedAt)
        _capturedAtSource = try values.decode(Extensible<PhotoCaptureDateSource>.self, forKey: .capturedAtSource)
        addedAt = try values.decode(Date.self, forKey: .addedAt)
        trackID = try values.decodeIfPresent(UUID.self, forKey: .trackID)
        time = try values.decodeIfPresent(TimeInterval.self, forKey: .time)
        origin = try values.decodeIfPresent(PhotoOrigin.self, forKey: .origin)
        caption = try values.decodeIfPresent(String.self, forKey: .caption)
        analysis = try values.decodeIfPresent(PhotoAnalysis.self, forKey: .analysis)
        hiddenFromSummary = try values.decodeIfPresent(Bool.self, forKey: .hiddenFromSummary)
        removedAt = try values.decodeIfPresent(Date.self, forKey: .removedAt)
        unknownFields = try UnknownFields(from: decoder, known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(relativePath, forKey: .relativePath)
        try values.encode(fileName, forKey: .fileName)
        try values.encode(sha256, forKey: .sha256)
        try values.encodeIfPresent(contentType, forKey: .contentType)
        try values.encodeIfPresent(byteCount, forKey: .byteCount)
        try values.encodeIfPresent(pixelWidth, forKey: .pixelWidth)
        try values.encodeIfPresent(pixelHeight, forKey: .pixelHeight)
        try values.encode(capturedAt, forKey: .capturedAt)
        try values.encode(_capturedAtSource, forKey: .capturedAtSource)
        try values.encode(addedAt, forKey: .addedAt)
        try values.encodeIfPresent(trackID, forKey: .trackID)
        try values.encodeIfPresent(time, forKey: .time)
        try values.encodeIfPresent(origin, forKey: .origin)
        try values.encodeIfPresent(caption, forKey: .caption)
        try values.encodeIfPresent(analysis, forKey: .analysis)
        try values.encodeIfPresent(hiddenFromSummary, forKey: .hiddenFromSummary)
        try values.encodeIfPresent(removedAt, forKey: .removedAt)
        try unknownFields.encode(to: encoder)
    }

    /// Field-wise merge of two copies of one photo (`MeetingMerge`): the person's caption, removal,
    /// and summary choice, and processing's analysis, are independent changes. A conflicting value
    /// keeps the newer one deterministically; `conflict` reports the field for History.
    static func merged(base: MeetingPhoto?, local: MeetingPhoto, remote: MeetingPhoto,
                       conflict: (String, String, String) -> Void) -> MeetingPhoto {
        func pick<T: Equatable & Encodable>(_ field: String, _ a: T, _ b: T, _ old: T?) -> T {
            if a == b { return a }
            if let old { if a == old { return b }; if b == old { return a } }
            let left = SyncEncoding.string(a), right = SyncEncoding.string(b)
            conflict(field, min(left, right), max(left, right))
            return left > right ? a : b
        }
        var result = local
        result.caption = pick("photo-caption:\(local.id)", local.caption, remote.caption, base.map(\.caption))
        result.hiddenFromSummary = pick("photo-summary:\(local.id)", local.hiddenFromSummary, remote.hiddenFromSummary, base.map(\.hiddenFromSummary))
        // Analyses are measurements: the newest one wins without a conflict.
        switch (local.analysis, remote.analysis) {
        case let (a?, b?):
            result.analysis = a.createdAt == b.createdAt
                ? (SyncEncoding.string(a) > SyncEncoding.string(b) ? a : b)
                : (b.createdAt > a.createdAt ? b : a)
        case (nil, let b): result.analysis = b
        default: break
        }
        // A deletion and an edit made apart: the deletion stands, and a Put Back made later wins over it.
        result.removedAt = pick("photo-removed:\(local.id)", local.removedAt, remote.removedAt, base.map(\.removedAt))
        // Timing can be refined (a photo moved onto a recording), the newest copy's way.
        if local.trackID != remote.trackID || local.time != remote.time {
            let timing = pick("photo-time:\(local.id)", PhotoTiming(local), PhotoTiming(remote), base.map(PhotoTiming.init))
            result.trackID = timing.trackID; result.time = timing.time
        }
        // What a newer Daybook added to it, key by key.
        result.unknownFields = UnknownFields.merged(base: base?.unknownFields, local.unknownFields, remote.unknownFields) { key, smaller, larger in
            conflict("photo-unknown:\(local.id):\(key)", smaller, larger)
        }
        return result
    }
}

extension MeetingPhoto {
    /// Both copies' photos: every photo either copy has (photos are originals, so none is dropped), each
    /// merged field by field. Order follows the ancestor, then new photos by ID, so both sides agree.
    static func mergedList(base: [MeetingPhoto], local: [MeetingPhoto], remote: [MeetingPhoto],
                           conflict: (String, String, String) -> Void) -> [MeetingPhoto] {
        var order: [UUID] = []
        for photo in base where !order.contains(photo.id) { order.append(photo.id) }
        order += Set((local + remote).map(\.id)).subtracting(order).sorted { $0.uuidString < $1.uuidString }
        return order.compactMap { id in
            let a = local.first { $0.id == id }, b = remote.first { $0.id == id }, old = base.first { $0.id == id }
            if let a, let b { return a == b ? a : merged(base: old, local: a, remote: b, conflict: conflict) }
            return a ?? b ?? old
        }
    }
}

private struct PhotoTiming: Codable, Equatable {
    var trackID: UUID?
    var time: TimeInterval?
    init(_ photo: MeetingPhoto) { trackID = photo.trackID; time = photo.time }
}

extension Meeting {
    /// Photos that aren't deleted, in the order they were taken (timeline first, then capture date).
    public var visiblePhotos: [MeetingPhoto] {
        (photos ?? []).filter { !$0.isRemoved }.sorted { lhs, rhs in
            let a = timelineTime(of: lhs), b = timelineTime(of: rhs)
            switch (a, b) {
            case let (a?, b?) where a != b: return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.capturedAt == rhs.capturedAt ? lhs.id.uuidString < rhs.id.uuidString : lhs.capturedAt < rhs.capturedAt
            }
        }
    }

    public func photo(_ id: UUID) -> MeetingPhoto? { photos?.first { $0.id == id } }

    /// Photos worth more than a second look this far from the recordings (before the first or after
    /// the last) are still shown on the timeline; anything farther is a photo of another moment.
    public static let photoTimelineMargin: TimeInterval = 300

    /// Where a photo falls on the conversation's timeline, in seconds, the way bookmarks are placed:
    ///
    /// 1. Taken during a recording on the timeline's own clock (`time` without `trackID`): that time.
    /// 2. Taken during a recording (`trackID`): that recording's placement (`timelinePlacement`, with
    ///    its clock drift), else the clock prior a multipoint link stored on it, applied to `time`.
    /// 3. Otherwise its capture moment, read by the clock of a placed recording the same device made
    ///    (its start and placement), so a photo from the iPhone lines up with the Mac's audio.
    /// 4. Otherwise its capture moment against the timeline's wall-clock start.
    ///
    /// Nil for a conversation without a known start, or a photo of another moment (more than
    /// `photoTimelineMargin` outside the recordings).
    public func timelineTime(of photo: MeetingPhoto) -> TimeInterval? {
        if let time = photo.time, time.isFinite {
            guard let trackID = photo.trackID else { return time }
            if let placement = timelinePlacement(of: trackID) { return placement.offset + placement.rate * time }
            if let prior = tracks.first(where: { $0.id == trackID })?.alignment?.clockOffset, prior.isFinite { return prior + time }
        }
        let span = wallClockSpan()
        func nearby(_ value: TimeInterval) -> TimeInterval? {
            guard value.isFinite else { return nil }
            guard let span, let zero = knownTimelineStart() else { return value }
            let lower = span.start.timeIntervalSince(zero) - Self.photoTimelineMargin
            let upper = span.end.timeIntervalSince(zero) + Self.photoTimelineMargin
            return value >= lower && value <= upper ? value : nil
        }
        if let origin = photo.origin {
            for track in tracks where origin.recorded(track) {
                guard let start = track.startedAt, let placement = timelinePlacement(of: track.id) else { continue }
                return nearby(placement.offset + placement.rate * photo.capturedAt.timeIntervalSince(start))
            }
        }
        guard let zero = knownTimelineStart() else { return nil }
        return nearby(photo.capturedAt.timeIntervalSince(zero))
    }

    // MARK: Editing

    /// Adds a stored photo, recorded in Version History.
    public mutating func addPhoto(_ photo: MeetingPhoto) {
        guard self.photo(photo.id) == nil else { return }
        photos = (photos ?? []) + [photo]
        revisions.append(MeetingRevision(field: "photo:\(photo.id.uuidString)", oldValue: "", newValue: "added"))
        updatedAt = Date()
    }

    /// Deletes a photo, keeping its file and record so it can be put back. Recorded in Version History.
    public mutating func removePhoto(_ id: UUID, at date: Date = Date()) {
        guard let index = photos?.firstIndex(where: { $0.id == id }), photos?[index].removedAt == nil else { return }
        photos?[index].removedAt = date
        revisions.append(MeetingRevision(date: date, field: "photo:\(id.uuidString)", oldValue: "present", newValue: "removed"))
        updatedAt = Date()
    }

    /// Puts a deleted photo back where it was. Recorded in Version History.
    public mutating func restorePhoto(_ id: UUID) {
        guard let index = photos?.firstIndex(where: { $0.id == id }), photos?[index].removedAt != nil else { return }
        photos?[index].removedAt = nil
        revisions.append(MeetingRevision(field: "photo:\(id.uuidString)", oldValue: "removed", newValue: "present"))
        updatedAt = Date()
    }

    /// The person's caption; empty clears it. Recorded in Version History.
    public mutating func setPhotoCaption(_ id: UUID, caption: String) {
        guard let index = photos?.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String? = trimmed.isEmpty ? nil : trimmed
        guard photos?[index].caption != value else { return }
        revisions.append(MeetingRevision(field: "photo-caption:\(id.uuidString)", oldValue: photos?[index].caption ?? "", newValue: value ?? ""))
        photos?[index].caption = value
        updatedAt = Date()
    }

    /// Takes a photo out of the summary, or lets summaries use it again. Removing it also takes it
    /// out of the current summary's sections at once; putting it back waits for the next summary.
    public mutating func setPhotoHiddenFromSummary(_ id: UUID, hidden: Bool) {
        guard let index = photos?.firstIndex(where: { $0.id == id }) else { return }
        photos?[index].hiddenFromSummary = hidden ? true : nil
        if hidden, var summary {
            for section in summary.sections.indices { summary.sections[section].photoIDs?.removeAll { $0 == id } }
            for section in summary.sections.indices where summary.sections[section].photoIDs?.isEmpty == true { summary.sections[section].photoIDs = nil }
            self.summary = summary
        }
        updatedAt = Date()
    }

    /// Stores what processing found for each photo. Only analysis changes: the person's caption and
    /// choices stay.
    public mutating func applyPhotoAnalyses(_ analyses: [UUID: PhotoAnalysis]) {
        guard var current = photos, !analyses.isEmpty else { return }
        var changed = false
        for index in current.indices {
            guard let analysis = analyses[current[index].id], current[index].analysis != analysis else { continue }
            current[index].analysis = analysis; changed = true
        }
        if changed { photos = current; updatedAt = Date() }
    }

    /// The photos a summary section shows: the ones it references that still exist and aren't deleted
    /// or hidden, in the section's order.
    public func photos(in section: SummarySection) -> [MeetingPhoto] {
        (section.photoIDs ?? []).compactMap { id in photo(id).flatMap { $0.isRemoved || $0.hiddenFromSummary == true ? nil : $0 } }
    }

    /// Photos taken while this device recorded the conversation, on the timeline's own clock (no
    /// recording named), are moved onto `track`, in its time, so they follow its placement once it
    /// joins an existing timeline as another source. `except` are photos that were there before.
    public mutating func movePhotos(onto track: RecordingTrack, except: Set<UUID>) {
        guard var current = photos else { return }
        var changed = false
        for index in current.indices where !except.contains(current[index].id) && current[index].trackID == nil {
            guard let time = current[index].time else { continue }
            current[index].trackID = track.id
            current[index].time = max(0, time - (track.offset ?? 0))
            changed = true
        }
        if changed { photos = current; updatedAt = Date() }
    }
}
