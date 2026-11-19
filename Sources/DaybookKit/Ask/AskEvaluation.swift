import DaybookCore
import Foundation

/// The synthetic evaluation library for Ask and its scoring (docs/validation.md, "Ask across conversations"): about
/// twenty invented conversations about invented people and companies, and about sixty questions with known answers,
/// each tagged for tuning or held out. The retrieval-recall test runs it in CI; `Daybook --ask-eval` runs it with a
/// real model. Nothing here reads a real library.
public enum AskEvaluation {
    /// Where an answer's evidence is: a passage of a conversation (by its line), a note paragraph, or a bookmark.
    public struct Location: Decodable, Equatable, Sendable {
        public var c: String
        public var line: Int?
        public var note: Int?
        public var bookmark: Int?
    }

    public struct Question: Decodable, Equatable, Sendable, Identifiable {
        public var id: String
        public var text: String
        public var category: String
        /// "tune" or "held": the held-out third is never looked at while tuning.
        public var split: String
        public var scope: String
        /// A conversation's fixture ID when the question is about one conversation.
        public var conversation: String?
        public var answerable: Bool
        /// The answer is in a Personal conversation: asked with the lock locked, it must be not found.
        public var personal: Bool
        /// Groups of alternatives: an answer is correct when every group has one of its words in the answer's text.
        public var facts: [[String]]
        /// Words a correct answer never contains.
        public var forbidden: [String]
        /// Any one of these is enough to answer.
        public var evidence: [Location]
        public var isHeldOut: Bool { split == "held" }
    }

    /// The library as meetings, with where each fixture line landed.
    public struct Library: Sendable {
        public var meetings: [Meeting]
        public var today: Date
        public var calendar: Calendar
        public var questions: [Question]
        private var fixtureIDs: [String: UUID]

        init(meetings: [Meeting], today: Date, calendar: Calendar, questions: [Question], fixtureIDs: [String: UUID]) {
            self.meetings = meetings; self.today = today; self.calendar = calendar; self.questions = questions; self.fixtureIDs = fixtureIDs
        }

        /// The conversation's ID in the library.
        public func meetingID(_ fixture: String) -> UUID? { fixtureIDs[fixture] }

        func meeting(_ fixture: String) -> Meeting? { fixtureIDs[fixture].flatMap { id in meetings.first { $0.id == id } } }

        /// Whether `location` is one of the passages, the note, or the bookmark `pieces` hold.
        func isIn(_ location: Location, passages: Set<UUID>, notes: Set<UUID>, paragraphs: Set<Int>, bookmarks: Set<UUID>) -> Bool {
            guard let meeting = meeting(location.c) else { return false }
            if let line = location.line, meeting.unifiedTranscript.indices.contains(line) { return passages.contains(meeting.unifiedTranscript[line].id) }
            if let note = location.note { return notes.contains(meeting.id) && paragraphs.contains(note) }
            if let bookmark = location.bookmark, meeting.highlights.indices.contains(bookmark) { return bookmarks.contains(meeting.highlights[bookmark].id) }
            return false
        }
    }

    private struct Fixture: Decodable {
        struct Note: Decodable { var after: String?; var text: String }
        struct Mark: Decodable { var during: String; var text: String }
        struct Section: Decodable { var heading: String; var body: String }
        struct Action: Decodable { var text: String; var owner: String? }
        struct Summary: Decodable { var overview: String; var sections: [Section]; var actions: [Action] }
        var id: String
        var title: String
        var date: String
        var kind: String
        var placement: String?
        var speakers: [String: String]
        var lines: [[String]]
        var notes: [Note]
        var bookmarks: [Mark]
        var summary: Summary?
    }

    private struct QuestionFile: Decodable {
        var today: String
        var timeZone: String
        var questions: [Question]
    }

    /// Loads the library's and the questions' JSON (Tests/DaybookKitTests/AskEvaluation): the summary harness's fixture
    /// format with dates, placements, and summaries added, as `Daybook --cloud-check` reads, with passages at 2.5
    /// words a second.
    public static func load(library: URL, questions: URL) throws -> Library {
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: library))
        let file = try JSONDecoder().decode(QuestionFile.self, from: Data(contentsOf: questions))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: file.timeZone) ?? .current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        var ids: [String: UUID] = [:]
        let meetings = try fixtures.map { fixture -> Meeting in
            guard let date = formatter.date(from: fixture.date) else { throw CocoaError(.fileReadCorruptFile) }
            let hex = AudioDigest.sha256(data: Data(fixture.id.utf8)).prefix(32)
            let id = UUID(uuidString: "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))") ?? UUID()
            ids[fixture.id] = id
            let track = UUID()
            var segments: [TranscriptSegment] = []
            var time = 0.0
            for line in fixture.lines where line.count >= 2 {
                let end = time + Double(line[1].split(separator: " ").count) / 2.5
                segments.append(TranscriptSegment(trackID: track, start: time, end: end, text: line[1], speakerID: line[0]))
                time = end + 0.6
            }
            func segment(_ snippet: String) -> TranscriptSegment? { segments.first { $0.text.hasPrefix(snippet) } }
            var meeting = Meeting(id: id, title: fixture.title, date: date, updatedAt: date, kind: MeetingKind(rawValue: fixture.kind) ?? .general,
                                  speakers: fixture.speakers.sorted { $0.key < $1.key }.map { Speaker(id: $0.key, name: $0.value) }, status: .ready)
            meeting.placement = fixture.placement.flatMap(LibraryPlacement.init(rawValue:))
            meeting.unifiedTranscript = segments
            meeting.notes = fixture.notes.map(\.text).joined(separator: "\n")
            meeting.timedNotes = fixture.notes.map { note in TimedNote(time: note.after.flatMap(segment).map { $0.end + 4 }, text: note.text) }
            meeting.highlights = fixture.bookmarks.compactMap { mark in segment(mark.during).map { Highlight(time: $0.start + 1, text: mark.text) } }
            if let summary = fixture.summary {
                meeting.summary = MeetingSummary(
                    kind: meeting.kind, title: fixture.title, overview: summary.overview,
                    sections: summary.sections.map { SummarySection(heading: $0.heading, body: $0.body) },
                    actionItems: summary.actions.map { ActionItem(text: $0.text, owner: $0.owner) })
            }
            return meeting
        }
        guard let today = formatter.date(from: file.today) else { throw CocoaError(.fileReadCorruptFile) }
        return Library(meetings: meetings, today: today, calendar: calendar, questions: file.questions, fixtureIDs: ids)
    }

    // MARK: Retrieval

    /// What retrieval did for one answerable question.
    public struct RetrievalResult: Equatable, Sendable {
        public var question: String
        public var id: String
        public var category: String
        public var isHeldOut: Bool
        /// Where the first expected piece ranks among the hits, from 1; nil when none of them does.
        public var rank: Int?
        /// Whether an expected piece is among what the model would be given.
        public var inEvidence: Bool
    }

    /// Retrieval's recall over the answerable questions (not the Personal ones, which are asked locked).
    public struct Recall: Equatable, Sendable {
        public var questions: Int
        public var atOne: Int
        public var atThree: Int
        public var inEvidence: Int
        public var atOnePercent: Double { questions == 0 ? 0 : Double(atOne) / Double(questions) * 100 }
        public var atThreePercent: Double { questions == 0 ? 0 : Double(atThree) / Double(questions) * 100 }
        public var inEvidencePercent: Double { questions == 0 ? 0 : Double(inEvidence) / Double(questions) * 100 }
    }

    /// The scope a question is asked in: the question's own scope and conversation, with Personal locked or not.
    public static func scope(of question: Question, in library: Library, locked: Bool) -> AskScope {
        var scope = AskScope(personal: locked ? .locked : .included)
        switch question.scope {
        case "work": scope.search = .work
        case "personal": scope.search = .personal
        default: break
        }
        scope.conversation = question.conversation.flatMap(library.meetingID)
        return scope
    }

    /// What retrieval finds for `question` over the library.
    public static func retrieve(_ question: Question, in library: Library, index: LibraryPassageIndex, locked: Bool = false) throws -> AskRetrieval {
        try AskRetriever(index: index).retrieve(question.text, scope: scope(of: question, in: library, locked: locked), in: library.meetings,
                                                now: library.today, calendar: library.calendar)
    }

    /// Where `question`'s expected evidence ranks, and whether it reaches the model.
    public static func result(of question: Question, retrieval: AskRetrieval, in library: Library) -> RetrievalResult {
        func covers(_ hit: AskHit) -> Bool {
            guard let meeting = library.meetings.first(where: { $0.id == hit.unit.meetingID }) else { return false }
            var passages = Set<UUID>(), notes = Set<UUID>(), paragraphs = Set<Int>(), bookmarks = Set<UUID>()
            switch hit.unit.kind {
            case .note: notes = [meeting.id]; paragraphs = hit.unit.paragraph.map { [$0] } ?? []
            case .bookmark: bookmarks = hit.unit.highlightID.map { [$0] } ?? []
            default: passages = Set((hit.unit.passages ?? 0..<0).map { meeting.unifiedTranscript[$0].id })
            }
            return question.evidence.contains { library.isIn($0, passages: passages, notes: notes, paragraphs: paragraphs, bookmarks: bookmarks) }
        }
        let rank = retrieval.hits.firstIndex(where: covers).map { $0 + 1 }
        var inEvidence = false
        if let evidence = retrieval.evidence {
            var passages = Set<UUID>(), notes = Set<UUID>(), paragraphs = Set<Int>(), bookmarks = Set<UUID>()
            for conversation in evidence.conversations {
                for passage in conversation.passages { passages.insert(passage.segmentID) }
                for note in conversation.notes { notes.insert(conversation.meetingID); paragraphs.insert(note.paragraph) }
                for bookmark in conversation.bookmarks { bookmarks.insert(bookmark.highlightID) }
            }
            inEvidence = question.evidence.contains { library.isIn($0, passages: passages, notes: notes, paragraphs: paragraphs, bookmarks: bookmarks) }
        }
        return RetrievalResult(question: question.text, id: question.id, category: question.category, isHeldOut: question.isHeldOut,
                               rank: rank, inEvidence: inEvidence)
    }

    public static func recall(_ results: [RetrievalResult]) -> Recall {
        Recall(questions: results.count, atOne: results.filter { $0.rank == 1 }.count,
               atThree: results.filter { ($0.rank ?? .max) <= 3 }.count, inEvidence: results.filter(\.inEvidence).count)
    }

    // MARK: Answers

    public enum Outcome: String, CaseIterable, Equatable, Sendable {
        /// An answerable question answered with its facts and none of its forbidden words.
        case correct
        /// Answered, with a fact missing or a forbidden word, or an unanswerable question answered.
        case wrong
        /// An answerable question the answer says nothing answers.
        case missed
        /// An unanswerable question the answer says nothing answers.
        case rightlyNotFound
    }

    /// An answer scored against the question's facts, by words in its sentences alone.
    public static func outcome(of answer: AskAnswer, for question: Question) -> Outcome {
        if answer.isNotFound { return question.answerable ? .missed : .rightlyNotFound }
        guard question.answerable else { return .wrong }
        let text = answer.sentences.map(\.text).joined(separator: " ").lowercased()
        let hasFacts = question.facts.allSatisfy { group in group.contains { text.contains($0.lowercased()) } }
        let clean = !question.forbidden.contains { text.contains($0.lowercased()) }
        return hasFacts && clean ? .correct : .wrong
    }
}
