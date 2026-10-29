import Foundation

public struct MeetingMergeResult: Sendable {
    public var meeting: Meeting
    public var warnings: [String]
}

/// A deterministic three-way merge. Independent changes survive; competing values remain in history.
/// It is commutative (`merge(base, a, b) == merge(base, b, a)`) and idempotent (`merge(base, m, m) == m`).
///
/// Without a common ancestor (two devices created the same conversation, as in a multipoint recording),
/// the merge runs against a neutral skeleton in which a default or empty value counts as unset: a value
/// set on one side wins with no conflict, notes are merged paragraph by paragraph, and a conflict is
/// recorded only when both sides set different values.
public enum MeetingMerge {
    public static func merge(base: Meeting?, local: Meeting, remote: Meeting) -> MeetingMergeResult {
        precondition(local.id == remote.id && (base == nil || base?.id == local.id), "Only versions of the same meeting can be merged")
        if local == remote { return MeetingMergeResult(meeting: local, warnings: []) }
        var result = local
        var conflicts: [MeetingRevision] = []
        /// What conflicted, for the warnings, which name the merged title so either order reads the same.
        var conflicted = Set<String>()
        func record(_ field: String, _ smaller: String, _ larger: String) {
            let id = SyncEncoding.uuid("\(local.id):\(field):\(smaller):\(larger)")
            conflicts.append(MeetingRevision(id: id, date: max(local.updatedAt, remote.updatedAt), field: "sync:\(field)", oldValue: smaller, newValue: larger))
        }
        func choose<T: Encodable & Equatable>(_ field: String, _ lhs: T, _ rhs: T, _ ancestor: T?) -> T {
            if lhs == rhs { return lhs }
            if let ancestor {
                if lhs == ancestor { return rhs }
                if rhs == ancestor { return lhs }
            }
            let a = SyncEncoding.string(lhs), b = SyncEncoding.string(rhs)
            record(field, min(a, b), max(a, b))
            conflicted.insert(field)
            return a > b ? lhs : rhs
        }
        /// The ancestor for a field with no common ancestor: a side holding the default is unset, so the
        /// other side's value wins; two defaults resolve to one of them, and two set values conflict.
        func unset<T: Encodable & Equatable>(_ lhs: T, _ rhs: T, isDefault: (T) -> Bool, otherwise: T) -> T {
            switch (isDefault(lhs), isDefault(rhs)) {
            case (true, true): return SyncEncoding.string(lhs) <= SyncEncoding.string(rhs) ? lhs : rhs
            case (true, false): return lhs
            case (false, true): return rhs
            case (false, false): return otherwise
            }
        }
        /// Derived values (processing status and its message) never conflict: with no ancestor, the
        /// value ranked higher wins.
        func ranked<T: Encodable & Equatable>(_ lhs: T, _ rhs: T, _ rank: (T) -> Int) -> T {
            let a = (rank(lhs), SyncEncoding.string(lhs)), b = (rank(rhs), SyncEncoding.string(rhs))
            return a > b ? lhs : rhs
        }
        func items<T: Codable & Equatable & Identifiable>(_ field: String, _ lhs: [T], _ rhs: [T], _ ancestor: [T], allowsRemoval: Bool = false) -> [T] {
            var order: [T.ID] = []
            for item in ancestor where !order.contains(item.id) { order.append(item.id) }
            let added = Set((lhs + rhs).map(\.id)).subtracting(order).sorted { String(describing: $0) < String(describing: $1) }
            order += added
            return order.compactMap { id in
                let a = lhs.first { $0.id == id }, b = rhs.first { $0.id == id }, old = ancestor.first { $0.id == id }
                if allowsRemoval {
                    // With no common ancestor nothing was removed: an item on one side was added there.
                    return choose("\(field):\(id)", a, b, .some(old))
                }
                if let a, let b { return choose("\(field):\(id)", a, b, old) }
                return a ?? b ?? old
            }
        }
        result.title = choose("title", local.title, remote.title,
                              base?.title ?? unset(local.title, remote.title, isDefault: Meeting.isPlaceholderTitle, otherwise: ""))
        // Two devices that started the same conversation keep the earlier start.
        result.date = choose("date", local.date, remote.date, base?.date ?? max(local.date, remote.date))
        result.$kind = choose("kind", local.$kind, remote.$kind,
                              base?.$kind ?? unset(local.$kind, remote.$kind, isDefault: { $0.isKnown && $0.wrappedValue == .auto }, otherwise: Extensible(wrappedValue: .auto)))
        let notes: MergedNotes
        if let base {
            notes = choose("notes", MergedNotes(local), MergedNotes(remote), MergedNotes(base))
        } else {
            notes = MergedNotes.union(MergedNotes(local), MergedNotes(remote), meetingID: local.id) { id, smaller, larger in
                record("notes:\(id)", smaller, larger)
                conflicted.insert("notes")
            }
        }
        result.notes = notes.text; result.timedNotes = notes.anchors
        result.folderID = choose("folder", local.folderID, remote.folderID, base.map(\.folderID) ?? unset(local.folderID, remote.folderID, isDefault: { $0 == nil }, otherwise: nil))
        result.templateID = choose("template", local.templateID, remote.templateID, base.map(\.templateID) ?? unset(local.templateID, remote.templateID, isDefault: { $0 == nil }, otherwise: nil))
        result.$placement = choose("placement", local.$placement, remote.$placement,
                                   base?.$placement ?? unset(local.$placement, remote.$placement, isDefault: \.isAbsent, otherwise: ExtensibleOptional(wrappedValue: nil)))
        if local.tags != nil || remote.tags != nil {
            let old = Set(base?.tags ?? []), a = Set(local.tags ?? []), b = Set(remote.tags ?? [])
            let removed = old.subtracting(a).union(old.subtracting(b))
            result.tags = old.subtracting(removed).union(a.subtracting(old)).union(b.subtracting(old)).sorted()
        }
        result.tracks = items("track", local.tracks, remote.tracks, base?.tracks ?? [])
        result.transcripts = items("transcript-run", local.transcripts, remote.transcripts, base?.transcripts ?? [])
        result.speakers = items("speaker", local.speakers, remote.speakers, base?.speakers ?? [])
        result.highlights = items("highlight", local.highlights, remote.highlights, base?.highlights ?? [], allowsRemoval: true)
        // Photos are originals: every copy's survive, merged field by field (Photos.swift).
        if local.photos != nil || remote.photos != nil {
            result.photos = MeetingPhoto.mergedList(base: base?.photos ?? [], local: local.photos ?? [], remote: remote.photos ?? []) { field, smaller, larger in
                record(field, smaller, larger)
                conflicted.insert("a photo")
            }
        }
        result.speakerMatches = items("speaker-match", local.speakerMatches ?? [], remote.speakerMatches ?? [], base?.speakerMatches ?? [])
        if result.speakerMatches?.isEmpty == true { result.speakerMatches = nil }
        // A multipoint link made on one Mac lets the recorder's recording join on another.
        if local.companions != nil || remote.companions != nil {
            result.companions = items("companion", local.companions ?? [], remote.companions ?? [], base?.companions ?? [])
        }
        if local.sourceSuggestions != nil || remote.sourceSuggestions != nil {
            result.sourceSuggestions = choose("source-suggestions", local.sourceSuggestions, remote.sourceSuggestions,
                base.map(\.sourceSuggestions) ?? unset(local.sourceSuggestions, remote.sourceSuggestions, isDefault: { ($0 ?? []).isEmpty }, otherwise: nil))
        }
        // Audio alignments are measurements, not edits: keep every pair, newest measurement wins.
        var measured: [String: TrackAudioAlignment] = [:]
        for record in (local.audioAlignments ?? []) + (remote.audioAlignments ?? []) {
            guard let current = measured[record.id] else { measured[record.id] = record; continue }
            let newer = (record.algorithmVersion, record.measuredAt), old = (current.algorithmVersion, current.measuredAt)
            if newer > old || (newer == old && SyncEncoding.string(record) > SyncEncoding.string(current)) { measured[record.id] = record }
        }
        result.audioAlignments = measured.isEmpty ? nil : measured.values.sorted { $0.id < $1.id }
        // These are one derived view. Mixing a transcript with another run's clock transform
        // would change playback/highlight timing, and its review candidates would be invalid.
        let localView = MergedTranscriptView(local), remoteView = MergedTranscriptView(remote)
        let view = choose("transcript-view", localView, remoteView,
                          base.map(MergedTranscriptView.init) ?? unset(localView, remoteView, isDefault: \.isEmpty, otherwise: MergedTranscriptView()))
        result.unifiedTranscript = view.segments
        result.alignmentReports = view.alignments
        result.correctionTransferIssues = view.correctionIssues
        result.fusionSummary = view.fusionSummary
        result.backgroundPassages = view.backgroundPassages
        if local.includesBackgroundAudio != nil || remote.includesBackgroundAudio != nil {
            result.includesBackgroundAudio = choose("background-audio", local.includesBackgroundAudio, remote.includesBackgroundAudio,
                base.map(\.includesBackgroundAudio) ?? unset(local.includesBackgroundAudio, remote.includesBackgroundAudio, isDefault: { $0 == nil }, otherwise: nil))
        }
        result.summary = choose("summary", local.summary, remote.summary, base.map(\.summary) ?? unset(local.summary, remote.summary, isDefault: { $0 == nil }, otherwise: nil))
        // Completion is a separate user decision from generated prose; exact task+owner identity survives.
        if var summary = result.summary {
            for index in summary.actionItems.indices {
                let item = summary.actionItems[index]
                let a = local.summary?.actionItems.first { $0.text == item.text && $0.owner == item.owner }
                let b = remote.summary?.actionItems.first { $0.text == item.text && $0.owner == item.owner }
                let old = base?.summary?.actionItems.first { $0.text == item.text && $0.owner == item.owner }
                if let a, let b {
                    let ancestor = base == nil ? unset(a.completed, b.completed, isDefault: { !$0 }, otherwise: false) : old?.completed
                    summary.actionItems[index].completed = choose("action:\(item.text)", a.completed, b.completed, ancestor)
                }
            }
            result.summary = summary
        }
        // Requests aren't edits: every device's requests survive, a finished outcome is final, and
        // the newest claim wins, so two Macs never both keep one.
        result.processingRequests = ProcessingRequest.merged(local.processingRequests, remote.processingRequests)
        if let base {
            result.$status = choose("status", local.$status, remote.$status, base.$status)
            result.errorMessage = choose("processing-message", local.errorMessage, remote.errorMessage, base.errorMessage)
        } else {
            result.$status = ranked(local.$status, remote.$status) { $0.isKnown ? Self.statusRank($0.wrappedValue) : Self.statusRank(.imported) }
            result.errorMessage = ranked(local.errorMessage, remote.errorMessage) { $0 == nil ? 0 : 1 }
        }
        // Fields a newer Daybook added, key by key. A conflict keeps the other value in History, as a
        // known field's does, but without a notice: this version can't say what it is.
        result.unknownFields = UnknownFields.merged(base: base?.unknownFields, local.unknownFields, remote.unknownFields) { key, smaller, larger in
            record("unknown:\(key)", smaller, larger)
        }
        var revisions: [UUID: MeetingRevision] = [:]
        for revision in (base?.revisions ?? []) + local.revisions + remote.revisions + conflicts {
            if let old = revisions[revision.id], SyncEncoding.string(old) > SyncEncoding.string(revision) { continue }
            revisions[revision.id] = revision
        }
        result.revisions = revisions.values.sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date }
        result.updatedAt = max(local.updatedAt, remote.updatedAt)
        let warnings = conflicted.map { "Concurrent edits to \($0) in \(result.title) were preserved in History." }
        return MeetingMergeResult(meeting: result, warnings: warnings.sorted())
    }

    /// With no common ancestor, the status further along wins.
    private static func statusRank(_ status: MeetingStatus) -> Int {
        switch status {
        case .draft: return 0
        case .imported: return 1
        case .failed: return 2
        case .ready: return 3
        case .summarizing: return 4
        case .transcribing: return 5
        case .recording: return 6
        }
    }
}

extension Meeting {
    /// This snapshot with the photos (and summary sections' photo IDs) of `parent`, when it carries none
    /// while its parent did: it was written by a Daybook that predates photos, which drops them on edit.
    func restoringPhotos(from parent: Meeting) -> Meeting {
        guard photos == nil, let parentPhotos = parent.photos else { return self }
        var result = self
        result.photos = parentPhotos
        if var summary = result.summary, let previous = parent.summary {
            for index in summary.sections.indices where summary.sections[index].photoIDs == nil {
                let id = summary.sections[index].id
                if let photoIDs = previous.sections.first(where: { $0.id == id })?.photoIDs { summary.sections[index].photoIDs = photoIDs }
            }
            result.summary = summary
        }
        return result
    }

    /// The titles Daybook gives a conversation before anyone names it; with no common ancestor, a
    /// title someone chose wins over one of these.
    static func isPlaceholderTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "Untitled meeting" || trimmed == "Untitled Conversation"
    }
}

private struct MergedTranscriptView: Codable, Equatable {
    var segments: [TranscriptSegment] = []
    var alignments: [TrackAlignment] = []
    var correctionIssues: [CorrectionTransferIssue]?
    var fusionSummary: FusionSummary?
    var backgroundPassages: [TranscriptSegment]?
    init() {}
    init(_ meeting: Meeting) {
        segments = meeting.unifiedTranscript; alignments = meeting.alignmentReports
        correctionIssues = meeting.correctionTransferIssues; fusionSummary = meeting.fusionSummary
        backgroundPassages = meeting.backgroundPassages
    }
    var isEmpty: Bool { segments.isEmpty && alignments.isEmpty && correctionIssues == nil && fusionSummary == nil && backgroundPassages == nil }
}
private struct MergedNotes: Codable, Equatable {
    var text: String
    var anchors: [TimedNote]?
    init(_ meeting: Meeting) { text = meeting.notes; anchors = meeting.timedNotes }
    init(text: String, anchors: [TimedNote]?) { self.text = text; self.anchors = anchors }

    /// One nonempty paragraph, with its anchor when the notes have one for it.
    private struct Paragraph {
        var id: UUID?
        var time: TimeInterval?
        var text: String
        /// Its own time, or the time of the last timed paragraph before it; nil before any.
        var effectiveTime: TimeInterval?
    }

    private var paragraphs: [Paragraph] {
        var anchors = self.anchors ?? []
        var last: TimeInterval?
        return text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.map { text in
            var paragraph = Paragraph(text: text)
            if let index = anchors.firstIndex(where: { $0.text == text }) {
                let anchor = anchors.remove(at: index)
                paragraph.id = anchor.id; paragraph.time = anchor.time
            }
            last = paragraph.time ?? last
            paragraph.effectiveTime = last
            return paragraph
        }
    }

    /// Two versions of the notes with no common ancestor, paragraph by paragraph: every paragraph
    /// either side has, once (the same anchor ID, else the same text), the other side's paragraphs
    /// placed among them by recording time. When one side holds every paragraph of the other, it's
    /// kept exactly. The same anchor with different text keeps one and reports the other.
    static func union(_ lhs: MergedNotes, _ rhs: MergedNotes, meetingID: UUID,
                      conflict: (_ id: UUID, _ smaller: String, _ larger: String) -> Void) -> MergedNotes {
        if lhs == rhs { return lhs }
        // Which side leads depends only on the content, so the result doesn't depend on the order.
        let (primary, secondary) = SyncEncoding.string(lhs) <= SyncEncoding.string(rhs) ? (lhs, rhs) : (rhs, lhs)
        let first = primary.paragraphs, second = secondary.paragraphs
        var unmatchedFirst = Array(first.indices)
        var added: [Paragraph] = []
        for paragraph in second {
            if let id = paragraph.id, let position = unmatchedFirst.firstIndex(where: { first[$0].id == id }) {
                let match = first[unmatchedFirst.remove(at: position)]
                if match.text != paragraph.text { conflict(id, min(match.text, paragraph.text), max(match.text, paragraph.text)) }
            } else if let position = unmatchedFirst.firstIndex(where: { first[$0].text == paragraph.text }) {
                unmatchedFirst.remove(at: position)
            } else {
                added.append(paragraph)
            }
        }
        if added.isEmpty { return primary }
        if unmatchedFirst.isEmpty && first.allSatisfy({ paragraph in second.contains { $0.text == paragraph.text } }) { return secondary }
        // Interleave: each side keeps its own order; the other side's paragraphs go in by time.
        var merged: [Paragraph] = []
        var next = added.makeIterator(), pending = next.next()
        for paragraph in first {
            while let candidate = pending, (candidate.effectiveTime ?? -.infinity) < (paragraph.effectiveTime ?? -.infinity) {
                merged.append(candidate); pending = next.next()
            }
            merged.append(paragraph)
        }
        while let candidate = pending { merged.append(candidate); pending = next.next() }
        let anchored = lhs.anchors != nil || rhs.anchors != nil
        var seen: [String: Int] = [:]
        let anchors = merged.map { paragraph -> TimedNote in
            let occurrence = seen[paragraph.text, default: 0]; seen[paragraph.text] = occurrence + 1
            return TimedNote(id: paragraph.id ?? SyncEncoding.uuid("\(meetingID):note:\(paragraph.text):\(occurrence)"), time: paragraph.time, text: paragraph.text)
        }
        return MergedNotes(text: merged.map(\.text).joined(separator: "\n"), anchors: anchored ? anchors : nil)
    }
}

enum SyncEncoding {
    static func data<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func string<T: Encodable>(_ value: T) -> String {
        (try? data(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "<unencodable value>"
    }
    static func uuid(_ seed: String) -> UUID {
        let hex = String(AudioDigest.sha256(data: Data(seed.utf8)).prefix(32))
        let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { range in
            String(hex[hex.index(hex.startIndex, offsetBy: range.lowerBound)..<hex.index(hex.startIndex, offsetBy: range.upperBound)])
        }
        return UUID(uuidString: parts.joined(separator: "-"))!
    }
}
