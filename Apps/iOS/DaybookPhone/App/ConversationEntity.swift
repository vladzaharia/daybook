import AppIntents
import CoreSpotlight
import DaybookKit
import Foundation

/// A conversation, for Siri, Shortcuts, and Spotlight: its title and date, as on the Mac. Open Conversation
/// opens it; Spotlight lists every conversation but Personal ones (`ConversationIndex`, by DaybookKit's
/// `SpotlightPlan`), by title and dates only, never what was said.
struct ConversationEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Conversation"
    static let defaultQuery = ConversationQuery()

    let id: UUID
    @Property(title: "Title") var title: String
    @Property(title: "Date") var date: Date

    init(id: UUID, title: String, date: Date) {
        self.id = id
        self.title = title
        self.date = date
    }

    init(_ entry: SpotlightPlan.Entry) {
        self.init(id: entry.id, title: entry.title, date: entry.date)
    }

    /// "Nov 10, 2026 at 9:00 AM": the subtitle in Shortcuts, and the description in Spotlight.
    var when: String { date.formatted(date: .abbreviated, time: .shortened) }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(when)")
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.title = title
        attributes.contentDescription = when
        attributes.contentCreationDate = date
        attributes.metadataModificationDate = date
        return attributes
    }
}

/// Finds conversations by ID (any conversation, so a shortcut made with one keeps working), by words in their
/// titles, and the latest ones as suggestions, the last two never Personal, as on the Mac.
struct ConversationQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [ConversationEntity] {
        let meetings = try await Self.library()
        return identifiers.compactMap { id in meetings.first { $0.id == id }.map { ConversationEntity(SpotlightPlan.Entry($0)) } }
    }

    @MainActor
    func entities(matching string: String) async throws -> [ConversationEntity] {
        let words = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return try await suggestedEntities() }
        return try await Self.library()
            .filter { SpotlightPlan.isShown($0) && $0.title.localizedStandardContains(words) }
            .sorted { $0.date > $1.date }
            .prefix(Self.limit)
            .map { ConversationEntity(SpotlightPlan.Entry($0)) }
    }

    @MainActor
    func suggestedEntities() async throws -> [ConversationEntity] {
        SpotlightPlan.entries(try await Self.library()).prefix(Self.limit).map(ConversationEntity.init)
    }

    static let limit = 20

    /// The library's conversations, loaded first when an intent woke Daybook.
    @MainActor
    static func library() async throws -> [Meeting] {
        guard let model = AppDestinations.model else { throw RecordingCommandError.appUnavailable }
        if !model.library.controller.isLoaded {
            // Kept locked ("Protect while iPhone is locked") and locked: it can't be read until it's unlocked.
            guard model.libraryReadable else { throw RecordingCommandError.failed(Self.unlockToFind) }
            try await model.library.reload()
        }
        return model.library.controller.meetings
    }

    static let unlockToFind = "Unlock iPhone to find conversations."
}

/// Open Conversation: Daybook opens at that conversation's page.
struct OpenConversationIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Conversation"
    static let description = IntentDescription("Opens a conversation in Daybook.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Conversation")
    var target: ConversationEntity

    init() {}

    init(target: ConversationEntity) {
        self.target = target
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppDestinations.open(.conversation(target.id))
        return .result()
    }
}

/// New Note: a conversation that's only notes, open with the keyboard on them, as the library's New Note.
struct NewNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "New Note"
    static let description = IntentDescription("Starts a conversation that's only your notes.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @MainActor
    func perform() async throws -> some IntentResult {
        AppDestinations.open(.newNote)
        return .result()
    }
}

/// Keeps Spotlight's list of the library in step with it, by the plan both apps share (DaybookKit's `SpotlightPlan`:
/// every conversation that isn't Personal, by title and date; Personal ones, and those in the Trash, are never listed,
/// and leave the list when they become so), and tells Siri which conversations it may name.
@MainActor
final class ConversationIndex {
    /// Where the list goes: Spotlight, or nowhere (tests).
    struct Indexer {
        var isActive: Bool
        var index: @MainActor ([SpotlightPlan.Entry]) async -> Void
        var remove: @MainActor ([UUID]) async -> Void
        /// Takes every conversation out, whatever an earlier run listed.
        var removeAll: @MainActor () async -> Void
        /// Siri's phrases with a conversation in them ("Open Pricing review in Daybook") learn the ones
        /// `ConversationQuery` suggests now.
        var refreshPhrases: @MainActor () -> Void = {}

        static let none = Indexer(isActive: false, index: { _ in }, remove: { _ in }, removeAll: {})

        static let system = system(protected: false)

        /// Spotlight's own index, or (`protected`, "Protect while iPhone is locked") one of Daybook's kept as the library
        /// is: class A, unreadable while the iPhone is locked.
        static func system(protected: Bool) -> Indexer {
            let index: @MainActor () -> CSSearchableIndex = {
                protected ? CSSearchableIndex(name: "Daybook", protectionClass: .complete) : CSSearchableIndex.default()
            }
            return Indexer(isActive: true, index: { entries in
                try? await index().indexAppEntities(entries.map(ConversationEntity.init))
            }, remove: { ids in
                try? await index().deleteAppEntities(identifiedBy: ids, ofType: ConversationEntity.self)
            }, removeAll: {
                try? await index().deleteAppEntities(ofType: ConversationEntity.self)
            }, refreshPhrases: {
                DaybookShortcuts.updateAppShortcutParameters()
            })
        }
    }

    private var indexer: Indexer
    /// What the last update listed, to list again in another index (`use`).
    private var entries: [SpotlightPlan.Entry]?
    /// Waits until the index can be written: while "Protect while iPhone is locked" keeps it, until the iPhone is unlocked.
    var untilWritable: @MainActor () async -> Void = {}
    /// What Spotlight has now.
    private var plan = SpotlightPlan()
    private var updating: Task<Void, Never>?
    /// The conversations Siri was last told it may name (`ConversationQuery.suggestedEntities`); nil until
    /// this run's first update, which tells it what changed while Daybook wasn't running.
    private var named: [SpotlightPlan.Entry]?
    private var naming: Task<Void, Never>?
    /// How long Siri's phrases wait for the list to settle, so a title being typed tells it once.
    private let namingDelay: Duration

    init(indexer: Indexer, namingDelay: Duration = .seconds(5)) {
        self.indexer = indexer
        self.namingDelay = namingDelay
    }

    /// Lists what's new or changed and removes what went (Trash, Personal), after any update before it.
    /// A run's first update starts Spotlight's list over: what changed while Daybook wasn't running (a
    /// conversation trashed or made Personal on another device) never stays listed. When the conversations
    /// Siri may name change, it's told once they've settled.
    func update(_ entries: [SpotlightPlan.Entry]) {
        self.entries = entries
        let suggested = Array(entries.prefix(ConversationQuery.limit))
        if suggested != named {
            named = suggested
            naming?.cancel()
            let refresh = indexer.refreshPhrases, delay = namingDelay
            naming = Task {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                refresh()
            }
        }
        guard let pass = plan.pass(to: entries) else { return }
        let previous = updating, indexer = self.indexer
        updating = Task { [weak self] in
            await previous?.value
            await self?.untilWritable()
            if pass.startsOver { await indexer.removeAll() }
            if !pass.removed.isEmpty { await indexer.remove(pass.removed) }
            if !pass.listed.isEmpty { await indexer.index(pass.listed) }
        }
    }

    /// Lists the library in `next` from now on ("Protect while iPhone is locked" switched): it starts over there with what
    /// was listed, and the index it leaves is emptied.
    func use(_ next: Indexer) {
        let previous = updating, old = indexer
        indexer = next
        plan = SpotlightPlan()
        updating = Task { [weak self] in
            await previous?.value
            await self?.untilWritable()
            await old.removeAll()
        }
        if let entries { update(entries) }
    }

    /// Waits for what's been asked of Spotlight and Siri (tests).
    func settle() async {
        await updating?.value
        await naming?.value
    }
}
