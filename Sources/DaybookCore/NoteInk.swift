import Foundation

// Handwriting in the notes (docs/iphone.md, "Handwriting"). A block of ink is one paragraph of `Meeting.notes`: its
// `id` is that paragraph's `TimedNote.id`, and the paragraph's text is what was read from the ink. Everything that
// reads the notes (search, summaries, exports, the Mac) reads words, with no idea ink exists; the iPhone's editor
// draws the strokes in that paragraph's place. The strokes travel with the conversation, like the notes they're part of.

/// One block of handwriting.
public struct NoteInk: Codable, Equatable, Identifiable, Sendable {
    /// The `TimedNote.id` of its paragraph.
    public var id: UUID
    /// `PKDrawing.dataRepresentation()`, in points of the column it was written in.
    public var drawing: Data
    /// The column it was written in: narrower columns draw it scaled to fit, and it's never enlarged.
    public var width: Double
    public var height: Double
    /// What was read from the ink. Nil until recognition has run; empty for a sketch with no words in it.
    public var recognized: String?
    public var updatedAt: Date
    /// When it was deleted or turned into typed words. Its strokes go; the record stays, so an older copy of the
    /// conversation can't bring it back.
    public var removedAt: Date?
    /// Keys a newer Daybook wrote that this version doesn't know, written back as they came.
    public var unknownFields = UnknownFields()

    public init(id: UUID = UUID(), drawing: Data, width: Double, height: Double, recognized: String? = nil, updatedAt: Date = Date()) {
        self.id = id
        self.drawing = drawing
        self.width = width
        self.height = height
        self.recognized = recognized
        self.updatedAt = updatedAt
    }

    /// The paragraph that stands for ink no words were read from: not yet, or a sketch.
    public static let placeholder = "Handwriting"

    /// Its words as one paragraph of the notes (one paragraph is one line).
    public var paragraphText: String { Self.paragraph(for: recognized) }

    public static func paragraph(for recognized: String?) -> String {
        let flat = (recognized ?? "").components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return flat.isEmpty ? placeholder : flat
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, drawing, width, height, recognized, updatedAt, removedAt
    }
    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        drawing = try values.decode(Data.self, forKey: .drawing)
        width = try values.decode(Double.self, forKey: .width)
        height = try values.decode(Double.self, forKey: .height)
        recognized = try values.decodeIfPresent(String.self, forKey: .recognized)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        removedAt = try values.decodeIfPresent(Date.self, forKey: .removedAt)
        unknownFields = try UnknownFields(from: decoder, known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(drawing, forKey: .drawing)
        try values.encode(width, forKey: .width)
        try values.encode(height, forKey: .height)
        try values.encodeIfPresent(recognized, forKey: .recognized)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encodeIfPresent(removedAt, forKey: .removedAt)
        try unknownFields.encode(to: encoder)
    }

    /// Every block either copy has (ink is an original, so none is dropped). A block both changed keeps the newer
    /// strokes; the same moment on both sides picks the same one on every device. Order follows the ancestor, then new
    /// blocks by ID, so both sides agree.
    static func mergedList(base: [NoteInk], local: [NoteInk], remote: [NoteInk]) -> [NoteInk] {
        var order: [UUID] = []
        for ink in base where !order.contains(ink.id) { order.append(ink.id) }
        order += Set((local + remote).map(\.id)).subtracting(order).sorted { $0.uuidString < $1.uuidString }
        return order.compactMap { id in
            let a = local.first { $0.id == id }, b = remote.first { $0.id == id }
            guard let a, let b else { return a ?? b ?? base.first { $0.id == id } }
            if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt ? a : b }
            return SyncEncoding.string(a) >= SyncEncoding.string(b) ? a : b
        }
    }
}

extension NoteTimeline {
    /// The notes with a new paragraph whose anchor takes `id`: after the nonempty paragraph at `index`, before the first
    /// when it's -1, or at the end when nil. The rest of the text is left as it was, blank lines and all.
    public static func inserting(_ paragraph: String, id: UUID, time: TimeInterval?, after index: Int?, in text: String,
                                 anchors saved: [TimedNote]?) -> (text: String, anchors: [TimedNote]) {
        var anchors = Self.anchors(saved, text: text)
        let clean = paragraph.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let note = TimedNote(id: id, time: time, text: clean)
        var lines = text.components(separatedBy: "\n")
        let paragraphs = lines.indices.filter { !lines[$0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if index == -1, let first = paragraphs.first {
            lines.insert(clean, at: first)
            anchors.insert(note, at: 0)
            return (lines.joined(separator: "\n"), anchors)
        }
        if let index, index >= 0, index < paragraphs.count {
            lines.insert(clean, at: paragraphs[index] + 1)
            anchors.insert(note, at: min(index + 1, anchors.count))
            return (lines.joined(separator: "\n"), anchors)
        }
        var updated = text
        if !updated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !updated.hasSuffix("\n") { updated += "\n" }
        if updated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { updated = "" }
        anchors.append(note)
        return (updated + clean, anchors)
    }

    /// The ink drawn in each nonempty paragraph of `text`, in order; nil for a paragraph of typed words. A block belongs
    /// to the paragraph anchored by its ID.
    public static func inkPlacements(_ ink: [NoteInk]?, anchors saved: [TimedNote]?, text: String) -> [NoteInk?] {
        let anchors = Self.anchors(saved, text: text)
        let ink = (ink ?? []).filter { $0.removedAt == nil }
        guard !ink.isEmpty else { return Array(repeating: nil, count: anchors.count) }
        let byID = Dictionary(ink.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return anchors.map { byID[$0.id] }
    }
}

/// What taking a block out left behind, for putting it back without touching anything else in the notes.
public struct InkRemoval: Equatable, Sendable {
    public var block: NoteInk
    public var paragraph: String
    public var time: TimeInterval?
    /// The nonempty paragraph it followed; -1 when it was the first.
    public var after: Int
    /// Its paragraph stayed, as typed words.
    public var keptWords: Bool
}

extension Meeting {
    /// The ink drawn in each nonempty paragraph of the notes, in order.
    public func inkPlacements() -> [NoteInk?] { NoteTimeline.inkPlacements(ink, anchors: timedNotes, text: notes) }

    /// Adds a block of handwriting as a new paragraph: after the nonempty paragraph at `index`, or at the end when nil.
    public mutating func addInk(_ block: NoteInk, after index: Int?, time: TimeInterval? = nil) {
        guard ink?.contains(where: { $0.id == block.id }) != true else { return }
        let applied = NoteTimeline.inserting(block.paragraphText, id: block.id, time: time, after: index, in: notes, anchors: timedNotes)
        notes = applied.text
        timedNotes = applied.anchors
        ink = (ink ?? []) + [block]
        updatedAt = Date()
    }

    /// Stores a block's new strokes or words. Its paragraph follows only when the words themselves changed, so a
    /// correction typed on another device survives more strokes that read the same.
    public mutating func updateInk(_ block: NoteInk) {
        // A result landing just after the block was deleted doesn't bring it back.
        guard let index = ink?.firstIndex(where: { $0.id == block.id }), let current = ink?[index], current.removedAt == nil else { return }
        var block = block
        block.unknownFields = current.unknownFields
        guard current != block else { return }
        let wordsChanged = current.paragraphText != block.paragraphText
        ink?[index] = block
        if wordsChanged {
            let applied = NoteTimeline.applying(SharedNote(id: block.id, text: block.paragraphText, time: nil), to: notes, anchors: timedNotes)
            notes = applied.text
            timedNotes = applied.anchors
        }
        updatedAt = Date()
    }

    /// Blocks written while recording, filed with their paragraphs. A block already here stays as it is.
    public mutating func adoptInk(_ blocks: [NoteInk]) {
        let known = Set((ink ?? []).map(\.id))
        let fresh = blocks.filter { !known.contains($0.id) }
        guard !fresh.isEmpty else { return }
        ink = (ink ?? []) + fresh
        updatedAt = Date()
    }

    /// Takes a block out: its paragraph goes, or stays as typed words, as it reads now, when `keepingWords` and there are
    /// any. The strokes go; the result puts them back (`restoreInk`).
    @discardableResult
    public mutating func removeInk(_ id: UUID, keepingWords: Bool, at date: Date = Date()) -> InkRemoval? {
        guard let index = ink?.firstIndex(where: { $0.id == id }), let block = ink?[index], block.removedAt == nil else { return nil }
        let anchors = NoteTimeline.anchors(timedNotes, text: notes)
        let position = anchors.firstIndex { $0.id == id }
        let paragraph = position.map { anchors[$0].text } ?? block.paragraphText
        let keeps = keepingWords && position != nil && paragraph != NoteInk.placeholder
        if !keeps, position != nil {
            let applied = NoteTimeline.applying(SharedNote(id: id, text: paragraph, time: nil, deleted: true), to: notes, anchors: timedNotes)
            notes = applied.text
            timedNotes = applied.anchors
        }
        ink?[index].drawing = Data()
        ink?[index].removedAt = date
        ink?[index].updatedAt = date
        updatedAt = Date()
        return InkRemoval(block: block, paragraph: paragraph, time: position.flatMap { anchors[$0].time }, after: (position ?? anchors.count) - 1, keptWords: keeps)
    }

    /// Puts a block back: its strokes, and its paragraph if that went. Anything else written since stays.
    public mutating func restoreInk(_ removal: InkRemoval) {
        if !removal.keptWords, !NoteTimeline.anchors(timedNotes, text: notes).contains(where: { $0.id == removal.block.id }) {
            let applied = NoteTimeline.inserting(removal.paragraph, id: removal.block.id, time: removal.time, after: removal.after, in: notes, anchors: timedNotes)
            notes = applied.text
            timedNotes = applied.anchors
        }
        var restored = removal.block
        restored.removedAt = nil
        restored.updatedAt = Date()
        if let index = ink?.firstIndex(where: { $0.id == restored.id }) {
            ink?[index] = restored
        } else {
            ink = (ink ?? []) + [restored]
        }
        updatedAt = Date()
    }

    /// A paragraph holding exactly the words of a block no paragraph holds becomes that block's again. A Version History
    /// restore or a merge can give a paragraph a new anchor. Ink nothing has read has no words to go by.
    public mutating func reanchorInk() {
        let live = (ink ?? []).filter { $0.removedAt == nil }
        guard !live.isEmpty else { return }
        var anchors = NoteTimeline.anchors(timedNotes, text: notes)
        let held = Set(anchors.map(\.id)), blocks = Set(live.map(\.id))
        var waiting = live.filter { !held.contains($0.id) && $0.paragraphText != NoteInk.placeholder }.sorted { $0.id.uuidString < $1.id.uuidString }
        guard !waiting.isEmpty else { return }
        var changed = false
        for index in anchors.indices where !blocks.contains(anchors[index].id) {
            guard let match = waiting.firstIndex(where: { $0.paragraphText == anchors[index].text }) else { continue }
            anchors[index].id = waiting.remove(at: match).id
            changed = true
        }
        if changed { timedNotes = anchors }
    }

    /// A merge keeps one copy's notes whole, so a block the other copy wrote can lose its paragraph while its strokes
    /// survive. It goes back at the end, in an order both devices agree on, or there'd be no way to reach the strokes.
    mutating func keepInkParagraphs(local: Meeting, remote: Meeting) {
        let live = (ink ?? []).filter { $0.removedAt == nil }.sorted { $0.id.uuidString < $1.id.uuidString }
        guard !live.isEmpty else { return }
        reanchorInk()
        let held = Set(NoteTimeline.anchors(timedNotes, text: notes).map(\.id))
        let copies = (local.timedNotes ?? []) + (remote.timedNotes ?? [])
        for block in live where !held.contains(block.id) {
            // Only a paragraph one of the copies had: a restore to before this ink was written stays that way.
            guard let anchor = copies.filter({ $0.id == block.id }).min(by: { $0.text < $1.text }) else { continue }
            let applied = NoteTimeline.inserting(anchor.text, id: block.id, time: anchor.time, after: nil, in: notes, anchors: timedNotes)
            notes = applied.text
            timedNotes = applied.anchors
        }
    }
}
