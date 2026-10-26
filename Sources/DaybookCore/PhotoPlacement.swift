import Foundation

/// A photo as the summarizer sees it: a short label ("P1") the model can repeat, when it was taken on
/// the conversation's timeline, and what processing found in it.
public struct PhotoEvidence: Codable, Equatable, Sendable {
    public var id: UUID
    public var label: String
    /// Seconds on the conversation's timeline, when the photo falls on it.
    public var time: TimeInterval?
    public var caption: String?
    /// The text in the picture, shortened.
    public var text: String?
    public var labels: [String]

    public init(id: UUID, label: String, time: TimeInterval? = nil, caption: String? = nil, text: String? = nil, labels: [String] = []) {
        self.id = id; self.label = label; self.time = time; self.caption = caption; self.text = text; self.labels = labels
    }
}

/// Where photos go in a summary ("as appropriate"): under the section each one illustrates, and only
/// photos worth showing. The summarizer proposes placements; `arrange` keeps the valid ones and adds a
/// time-based fallback for a clearly relevant photo the model left out.
public enum PhotoPlacement {
    /// At most this many photos are offered to a summary, and shown under one section.
    public static let maximumPhotos = 24
    public static let maximumPerSection = 6
    /// Recognized text kept per photo in the summarizer's source data.
    public static let textExcerptLength = 280

    /// The photos a summary may use, labelled P1, P2… in timeline order: not deleted, not taken out of
    /// the summary by the person, analysed, and informative (sharp, not a near copy, something in it).
    public static func candidates(in meeting: Meeting) -> [PhotoEvidence] {
        let usable = meeting.visiblePhotos.filter { $0.hiddenFromSummary != true && $0.analysis?.isInformative == true }
        return usable.prefix(maximumPhotos).enumerated().map { index, photo in
            let text = photo.analysis?.recognizedText.map { excerpt($0) }
            return PhotoEvidence(id: photo.id, label: "P\(index + 1)", time: meeting.timelineTime(of: photo),
                                 caption: photo.displayCaption, text: text?.isEmpty == false ? text : nil,
                                 labels: Array((photo.analysis?.labels ?? []).prefix(4)))
        }
    }

    /// The summarizer's source data for photos, one line each, with timeline times in the transcript's form.
    public static func evidence(_ photos: [PhotoEvidence]) -> String {
        photos.map { photo in
            var parts = ["[\(photo.label)]"]
            parts.append(photo.time.map { "taken at \(clock($0))" } ?? "taken outside the recording")
            if let caption = photo.caption { parts.append("shows: \(caption)") }
            else if !photo.labels.isEmpty { parts.append("shows: \(photo.labels.joined(separator: ", "))") }
            if let text = photo.text { parts.append("text in the photo: \(text)") }
            return parts.joined(separator: "; ")
        }.joined(separator: "\n")
    }

    /// The summary with only valid photo placements: each photo a candidate, once, at most
    /// `maximumPerSection` per section, then each clearly relevant photo the model didn't place under
    /// the section closest to when it was taken.
    public static func arrange(_ summary: MeetingSummary, in meeting: Meeting) -> MeetingSummary {
        var result = summary
        let candidates = self.candidates(in: meeting)
        let allowed = Set(candidates.map(\.id))
        var used = Set<UUID>()
        for index in result.sections.indices {
            var kept: [UUID] = []
            for id in result.sections[index].photoIDs ?? [] where allowed.contains(id) && kept.count < maximumPerSection {
                if used.insert(id).inserted { kept.append(id) }
            }
            result.sections[index].photoIDs = kept.isEmpty ? nil : kept
        }
        guard !result.sections.isEmpty else { return result }
        let ranges = sectionRanges(result.sections, meeting: meeting)
        for photo in candidates where !used.contains(photo.id) && isClearlyRelevant(photo, in: meeting) {
            guard let time = photo.time, let target = closestSection(to: time, ranges: ranges),
                  (result.sections[target].photoIDs?.count ?? 0) < maximumPerSection else { continue }
            result.sections[target].photoIDs = (result.sections[target].photoIDs ?? []) + [photo.id]
            used.insert(photo.id)
        }
        return result
    }

    /// A photo that plainly belongs to the conversation: taken during it, and either showing words
    /// (a slide, a whiteboard, a document) or showing something the conversation talked about then.
    public static func isClearlyRelevant(_ photo: PhotoEvidence, in meeting: Meeting) -> Bool {
        guard let time = photo.time, let span = transcriptSpan(meeting), time >= span.lowerBound - 60, time <= span.upperBound + 60 else { return false }
        let words = (photo.text ?? "").split(whereSeparator: { !$0.isLetter && !$0.isNumber }).filter { $0.count >= 2 }
        if words.count >= 3 { return true }
        let nearby = meeting.unifiedTranscript.filter { $0.end >= time - 180 && $0.start <= time + 180 }.map(\.text).joined(separator: " ")
        let shown = tokens(([photo.caption ?? ""] + photo.labels + [photo.text ?? ""]).joined(separator: " "))
        return shown.intersection(tokens(nearby)).count >= 2
    }

    /// The part of the timeline each section talks about: the passages that share its words, else its
    /// place in order across the transcript (summaries usually follow the conversation).
    static func sectionRanges(_ sections: [SummarySection], meeting: Meeting) -> [ClosedRange<TimeInterval>?] {
        let segments = meeting.unifiedTranscript
        guard let span = transcriptSpan(meeting) else { return sections.map { _ in nil } }
        let segmentTokens = segments.map { tokens($0.text) }
        return sections.enumerated().map { index, section in
            let wanted = tokens(section.heading + " " + section.body)
            let scored = segments.indices.map { ($0, segmentTokens[$0].intersection(wanted).count) }
            var anchors = scored.filter { $0.1 >= 2 }.map(\.0)
            if anchors.isEmpty { anchors = scored.filter { $0.1 >= 1 }.sorted { $0.1 > $1.1 }.prefix(3).map(\.0) }
            if !anchors.isEmpty {
                let lower = anchors.map { segments[$0].start }.min()!, upper = anchors.map { segments[$0].end }.max()!
                return lower...max(lower, upper)
            }
            let width = (span.upperBound - span.lowerBound) / Double(sections.count)
            let lower = span.lowerBound + width * Double(index)
            return lower...(lower + width)
        }
    }

    static func closestSection(to time: TimeInterval, ranges: [ClosedRange<TimeInterval>?]) -> Int? {
        var best: (index: Int, distance: TimeInterval)?
        for (index, range) in ranges.enumerated() {
            guard let range else { continue }
            let distance = range.contains(time) ? 0 : min(abs(time - range.lowerBound), abs(time - range.upperBound))
            if best == nil || distance < best!.distance { best = (index, distance) }
        }
        return best?.index
    }

    static func transcriptSpan(_ meeting: Meeting) -> ClosedRange<TimeInterval>? {
        guard let lower = meeting.unifiedTranscript.map(\.start).min(), let upper = meeting.unifiedTranscript.map(\.end).max(), upper >= lower else { return nil }
        return lower...upper
    }

    private static let stopwords: Set<String> = [
        "about", "after", "also", "been", "before", "being", "could", "does", "from", "have", "here", "into", "just", "like",
        "make", "more", "most", "much", "only", "other", "over", "really", "said", "should", "some", "that", "than", "their",
        "them", "then", "there", "these", "they", "this", "those", "very", "want", "were", "what", "when", "where", "which",
        "while", "will", "with", "would", "your", "yeah", "okay", "think", "going", "know", "right", "well", "photo", "image",
        "picture", "shows", "showing"
    ]

    static func tokens(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { $0.count >= 4 && !stopwords.contains($0) })
    }

    private static func excerpt(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " / ")
        return flat.count > textExcerptLength ? String(flat.prefix(textExcerptLength)) + "…" : flat
    }

    /// "00:12:34" / "12:34", as the summarizer's transcript writes times.
    private static func clock(_ seconds: TimeInterval) -> String {
        let value = Int(max(0, seconds.isFinite ? seconds : 0))
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, (value % 3600) / 60, value % 60)
            : String(format: "%02d:%02d", value / 60, value % 60)
    }
}
