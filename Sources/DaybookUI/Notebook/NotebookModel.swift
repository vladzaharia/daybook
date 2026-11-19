import DaybookCore
import Foundation

/// What a page's strokes are right now, from whoever keeps them.
public enum NotebookPageContent: Equatable, Sendable {
    case strokes(Data)
    /// No strokes: a page made here, or one the conversation has none for.
    case blank
    /// The strokes exist but aren't on this device yet. The canvas stays closed over them.
    case notLoaded
}

/// What the notebook needs from whoever keeps the pages, like `NotesInkModel` for the notes: the recorder while recording,
/// a conversation's library when it's saved. The notebook never reaches either one directly.
@MainActor
public struct NotebookModel {
    /// Pages that aren't deleted, in order.
    public var pages: () -> [NotebookPage]
    public var content: (UUID) -> NotebookPageContent
    /// Brings a page's strokes onto this device; false when it couldn't. Nil when they're always at hand.
    public var fetch: ((UUID) async -> Bool)?
    /// A page made in the notebook: kept with the first strokes written on it, so an empty page never exists elsewhere.
    public var add: (NotebookPage) -> Void
    /// The strokes changed: written to a file a moment later, never to the journal. False when refused.
    public var saveDraft: (UUID, Data) -> Bool
    /// The strokes settled. Returns their SHA-256, which a reading of them is checked against. Throws when they weren't kept
    /// (the page's earlier strokes aren't here, the file couldn't be written); the error says why in plain words.
    public var commit: (_ page: UUID, _ data: Data, _ strokeCount: Int, _ contentVersion: Int) async throws -> String
    public var applyReading: (UUID, PageReading) -> Void
    public var correct: (_ page: UUID, _ passage: UUID, _ text: String) -> Void
    public var remove: (UUID) -> (() -> Void)?
    public var recordErasures: (UUID, [ErasedStroke]) -> Void
    public var logTurn: (PageTurn) -> Void
    /// Notes the recorder's clock against the wall clock as a stroke begins; nil when no recording runs.
    public var sampleClock: (() -> Void)?
    /// Where a moment falls: seconds into the recording, or on a track while playing; nil without a clock.
    public var anchor: (Date) -> (trackID: UUID?, time: TimeInterval?)
    public var isEditable: Bool
    /// The device pages made here are credited to (`NotebookPage.origin`).
    public var origin: PhotoOrigin?

    public init(pages: @escaping () -> [NotebookPage], content: @escaping (UUID) -> NotebookPageContent,
                fetch: ((UUID) async -> Bool)? = nil, add: @escaping (NotebookPage) -> Void,
                saveDraft: @escaping (UUID, Data) -> Bool,
                commit: @escaping (UUID, Data, Int, Int) async throws -> String,
                applyReading: @escaping (UUID, PageReading) -> Void, correct: @escaping (UUID, UUID, String) -> Void,
                remove: @escaping (UUID) -> (() -> Void)?, recordErasures: @escaping (UUID, [ErasedStroke]) -> Void,
                logTurn: @escaping (PageTurn) -> Void, sampleClock: (() -> Void)? = nil,
                anchor: @escaping (Date) -> (trackID: UUID?, time: TimeInterval?), isEditable: Bool = true,
                origin: PhotoOrigin? = nil) {
        self.pages = pages; self.content = content; self.fetch = fetch; self.add = add; self.saveDraft = saveDraft
        self.commit = commit; self.applyReading = applyReading; self.correct = correct; self.remove = remove
        self.recordErasures = recordErasures; self.logTurn = logTurn; self.sampleClock = sampleClock; self.anchor = anchor
        self.isEditable = isEditable; self.origin = origin
    }
}
