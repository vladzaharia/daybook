import DaybookCore
import Foundation

/// What a question was answered from: the passages, notes, and bookmarks of the conversations retrieval chose, each
/// under a label the answering step cites (docs/architecture.md, "Ask across conversations").
public struct AskEvidence: Equatable, Sendable {
    /// One passage of a conversation's transcript.
    public struct Passage: Equatable, Sendable {
        public var label: String
        public var segmentID: UUID
        /// Seconds into the conversation.
        public var time: TimeInterval
        public var speaker: String?
        public var text: String
        public init(label: String, segmentID: UUID, time: TimeInterval, speaker: String?, text: String) {
            self.label = label; self.segmentID = segmentID; self.time = time; self.speaker = speaker; self.text = text
        }
    }

    /// A paragraph of the person's notes, written rather than said.
    public struct Note: Equatable, Sendable {
        public var label: String
        public var paragraph: Int
        public var time: TimeInterval?
        public var text: String
        public init(label: String, paragraph: Int, time: TimeInterval?, text: String) {
            self.label = label; self.paragraph = paragraph; self.time = time; self.text = text
        }
    }

    public struct Bookmark: Equatable, Sendable {
        public var label: String
        public var highlightID: UUID
        public var time: TimeInterval
        public var text: String
        public init(label: String, highlightID: UUID, time: TimeInterval, text: String) {
            self.label = label; self.highlightID = highlightID; self.time = time; self.text = text
        }
    }

    public struct Conversation: Equatable, Sendable {
        public var label: String
        public var meetingID: UUID
        /// Only a title the person or the calendar gave; nil for "Untitled meeting".
        public var title: String?
        public var date: Date
        /// When it began, for resolving a date said in it: "Wednesday 2026-11-18, 14:05, America/Vancouver".
        public var started: String
        public var passages: [Passage]
        public var notes: [Note]
        public var bookmarks: [Bookmark]
        public init(label: String, meetingID: UUID, title: String?, date: Date, started: String, passages: [Passage] = [], notes: [Note] = [],
                    bookmarks: [Bookmark] = []) {
            self.label = label; self.meetingID = meetingID; self.title = title; self.date = date; self.started = started
            self.passages = passages; self.notes = notes; self.bookmarks = bookmarks
        }
    }

    public var question: String
    /// "Wednesday 2026-11-18, America/Vancouver".
    public var today: String
    public var conversations: [Conversation]
    /// Rough tokens the passages, notes, and bookmarks take.
    public var tokens: Int

    public init(question: String, today: String, conversations: [Conversation], tokens: Int = 0) {
        self.question = question; self.today = today; self.conversations = conversations; self.tokens = tokens
    }

    /// The pieces an answer may cite, by label.
    public func source(_ label: String) -> (conversation: Conversation, kind: AskCitation.Kind, text: String)? {
        for conversation in conversations {
            if let passage = conversation.passages.first(where: { $0.label == label }) { return (conversation, .passage, passage.text) }
            if let note = conversation.notes.first(where: { $0.label == label }) { return (conversation, .note, note.text) }
            if let bookmark = conversation.bookmarks.first(where: { $0.label == label }) { return (conversation, .bookmark, bookmark.text) }
        }
        return nil
    }

    var isEmpty: Bool { conversations.allSatisfy { $0.passages.isEmpty && $0.notes.isEmpty && $0.bookmarks.isEmpty } }
}

/// What one sentence of an answer rests on: a passage, a note, or a bookmark of one conversation.
public struct AskCitation: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case passage, note, bookmark }

    public var kind: Kind
    public var meetingID: UUID
    public var conversationTitle: String?
    public var date: Date
    /// The passage to open and play from; nil for a note or a bookmark.
    public var segmentID: UUID?
    public var highlightID: UUID?
    public var paragraph: Int?
    /// Seconds into the conversation; nil for a note written outside the recording.
    public var time: TimeInterval?
    /// Who said it; nil for a note, a bookmark, or an unknown voice.
    public var speaker: String?
    /// The passage's, note's, or bookmark's own words.
    public var text: String

    public init(kind: Kind, meetingID: UUID, conversationTitle: String?, date: Date, segmentID: UUID? = nil, highlightID: UUID? = nil,
                paragraph: Int? = nil, time: TimeInterval?, speaker: String? = nil, text: String) {
        self.kind = kind; self.meetingID = meetingID; self.conversationTitle = conversationTitle; self.date = date
        self.segmentID = segmentID; self.highlightID = highlightID; self.paragraph = paragraph; self.time = time
        self.speaker = speaker; self.text = text
    }
}

/// One sentence of an answer, kept only because its quote is in a passage it cites, word for word.
public struct AskSentence: Equatable, Sendable {
    public var text: String
    /// The sources, the one holding the quote first.
    public var citations: [AskCitation]
    /// The few words quoted from the first citation.
    public var quote: String

    public init(text: String, citations: [AskCitation], quote: String) { self.text = text; self.citations = citations; self.quote = quote }
}

/// An answer to a question, every sentence of it cited and checked.
public struct AskAnswer: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case answered
        /// Part is answered, or sentences were dropped by the quote check. The interface says so with `AskWords.partial`.
        case partial
        /// "Nothing here answers that."
        case notFound(Reason)
    }

    /// Why nothing was answered.
    public enum Reason: Equatable, Sendable {
        /// Retrieval found nothing worth reading; no model ran.
        case nothingFound
        /// The model said the passages don't answer it.
        case modelSaidSo
        /// The model wrote sentences, and the quote check dropped every one.
        case nothingVerified
    }

    public var status: Status
    public var sentences: [AskSentence]
    /// Sentences the model wrote that the quote check dropped.
    public var dropped: Int
    /// Conversations in the order retrieval ranked them, for the closest search results under a "not found".
    public var closest: [UUID]
    /// What the question was read as: the people and dates it filtered by.
    public var query: AskQuery?

    public init(status: Status, sentences: [AskSentence] = [], dropped: Int = 0, closest: [UUID] = [], query: AskQuery? = nil) {
        self.status = status; self.sentences = sentences; self.dropped = dropped
        self.closest = closest; self.query = query
    }

    /// Nothing here answers it.
    public var isNotFound: Bool { if case .notFound = status { return true } else { return false } }
}

/// What a question reports while it's answered.
public enum AskProgress: Equatable, Sendable {
    /// Retrieval is running.
    case searching
    /// Another job holds the model; the question waits its turn.
    case waiting
    /// The model is loading, 0 to 1.
    case loading(Double)
    /// The model is writing.
    case answering
    /// A sentence of the answer, once checked; they come in order, before the answer itself.
    case sentence(AskSentence)
}
