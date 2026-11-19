import DaybookCore
import Foundation

/// What a summary is written from: the transcript with the person's notes and bookmarks placed in it
/// at their times, and the passages around each one marked to carry more weight
/// (docs/templates.md, "Notes and bookmarks"). Notes are the person's own words, never a speaker's;
/// the summary folds each into the part of the conversation it belongs to rather than listing them.
public struct SummarySource: Sendable, Equatable {
    /// One passage of the transcript.
    public struct Line: Sendable, Equatable {
        public var time: TimeInterval
        public var speaker: String
        public var text: String
        /// The notes and bookmarks ("N1", "B2") whose window this passage falls in.
        public var near: [String]
    }

    /// A note or a bookmark.
    public struct Anchor: Sendable, Equatable {
        public enum Kind: String, Sendable { case note, bookmark }
        /// "N1", "N2", … for notes in order; "B1", … for bookmarks in time order.
        public var label: String
        public var kind: Kind
        /// On the conversation's timeline; nil for a note written outside a recording, or a bookmark
        /// on a recording that isn't lined up with the others.
        public var time: TimeInterval?
        /// The note, or the bookmark's own words ("" for a bare bookmark).
        public var text: String
        /// The stretch of the timeline whose passages carry more weight.
        public var window: ClosedRange<TimeInterval>?
        /// For a bookmark on a recording that isn't lined up: that recording's name and its own passages
        /// around the bookmark, in its own time.
        public var recording: String?
        public var context: [String]
        /// A note found to repeat what was said around it: passed on without its words, as a moment the
        /// person marked (`MeetingSynthesis.notesRepeatingWhatWasSaid`).
        public var repeatsWhatWasSaid = false
    }

    /// How far around a note or a bookmark its passages carry more weight. A note is usually written
    /// just after what it's about; a bookmark is pressed during it (the window bookmarks had before).
    public struct Windows: Sendable, Equatable {
        public var noteBefore: TimeInterval = 60
        public var noteAfter: TimeInterval = 15
        public var bookmarkBefore: TimeInterval = 30
        public var bookmarkAfter: TimeInterval = 60
        public init() {}
    }

    public var lines: [Line]
    public var anchors: [Anchor]
    /// The transcript as it always was ("[01:02] Alex: …"), for checking quoted commitments.
    public var transcript: String
    /// The notes and bookmarks as earlier summaries received them (`MeetingEvidence.notes` and
    /// `.highlights`), for inference that takes strings and for small tasks.
    public var notesText: String
    public var highlightText: String?
    /// The conversation's title when the person or the calendar gave it (`Context.title`), never one Daybook
    /// made up or a model wrote, cut to `Context.titleLength` characters. Context for the model, not evidence.
    public var title: String?
    /// When the conversation began, as `Context.when` writes it ("Wednesday 2026-11-18, 14:05, America/Vancouver"); nil when
    /// no recording's start is known. Context for the model, not evidence.
    public var started: String?

    public init(lines: [Line], anchors: [Anchor], transcript: String, notesText: String, highlightText: String?,
                title: String? = nil, started: String? = nil) {
        self.lines = lines; self.anchors = anchors; self.transcript = transcript
        self.notesText = notesText; self.highlightText = highlightText
        self.title = title; self.started = started
    }

    /// What the summary model is told about the conversation beside what was said: its title and when it began.
    /// Nothing else about it (docs/cloud.md, "What is sent").
    public enum Context {
        /// The most characters of a title a model is given.
        public static let titleLength = 120

        /// A title the person or the calendar gave: the conversation's own, with the time Daybook adds to a recording's
        /// ("Weekly sync at 10:15 AM") taken off, and nil for a placeholder (none, "Untitled Conversation", "Note",
        /// "Conversation", "Microphone", a device's name alone such as "Alex’s iPhone") or a title that is only a time. The title a summary
        /// model wrote is the summary's (`MeetingSummary.title`), never the conversation's, and is never sent: a
        /// re-summary would be anchored on the earlier one's guess.
        public static func title(_ meeting: Meeting) -> String? {
            var title = meeting.title.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            if let time = title.range(of: #" at \d{1,2}[:.]\d{2}.*$"#, options: .regularExpression) { title.removeSubrange(time.lowerBound...) }
            let lowered = title.lowercased()
            guard !title.isEmpty, !placeholders.contains(lowered), lowered.range(of: deviceName, options: .regularExpression) == nil,
                  title.contains(where: \.isLetter) else { return nil }
            return title.count > titleLength ? String(title.prefix(titleLength)) + "…" : title
        }

        /// A title that is a device's name and nothing more: the name Daybook gives a recording made on an iPhone, an iPad, or
        /// an Apple Watch ("iPhone", "Apple Watch", "Alex’s iPhone"; `Meeting.defaultTitle` with `RecordingWords.baseName`).
        /// "iPhone launch review" is a title.
        private static let deviceName = #"^(.+['’]s )?(iphone|ipad|apple watch)$"#

        private static let placeholders = Set((["Untitled meeting", "Untitled Conversation", "Imported recording", "Conversation", "Note", "Recorder"]
            + AudioSource.allCases.map(\.recordingName)).map { $0.lowercased() })

        /// When the conversation began: the earliest start any of its recordings has by its own clock, which a recording
        /// made here or by a recorder that dates its files has, and a file imported by hand does not. The conversation's
        /// date alone is not used: for a file imported by hand it is the day it was imported. Nil when no recording knows
        /// its start. Written as "Wednesday 2026-11-18, 14:05, America/Vancouver" in `timeZone`, the same whatever the
        /// person's language or region, so the model can count to "next Tuesday".
        public static func started(_ meeting: Meeting, in timeZone: TimeZone = .current) -> String? {
            guard let start = meeting.tracks.filter({ !$0.isRemoved }).compactMap(\.startedAt).min() else { return nil }
            return when(start, in: timeZone)
        }

        public static func when(_ date: Date, in timeZone: TimeZone) -> String {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.timeZone = timeZone
            formatter.dateFormat = "EEEE yyyy-MM-dd, HH:mm"
            return "\(formatter.string(from: date)), \(timeZone.identifier)"
        }
    }

    /// A source from strings alone (inference that predates notes in place): the transcript as it
    /// comes, and the notes and bookmark evidence as text.
    public static func legacy(transcript: String, notes: String, highlights: String?) -> SummarySource {
        SummarySource(lines: [], anchors: [], transcript: transcript, notesText: notes, highlightText: highlights)
    }

    /// Whether notes and bookmarks are placed in the transcript (false for a `legacy` source).
    public var isStructured: Bool { !lines.isEmpty || !anchors.isEmpty }

    /// The transcript with each timed note and bookmark on its own line at its time, and passages near
    /// one marked "(near N1)":
    ///
    ///     [11:30] (near N1) Alex: We could keep the budget flat.
    ///     [12:04] NOTE N1, written by the user (not spoken): Budget cap is firm at 40k
    public var annotatedTranscript: String {
        guard isStructured else { return transcript }
        var result: [String] = []
        let placed = anchors.filter { $0.time != nil && $0.context.isEmpty }.sorted { ($0.time!, $0.label) < ($1.time!, $1.label) }
        var next = 0
        for line in lines {
            while next < placed.count, placed[next].time! < line.time { result.append(Self.marker(placed[next])); next += 1 }
            result.append(Self.format(line))
        }
        while next < placed.count { result.append(Self.marker(placed[next])); next += 1 }
        return result.joined(separator: "\n")
    }

    /// Every note and bookmark, for the model: label, kind, time (null when it has none), and text;
    /// a bookmark on a recording that isn't lined up also carries that recording's passages around it.
    public var notesPayload: [[String: Any]] {
        anchors.map { anchor in
            var entry: [String: Any] = ["label": anchor.label, "kind": anchor.kind.rawValue,
                                        "time": anchor.time.map { TimeLabel.format($0) as Any } ?? NSNull(),
                                        "text": anchor.repeatsWhatWasSaid ? "" : anchor.text]
            if anchor.repeatsWhatWasSaid { entry["repeats_what_was_said"] = true }
            if anchor.kind == .note && anchor.time == nil { entry["placement"] = "written outside the recording" }
            if let recording = anchor.recording { entry["recording"] = recording; entry["context"] = anchor.context }
            return entry
        }
    }

    /// The passages near notes and bookmarks, as many as fit `budget` (in `cost`'s units, the model's
    /// tokens): each note and bookmark gets its nearest passages before any gets farther ones, notes
    /// and bookmarks with words before bare bookmarks, so trimming a long conversation keeps the
    /// moments the person marked. Chronological, "[…]" between passages that aren't consecutive.
    public func focusPassages(fitting budget: Int, cost: (String) async -> Int) async -> String {
        guard budget > 0 else { return "" }
        let order = anchors.indices.sorted { a, b in
            let lhs = anchors[a], rhs = anchors[b]
            if lhs.text.isEmpty != rhs.text.isEmpty { return !lhs.text.isEmpty }
            return (lhs.time ?? .infinity, lhs.label) < (rhs.time ?? .infinity, rhs.label)
        }
        // Each anchor's candidates, nearest first: transcript lines (by index) or its own context.
        enum Item: Hashable { case line(Int), context(anchor: Int, index: Int) }
        var queues: [[Item]] = Array(repeating: [], count: anchors.count)
        for index in anchors.indices {
            let anchor = anchors[index]
            if !anchor.context.isEmpty {
                // Its own recording's passages, from the bookmark outward (they come in time order).
                let middle = anchor.context.count / 2
                queues[index] = anchor.context.indices.sorted { abs($0 - middle) < abs($1 - middle) }.map { .context(anchor: index, index: $0) }
                continue
            }
            guard let time = anchor.time, let window = anchor.window else { continue }
            let near = lines.indices.filter { window.contains(lines[$0].time) || lines[$0].near.contains(anchor.label) }
            // A note looks back: what came after it counts double.
            func distance(_ line: Int) -> Double {
                let gap = lines[line].time - time
                return anchor.kind == .note && gap > 0 ? gap * 2 : abs(gap)
            }
            queues[index] = near.sorted { distance($0) < distance($1) }.map { .line($0) }
        }
        var chosen = Set<Item>(), spent = 0, progressed = true
        while progressed {
            progressed = false
            for index in order {
                while let item = queues[index].first, chosen.contains(item) { queues[index].removeFirst() }
                guard let item = queues[index].first else { continue }
                queues[index].removeFirst()
                let text: String
                switch item {
                case .line(let line): text = Self.format(lines[line])
                case .context(let anchor, let position): text = anchors[anchor].context[position]
                }
                let price = await cost(text) + 1
                guard spent + price <= budget else { queues[index] = []; continue }
                spent += price
                chosen.insert(item)
                progressed = true
            }
        }
        var output: [String] = []
        var previous: Int?
        for line in chosen.compactMap({ item -> Int? in if case .line(let line) = item { return line }; return nil }).sorted() {
            if let previous, line != previous + 1 { output.append("[…]") }
            output.append(Self.format(lines[line]))
            previous = line
        }
        for index in anchors.indices where !anchors[index].context.isEmpty {
            let picked = anchors[index].context.indices.filter { chosen.contains(.context(anchor: index, index: $0)) }
            guard !picked.isEmpty else { continue }
            output.append("\(anchors[index].label), on \(anchors[index].recording ?? "a recording") (its own clock, not lined up with the others):")
            output += picked.map { anchors[index].context[$0] }
        }
        return output.joined(separator: "\n")
    }

    /// What was said around a note or bookmark on the timeline: the passages from `before` seconds before it
    /// to `after` seconds after, at most `limit` of them (the nearest), each cut to 600 characters, in order.
    /// Wider than its window, so a note written a while after what it's about still meets it.
    public func passages(around anchor: Anchor, before: TimeInterval = 120, after: TimeInterval = 30, limit: Int = 40) -> String {
        guard let time = anchor.time, anchor.context.isEmpty else { return "" }
        let near = lines.indices.filter { lines[$0].time >= time - before && lines[$0].time <= time + after }
            .sorted { abs(lines[$0].time - time) < abs(lines[$1].time - time) }.prefix(limit).sorted()
        return near.map { index in
            let line = lines[index]
            return "[\(TimeLabel.format(line.time))] \(line.speaker): \(line.text.count > 600 ? String(line.text.prefix(600)) + "…" : line.text)"
        }.joined(separator: "\n")
    }

    static func format(_ line: Line) -> String {
        let near = line.near.isEmpty ? "" : "(near \(line.near.joined(separator: ", "))) "
        return "[\(TimeLabel.format(line.time))] \(near)\(line.speaker): \(line.text)"
    }

    /// A note or bookmark as a line of its own: "[12:04] NOTE N1, written by the user (not spoken): …", or, for a
    /// note that repeats what was said, "[12:04] NOTE N1, written by the user, repeats what was said around it".
    public static func marker(_ anchor: Anchor) -> String {
        let time = anchor.time.map { "[\(TimeLabel.format($0))] " } ?? ""
        switch anchor.kind {
        case .note where anchor.repeatsWhatWasSaid: return "\(time)NOTE \(anchor.label), written by the user, repeats what was said around it"
        case .note: return "\(time)NOTE \(anchor.label), written by the user (not spoken): \(anchor.text)"
        case .bookmark: return "\(time)BOOKMARK \(anchor.label), marked by the user" + (anchor.text.isEmpty ? "" : ": \(anchor.text)")
        }
    }
}

extension MeetingEvidence {
    /// The summary's source for a conversation: its unified transcript (background audio already left
    /// out), each note paragraph and bookmark placed at its time, and the passages in each one's window
    /// marked to carry more weight, with its title and start (`SummarySource.Context`).
    public static func summarySource(_ meeting: Meeting, windows: SummarySource.Windows = .init(), timeZone: TimeZone = .current) -> SummarySource {
        var anchors: [SummarySource.Anchor] = []
        let paragraphs = meeting.notes.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let times = meeting.paragraphTimes()
        let ink = meeting.inkPlacements()
        for (index, text) in paragraphs.enumerated() {
            // Ink with no words (a sketch, or not read yet) has the placeholder for a paragraph: not something the person
            // wrote. It's left out, and the notes after it keep their labels (N1, N3).
            if text == NoteInk.placeholder, index < ink.count, ink[index] != nil { continue }
            let time = index < times.count ? times[index] : nil
            anchors.append(.init(label: "N\(index + 1)", kind: .note, time: time, text: text,
                                 window: time.map { ($0 - windows.noteBefore)...($0 + windows.noteAfter) }, recording: nil, context: []))
        }
        let contexts = meeting.highlightContexts(before: windows.bookmarkBefore, after: windows.bookmarkAfter)
        for (index, context) in contexts.sorted(by: { ($0.isAligned ? 0 : 1, $0.markerTime) < ($1.isAligned ? 0 : 1, $1.markerTime) }).enumerated() {
            let words = BookmarkMarks.automaticLabels.contains(context.highlight.text) ? "" : context.highlight.text
            let label = "B\(index + 1)"
            if context.isAligned {
                anchors.append(.init(label: label, kind: .bookmark, time: context.markerTime, text: words,
                                     window: context.rangeStart...context.rangeEnd, recording: nil, context: []))
            } else {
                let source = meeting.tracks.first { $0.id == context.highlight.trackID }.map { MeetingExport.sourceName(of: $0, in: meeting) } ?? context.sourceName
                anchors.append(.init(label: label, kind: .bookmark, time: nil, text: words, window: nil, recording: source,
                                     context: context.speechContext.map { "[\(TimeLabel.format($0.start))] \($0.text)" }))
            }
        }
        let lines = meeting.unifiedTranscript.map { segment -> SummarySource.Line in
            let name = meeting.speakers.first { $0.id == segment.speakerID }?.name ?? "Unknown speaker"
            let near = anchors.filter { anchor in
                guard let window = anchor.window else { return false }
                return segment.end >= window.lowerBound && segment.start <= window.upperBound
            }.map(\.label)
            return .init(time: segment.start, speaker: name, text: segment.text, near: near)
        }
        return SummarySource(lines: lines, anchors: anchors, transcript: transcript(meeting),
                             notesText: notes(meeting), highlightText: highlights(meeting),
                             title: SummarySource.Context.title(meeting), started: SummarySource.Context.started(meeting, in: timeZone))
    }
}
