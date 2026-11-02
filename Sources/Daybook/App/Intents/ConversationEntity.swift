import AppIntents
import CoreSpotlight
import DaybookDevices
import DaybookKit
import Foundation
import os

/// A conversation, for Shortcuts and Spotlight: its title, when it was, and its gist. Personal conversations are never
/// named outside the app (the menu bar extra's rule), so they're never indexed or suggested; a shortcut made with one
/// still opens it.
struct ConversationEntity: AppEntity, IndexedEntity, Equatable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Conversation"
    static let defaultQuery = ConversationQuery()

    var id: UUID
    var title: String
    var date: Date
    /// The summary's overview, when there is one.
    var gist: String?

    init(id: UUID, title: String, date: Date, gist: String?) {
        self.id = id
        self.title = title
        self.date = date
        self.gist = gist
    }

    init(_ meeting: Meeting) {
        self.init(id: meeting.id, title: meeting.title, date: meeting.date,
                  gist: meeting.summary?.overview.isEmpty == false ? meeting.summary?.overview : nil)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(date.formatted(date: .abbreviated, time: .shortened))")
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.title = title
        attributes.contentDescription = gist
        attributes.contentCreationDate = date
        attributes.metadataModificationDate = date
        return attributes
    }

    /// Whether Daybook may name it outside its windows: anything not Personal.
    static func isShown(_ meeting: Meeting) -> Bool { meeting.effectivePlacement != .personal }

    /// What Spotlight and Shortcuts' suggestions list, newest first.
    static func shown(in meetings: [Meeting]) -> [ConversationEntity] {
        meetings.filter(isShown).sorted { $0.date > $1.date }.map(ConversationEntity.init)
    }
}

/// Finds conversations for Shortcuts: by ID (any conversation, so a shortcut keeps working), by words in the title,
/// and the newest as suggestions, the last two never Personal.
struct ConversationQuery: EntityStringQuery {
    static let suggestions = 20

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [ConversationEntity] {
        let state = try await IntentState.ready()
        let wanted = Set(identifiers)
        return state.meetings.filter { wanted.contains($0.id) }.map(ConversationEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [ConversationEntity] {
        let state = try await IntentState.ready()
        let words = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return [] }
        return ConversationEntity.shown(in: state.meetings).filter { $0.title.localizedStandardContains(words) }
    }

    @MainActor
    func suggestedEntities() async throws -> [ConversationEntity] {
        let state = try await IntentState.ready()
        return Array(ConversationEntity.shown(in: state.meetings).prefix(Self.suggestions))
    }
}

/// Open Conversation: Spotlight's action on a conversation it found, and a Shortcuts action.
struct OpenConversationIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Conversation"
    static let description = IntentDescription("Opens a conversation in Daybook.")
    static let openAppWhenRun = true

    @Parameter(title: "Conversation")
    var target: ConversationEntity

    init() {}

    init(target: ConversationEntity) {
        self.target = target
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try IntentActions.open(target.id, in: try await IntentState.ready())
        return .result()
    }
}

/// Where Spotlight's copy goes. The system's index in the app; tests keep a list.
protocol ConversationIndexing: Sendable {
    /// Everything this app indexed before goes, and `entities` replace it (the first pass after launch).
    func replaceAll(with entities: [ConversationEntity]) async
    func update(_ entities: [ConversationEntity], removing removed: [UUID]) async
}

/// The system's Spotlight index. What can't be indexed is logged and left: Spotlight is a convenience, never the library.
struct SpotlightConversationIndex: ConversationIndexing {
    private static let log = Logger(subsystem: "local.daybook", category: "Spotlight")

    func replaceAll(with entities: [ConversationEntity]) async {
        let index = CSSearchableIndex.default()
        do {
            try await index.deleteAppEntities(ofType: ConversationEntity.self)
            if !entities.isEmpty { try await index.indexAppEntities(entities) }
        } catch {
            Self.log.notice("Conversations couldn't be indexed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func update(_ entities: [ConversationEntity], removing removed: [UUID]) async {
        let index = CSSearchableIndex.default()
        do {
            if !removed.isEmpty { try await index.deleteAppEntities(identifiedBy: removed, ofType: ConversationEntity.self) }
            if !entities.isEmpty { try await index.indexAppEntities(entities) }
        } catch {
            Self.log.notice("Conversations couldn't be indexed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Keeps Spotlight's copy of the library's conversations in step with the library: everything once the library opens,
/// then what changed, a moment after a burst of edits. A conversation moved to Personal, or to the Trash, goes.
@MainActor
final class ConversationSpotlight {
    private weak var state: AppState?
    private let index: any ConversationIndexing
    private let delay: Duration
    private var watch: ObservationWatch?
    /// What Spotlight has now, by ID; nil before the first pass.
    private var indexed: [UUID: ConversationEntity]?
    /// The passes, one after another.
    private var work: Task<Void, Never>?

    init(state: AppState, index: any ConversationIndexing = SpotlightConversationIndex(), delay: Duration = .seconds(2)) {
        self.state = state
        self.index = index
        self.delay = delay
    }

    func start() {
        watch = ObservationWatch.values(of: { [weak self] in
            guard let state = self?.state else { return 0 }
            _ = state.isReady
            return state.libraryRevision
        }, delay: delay) { [weak self] _ in self?.refresh() }
        refresh()
    }

    func stop() {
        watch?.cancel()
        watch = nil
    }

    /// Waits for the passes sent so far (tests).
    func settled() async { await work?.value }

    /// Sends Spotlight what's different from its copy.
    func refresh() {
        guard let state, state.isReady else { return }
        let next = Dictionary(uniqueKeysWithValues: ConversationEntity.shown(in: state.meetings).map { ($0.id, $0) })
        let previous = work, index = self.index
        if let indexed {
            let changed = next.values.filter { indexed[$0.id] != $0 }.sorted { $0.date > $1.date }
            let removed = indexed.keys.filter { next[$0] == nil }.sorted { $0.uuidString < $1.uuidString }
            guard !changed.isEmpty || !removed.isEmpty else { return }
            work = Task { await previous?.value; await index.update(changed, removing: removed) }
        } else {
            let all = next.values.sorted { $0.date > $1.date }
            work = Task { await previous?.value; await index.replaceAll(with: all) }
        }
        indexed = next
    }
}
