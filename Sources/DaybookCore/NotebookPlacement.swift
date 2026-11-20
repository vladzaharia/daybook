import Foundation

/// A writing passage of a notebook page as a summary reads it: the words shown (the person's correction while it stands,
/// else what was read), on which page, and when on the conversation's timeline.
public struct PageWriting: Equatable, Sendable {
    public var passageID: UUID
    /// 1-based, among the visible pages.
    public var page: Int
    /// Seconds on the conversation's timeline; nil when it was written outside a recording.
    public var time: TimeInterval?
    /// How long writing it took.
    public var duration: TimeInterval
    /// The words with line breaks as " / ", cut at `NotebookPlacement.writingLength` characters.
    public var text: String
}

extension NotebookPage {
    /// The passages a summary may read: those of a reading made from the page's current drawing by this version's grouping. A
    /// reading not made yet, or of strokes since replaced, may hold words the person has erased, so it is not summary input.
    public var summaryPassages: [NotebookPassage] { isReadingCurrent ? passages : [] }
}

extension Meeting {
    /// The writing on pages a summary may use: each visible page not taken out of summaries whose reading is current for its
    /// drawing, each passage that is known to be writing (a kind a newer Daybook wrote is never summary input) with words, in time order (timeline time, then page, then place); passages without a time come after the timed ones, in page
    /// order. Words a typed note already has are left out.
    public func pageWriting() -> [PageWriting] {
        let typed = notes.components(separatedBy: .newlines).map(NotebookPlacement.normalized).filter { !$0.isEmpty }
        var found: [(writing: PageWriting, y: Double, x: Double)] = []
        for (index, page) in visiblePages.enumerated() where page.hiddenFromSummary != true {
            for passage in page.summaryPassages where passage.kind == .writing && passage.$kind.isKnown {
                let flat = (page.words(of: passage) ?? "").split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " / ")
                guard !flat.isEmpty else { continue }
                let key = NotebookPlacement.normalized(flat)
                // Whole words only: "call ann" is not in "recall anne's budget".
                guard !typed.contains(where: { $0 == key || (key.count >= 8 && (" " + $0 + " ").contains(" " + key + " ")) }) else { continue }
                let text = flat.count > NotebookPlacement.writingLength ? String(flat.prefix(NotebookPlacement.writingLength)) + "…" : flat
                found.append((PageWriting(passageID: passage.id, page: index + 1, time: timelineTime(of: passage, on: page),
                                          duration: passage.duration, text: text), passage.y, passage.x))
            }
        }
        return found.sorted { lhs, rhs in
            (lhs.writing.time ?? .infinity, lhs.writing.page, lhs.y, lhs.x) < (rhs.writing.time ?? .infinity, rhs.writing.page, rhs.y, rhs.x)
        }.map(\.writing)
    }

    /// What a summary reads from the notebook, to tell whether it changed: per page its hidden flag and, per passage, its ID,
    /// kind, the words shown, its time, and what was found in a sketch. Reading the same strokes again gives the same value.
    var notebookSummaryInputs: [String] {
        visiblePages.flatMap { page in
            [page.id.uuidString + (page.hiddenFromSummary == true ? " hidden" : "")] + page.summaryPassages.map { passage in
                let found = page.sketch(for: passage)?.analysis
                return [passage.id.uuidString, passage.kind.rawValue, page.words(of: passage) ?? "",
                        timelineTime(of: passage, on: page).map { String($0) } ?? "", found?.caption ?? "",
                        found?.recognizedText ?? "", found?.isInformative == true ? "informative" : ""].joined(separator: "|")
            }
        }
    }

    /// A short digest of `notebookSummaryInputs`: what a summary stores of the notebook it was written from.
    public var notebookDigest: String {
        String(AudioDigest.sha256(data: Data(notebookSummaryInputs.joined(separator: "\n").utf8)).prefix(16))
    }

    /// Whether the notebook now gives a summary something other than it was written from (a page's reading arrived, a
    /// correction, a page hidden). False for a summary that kept no digest, so older summaries are not all out of date.
    public var summaryNotebookChanged: Bool {
        guard let written = summary?.notebookDigest else { return false }
        return written != notebookDigest
    }

    /// The sketches a summary section drew on that still exist: not on a deleted or hidden page, and still among the passages
    /// read, in the section's order.
    public func sketches(in section: SummarySection) -> [(page: NotebookPage, passage: NotebookPassage)] {
        (section.sketchIDs ?? []).compactMap { id in
            for page in visiblePages where page.hiddenFromSummary != true {
                if let passage = page.passages.first(where: { $0.id == id && $0.kind == .sketch }) { return (page, passage) }
            }
            return nil
        }
    }

    /// Takes a page out of summaries, or lets them use it again. Hiding it also takes its sketches out of the current summary's
    /// sections at once. Recorded in nothing: it is a choice about summaries, as for a photo.
    public mutating func setPageHiddenFromSummary(_ id: UUID, hidden: Bool, now: Date = Date()) {
        guard let index = pages?.firstIndex(where: { $0.id == id }), (pages?[index].hiddenFromSummary == true) != hidden else { return }
        pages?[index].hiddenFromSummary = hidden ? true : nil
        pages?[index].updatedAt = now
        if hidden, var summary {
            let gone = Set((pages?[index].passages ?? []).map(\.id))
            for section in summary.sections.indices {
                summary.sections[section].sketchIDs?.removeAll { gone.contains($0) }
                if summary.sections[section].sketchIDs?.isEmpty == true { summary.sections[section].sketchIDs = nil }
            }
            self.summary = summary
        }
        updatedAt = now
    }

    /// Stores what image reading found for sketch passages, by passage: replaces a reading of the same passage. A reading of
    /// strokes the passage no longer has (a late result) is dropped, and so is one for a passage no page has.
    public mutating func applySketchAnalyses(_ analyses: [UUID: SketchAnalysis], now: Date = Date()) {
        guard pages != nil, !analyses.isEmpty else { return }
        var changed = false
        for index in pages!.indices {
            for passage in pages![index].passages {
                guard let found = analyses[passage.id], found.strokeDigest == passage.strokeDigest else { continue }
                var list = (pages![index].sketches ?? []).filter { $0.passageID != passage.id }
                list.append(found)
                list.sort { $0.passageID.uuidString < $1.passageID.uuidString }
                guard list != pages![index].sketches else { continue }
                pages![index].sketches = list
                pages![index].updatedAt = now
                changed = true
            }
        }
        if changed { updatedAt = now }
    }

    /// Sketch passages of visible pages (not hidden from summaries, and read from their current drawing) with no reading of their
    /// strokes: what an image reading pass has to do.
    public var sketchesNeedingReading: [(page: NotebookPage, passage: NotebookPassage)] {
        visiblePages.filter { $0.hiddenFromSummary != true }.flatMap { page in
            page.summaryPassages.filter { $0.kind == .sketch && page.sketch(for: $0) == nil }.map { (page, $0) }
        }
    }
}

/// Where sketches from notebook pages go in a summary, as photos do (`PhotoPlacement`): offered to an on-device summary as
/// picture evidence labelled S1, S2…, placed under the section each drew on, and never offered to a cloud model.
public enum NotebookPlacement {
    public static let maximumSketches = 12
    public static let maximumPerSection = 6
    /// The most characters of one handwriting passage a summary is given.
    public static let writingLength = 1_000

    /// The sketches a summary may use, labelled S1, S2… in timeline order (then page, then place): sketch passages of visible
    /// pages not taken out of summaries whose current reading found something.
    public static func candidates(in meeting: Meeting) -> [PhotoEvidence] {
        var found: [(passage: NotebookPassage, page: NotebookPage, number: Int, time: TimeInterval?)] = []
        for (index, page) in meeting.visiblePages.enumerated() where page.hiddenFromSummary != true {
            for passage in page.summaryPassages where passage.kind == .sketch && passage.$kind.isKnown && page.sketch(for: passage)?.analysis.isInformative == true {
                found.append((passage, page, index + 1, meeting.timelineTime(of: passage, on: page)))
            }
        }
        found.sort { ($0.time ?? .infinity, $0.number, $0.passage.y, $0.passage.x) < ($1.time ?? .infinity, $1.number, $1.passage.y, $1.passage.x) }
        return found.prefix(maximumSketches).enumerated().map { index, item in
            let analysis = item.page.sketch(for: item.passage)!.analysis
            let caption = analysis.caption?.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = analysis.recognizedText.map { PhotoPlacement.excerpt($0) } ?? ""
            return PhotoEvidence(id: item.passage.id, label: "S\(index + 1)", time: item.time,
                                 caption: caption?.isEmpty == false ? caption : nil, text: text.isEmpty ? nil : text,
                                 labels: Array((analysis.labels ?? []).prefix(4)), isSketch: true, page: item.number)
        }
    }

    /// The summary with only valid sketch placements: each a candidate, once, at most `maximumPerSection` per section, then each
    /// clearly relevant sketch the model didn't place under the section closest to when it was drawn.
    public static func arrange(_ summary: MeetingSummary, in meeting: Meeting) -> MeetingSummary {
        var result = summary
        let candidates = self.candidates(in: meeting)
        let allowed = Set(candidates.map(\.id))
        var used = Set<UUID>()
        for index in result.sections.indices {
            var kept: [UUID] = []
            for id in result.sections[index].sketchIDs ?? [] where allowed.contains(id) && kept.count < maximumPerSection {
                if used.insert(id).inserted { kept.append(id) }
            }
            result.sections[index].sketchIDs = kept.isEmpty ? nil : kept
        }
        guard !result.sections.isEmpty else { return result }
        let ranges = PhotoPlacement.sectionRanges(result.sections, meeting: meeting)
        for sketch in candidates where !used.contains(sketch.id) && PhotoPlacement.isClearlyRelevant(sketch, in: meeting) {
            guard let time = sketch.time, let target = PhotoPlacement.closestSection(to: time, ranges: ranges),
                  (result.sections[target].sketchIDs?.count ?? 0) < maximumPerSection else { continue }
            result.sections[target].sketchIDs = (result.sections[target].sketchIDs ?? []) + [sketch.id]
            used.insert(sketch.id)
        }
        return result
    }

    /// Letters and digits only, lowercased, words one space apart: for telling whether words are already in a note.
    static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }
}
