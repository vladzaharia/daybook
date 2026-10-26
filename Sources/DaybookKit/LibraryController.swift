import Combine
import DaybookCore
import DaybookDevices
import Foundation

/// The library both apps share: its conversations, folders, templates, and vocabulary; loading and
/// saving through `MeetingStore`; every edit, with the Version History records the conversation
/// keeps; applying sync; bringing in recordings; and processing requests.
///
/// It knows nothing about recording, windows, or local models. The Mac's `AppState` holds one and
/// adds those; the iPhone app holds one too. Everything here runs on the main actor; the store,
/// fusion, and sync engine do their work off it.
@MainActor
public final class LibraryController: ObservableObject {
    /// The library's conversations, in the order they were loaded or added.
    @Published public var meetings: [Meeting] = []
    /// Folders, templates, and vocabulary: synced library settings.
    @Published public private(set) var metadata = LibraryMetadata()
    /// Vocabulary, mirrored into `metadata.vocabulary` when it changes.
    @Published public var glossary: [GlossaryTerm] = []
    /// The last thing that went wrong, in a sentence for the person.
    @Published public var errorMessage: String?
    /// The system's own words for it, shown only behind Details.
    @Published public var errorDetails: String?
    /// The last thing worth knowing (a sync warning, a recording already in the library).
    @Published public var notice: String?
    /// The store is open and the conversations are loaded.
    @Published public private(set) var isLoaded = false
    /// A sync result is being applied: its saves don't ask for another sync, and a device's
    /// processing waits.
    public private(set) var isApplyingSync = false

    public let rootURL: URL
    /// The sync folder, when the app has one. Saves ask it to sync.
    public let sync: LibrarySyncController?

    private var store: MeetingStore?
    private var glossaryStore: GlossaryStore?
    /// Saves, coalesced and written in the background (`LibrarySaveQueue`).
    private let saves = LibrarySaveQueue()
    /// Saves that failed, by conversation ID, "library-settings", or "glossary", until one succeeds.
    private var persistenceErrors: [String: String] { saves.failures }
    /// Edits since the last sync request; the request goes out once they're written.
    private var syncWanted = false
    /// False when `library.json` couldn't be read or a newer Daybook wrote it: never overwritten.
    private var metadataWritable = true
    private var lifecycle: AnyCancellable?
    private var notesTasks: [UUID: Task<Void, Never>] = [:]
    private var noteOriginals: [UUID: String] = [:]
    private var locked = false
    /// Tasks waiting for the lock, in order; each is resumed with true when it's handed the lock.
    private var lockWaiters: [(id: UUID, waiting: CheckedContinuation<Bool, Never>)] = []

    /// How long a save waits after an edit, so a burst of edits (typing) writes once.
    public var saveDelay: Duration {
        get { saves.delay }
        set { saves.delay = newValue }
    }
    /// Conversations edited (and whether settings were) while the current sync pass ran.
    private var editedDuringSync = Set<UUID>()
    private var settingsEditedDuringSync = false
    /// The saves being made are the pass's own.
    private var savingSyncResult = false

    public init(rootURL: URL, sync: LibrarySyncController?) {
        self.rootURL = rootURL
        self.sync = sync
        saves.onFailure = { [weak self] key, error in self?.reportSaveFailure(key, error) }
        saves.onIdle = { [weak self] in
            guard let self, self.syncWanted else { return }
            self.syncWanted = false
            self.sync?.requestSync()
        }
        #if canImport(UIKit)
        lifecycle = flushWhenBackgrounded()
        #endif
    }

    // MARK: Loading

    /// Opens the store and loads the conversations, vocabulary, and library settings. Work that was
    /// running when the app last quit is marked interrupted; nothing is lost. Only a library folder
    /// that can't be opened at all fails: a damaged or newer settings file, unreadable vocabulary, or
    /// a conversation that can't be saved now is a notice, and the library opens.
    public func load() async throws {
        guard !isLoaded else { return }
        let store = try MeetingStore(rootURL: rootURL)
        let glossaryStore = try GlossaryStore(rootURL: rootURL)
        self.store = store; self.glossaryStore = glossaryStore
        meetings = try await store.list()
        var warnings = await store.warnings
        do { glossary = try await glossaryStore.list() }
        catch { glossary = []; warnings.append("Your vocabulary couldn’t be read.") }
        let settings = await store.loadLibraryMetadata()
        metadataWritable = settings.isWritable
        warnings += settings.warnings
        if let saved = settings.metadata {
            metadata = saved
            if !metadata.vocabulary.isEmpty { glossary = metadata.vocabulary.compactMap(\.value) }
        } else {
            metadata.vocabulary = glossary.map { .init(id: $0.id.uuidString, value: $0) }
        }
        // Only work this device was doing: a status synced from another device's job stays as it is.
        // A library that predates the record (nil) treats every such status as this device's, as before.
        let ownWork = Self.loadLocalWork(at: localWorkURL)
        localWork = []
        for index in meetings.indices where [.transcribing, .summarizing, .recording].contains(meetings[index].status)
            && ownWork?.contains(meetings[index].id) != false {
            var meeting = meetings[index]
            meeting.status = .imported
            meeting.errorMessage = "Processing was interrupted. Your audio and notes are saved."
            meetings[index] = meeting
            persist(meeting, requestingSync: false)
        }
        // The sweep is done: from here the record lists only work this run starts.
        saveLocalWork()
        await saves.drain()
        if !warnings.isEmpty { notice = warnings.joined(separator: "\n") }
        isLoaded = true
    }

    // MARK: Reading

    public func meeting(_ id: UUID) -> Meeting? { meetings.first { $0.id == id } }

    public var folders: [LibraryFolder] {
        metadata.folders.compactMap(\.value).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public var templates: [SummaryTemplate] { SummaryTemplate.catalog(templates: metadata.templates.compactMap(\.value)) }
    public var allTags: [String] { Array(Set(meetings.flatMap { $0.tags ?? [] })).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }

    /// The template a conversation is summarized with; nil for Automatic.
    public func resolvedTemplate(for meeting: Meeting) -> SummaryTemplate? {
        guard meeting.templateID != nil || meeting.kind != .auto else { return nil }
        return SummaryTemplate.resolved(id: meeting.templateID, kind: meeting.kind, templates: templates)
    }

    /// The template picker's value: a template ID, or "auto".
    public func templateSelection(for id: UUID) -> String {
        guard let meeting = meeting(id) else { return "auto" }
        return meeting.templateID ?? (meeting.kind == .auto ? "auto" : resolvedTemplate(for: meeting)?.id ?? "auto")
    }

    /// Where a recording's original bytes are, for playback and processing.
    public func audioURL(for track: RecordingTrack, in meetingID: UUID) async throws -> URL {
        guard let store else { throw DaybookError.libraryUnavailable }
        return try await store.audioURL(for: track, in: meetingID)
    }

    /// The conversation that already holds these exact bytes, if any. The file is hashed off the
    /// main actor and matched against the digests the library already has in memory; only a
    /// conversation that claims the digest has its original read to confirm it.
    public func existingMeeting(containingAudioAt url: URL) async throws -> Meeting? {
        guard let store else { throw DaybookError.libraryUnavailable }
        let digest = try await AudioDigest.sha256(contentsOf: url)
        let candidates = meetings.filter { $0.tracks.contains { $0.sha256 == digest } }
        guard !candidates.isEmpty, let found = await store.verifiedMeeting(withDigest: digest, among: candidates) else { return nil }
        return meeting(found.id) ?? found
    }

    // MARK: Saving

    /// Adds a new, empty conversation and returns its ID.
    @discardableResult
    public func newMeeting(title: String = "Untitled Conversation", date: Date = Date(),
                           folderID: UUID? = nil, placement: LibraryPlacement? = nil) -> UUID {
        let meeting = Meeting(title: title, date: date, folderID: folderID, placement: placement)
        meetings.insert(meeting, at: 0)
        persist(meeting)
        return meeting.id
    }

    /// Adds a conversation made elsewhere (a recovered recording) and saves it.
    public func add(_ meeting: Meeting) {
        guard self.meeting(meeting.id) == nil else { return }
        meetings.append(meeting)
        persist(meeting)
    }

    /// Changes a conversation and saves it when something changed. Version History entries are
    /// the change's own: `Meeting`'s editing methods record them.
    public func update(_ id: UUID, _ change: (inout Meeting) -> Void) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        let before = meetings[index]
        change(&meetings[index])
        guard meetings[index] != before else { return }
        meetings[index].updatedAt = Date()
        persist(meetings[index])
    }

    /// Saves a conversation in the background. Saves are coalesced: the latest snapshot of each
    /// conversation is the one written, shortly after the last edit (`saveDelay`), or at `flush`.
    private func persist(_ meeting: Meeting, requestingSync: Bool = true) {
        guard let store else { return }
        trackLocalWork(meeting)
        noteChange(meeting.id, requestingSync: requestingSync)
        let id = meeting.id
        saves.enqueue(id.uuidString) { [weak self] in
            // A conversation that left the library (the Trash, a deletion that synced) has nothing to save.
            guard let self, self.meeting(id) != nil else { return }
            do { try await store.save(meeting) }
            catch LibraryError.trashedMeeting, LibraryError.missingMeeting { }
        }
    }

    private func persistMetadata(requestingSync: Bool = true) {
        noteChange(nil, requestingSync: requestingSync)
        // Settings that couldn't be read, or that a newer Daybook wrote, are never overwritten.
        guard let store, metadataWritable else { return }
        let snapshot = metadata
        saves.enqueue("library-settings") { try await store.saveLibraryMetadata(snapshot) }
    }

    /// What couldn't be saved, in plain words; the system's own words go to `errorDetails`.
    private func reportSaveFailure(_ key: String, _ error: Error) {
        switch key {
        case "library-settings": errorMessage = "Your folders and templates couldn’t be saved. Daybook tries again with your next change."
        case "glossary": errorMessage = "Your vocabulary couldn’t be saved. Daybook tries again with your next change."
        default:
            let title = meetings.first { $0.id.uuidString == key }?.title ?? "a conversation"
            errorMessage = "Changes to “\(title)” couldn’t be saved. Daybook tries again with your next change."
        }
        errorDetails = error.localizedDescription
    }

    // MARK: Work this device is doing

    /// Conversations this device put into recording, transcribing, or summarizing, kept beside the library
    /// (never synced), so a launch after a crash resets only its own interrupted work.
    private var localWork = Set<UUID>()
    private var localWorkURL: URL { rootURL.appendingPathComponent("local-work.json") }

    private func trackLocalWork(_ meeting: Meeting) {
        // A status that arrived through sync describes another device's job.
        guard !savingSyncResult else { return }
        let active = [.transcribing, .summarizing, .recording].contains(meeting.status)
        let changed = active ? localWork.insert(meeting.id).inserted : localWork.remove(meeting.id) != nil
        if changed { saveLocalWork() }
    }

    /// Written in order on a serial queue, so an older record never lands after a newer one.
    private func saveLocalWork() {
        let ids = localWork.map(\.uuidString).sorted(), url = localWorkURL
        Self.localWorkQueue.async { try? JSONEncoder().encode(ids).write(to: url, options: .atomic) }
    }

    private static let localWorkQueue = DispatchQueue(label: "local.daybook.library.local-work", qos: .utility)

    /// Waits for record writes queued so far (tests).
    static func drainLocalWorkWrites() { localWorkQueue.sync {} }

    /// Nil when the library has no record yet (written by an earlier Daybook).
    static func loadLocalWork(at url: URL) -> Set<UUID>? {
        guard let data = try? Data(contentsOf: url), let ids = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        return Set(ids.compactMap(UUID.init(uuidString:)))
    }

    /// Every save asks for a sync pass (once the saves are written), except the saves that apply one. An
    /// edit made while a pass runs isn't in that pass: it's remembered, and asks for another pass when this
    /// one ends.
    private func noteChange(_ id: UUID?, requestingSync: Bool = true) {
        guard requestingSync, !savingSyncResult else { return }
        guard isApplyingSync else { syncWanted = true; return }
        if let id { editedDuringSync.insert(id) } else { settingsEditedDuringSync = true }
    }

    /// Finishes note edits in progress and writes every waiting save now, returning once none is
    /// left (saves queued meanwhile too). A save that failed before is tried again with what's
    /// current; one for a conversation no longer in the library is dropped.
    public func flush() async {
        for id in Array(noteOriginals.keys) { finishNoteEdit(id) }
        for key in persistenceErrors.keys {
            switch key {
            case "library-settings": persistMetadata(requestingSync: false)
            case "glossary": persistGlossaryFile()
            default:
                if let id = UUID(uuidString: key), let meeting = meeting(id) { persist(meeting, requestingSync: false) }
                else { saves.forget(key) }
            }
        }
        await saves.drain()
    }

    /// A durability barrier for operations that discard recovery data or acknowledge a sync pull:
    /// every save is written, and everything written since the last barrier is flushed to permanent
    /// storage (`MeetingStore.synchronizeWrites`). Waiting for the save queue alone does not mean its
    /// writes succeeded. With `ids`, only those conversations' failed saves count (an unrelated
    /// conversation that can't be saved doesn't stop an import); without, every failure does.
    public func flushDurably(_ ids: Set<UUID>? = nil, includingSettings: Bool = false) async throws {
        await flush()
        // What the saves and imports wrote since the last barrier reaches permanent storage.
        if let store {
            do { try await store.synchronizeWrites() } catch { throw DaybookError.saveFailed(error.localizedDescription) }
        }
        let failures = persistenceErrors.filter { key, _ in
            guard let ids else { return true }
            return UUID(uuidString: key).map(ids.contains) ?? includingSettings
        }
        guard failures.isEmpty else {
            throw DaybookError.saveFailed(failures.values.sorted().joined(separator: "\n"))
        }
    }

    /// Saves carried out since the library opened (tests count writes per burst of edits).
    var savesCompleted: Int { saves.completed }

    // MARK: Editing a conversation

    /// The notes as typed. The text saves shortly after typing (or at `flush`); a Version History
    /// entry is written once typing pauses. `captureTime`, while this conversation is being
    /// recorded, timestamps new paragraphs.
    public func editNotes(_ id: UUID, text: String, captureTime: TimeInterval? = nil) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        var meeting = meetings[index]
        if noteOriginals[id] == nil { noteOriginals[id] = meeting.notes }
        let previous = meeting.timedNotes ?? NoteTimeline.reconcile(previous: [], text: meeting.notes, captureTime: nil)
        meeting.timedNotes = NoteTimeline.reconcile(previous: previous, text: text, captureTime: captureTime)
        meeting.notes = text
        meeting.updatedAt = Date()
        // One change for observers; the save is coalesced with the rest of the burst, while
        // history entries are grouped after typing pauses.
        meetings[index] = meeting
        persist(meeting)
        notesTasks[id]?.cancel()
        notesTasks[id] = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(900)); self?.finishNoteEdit(id) } catch { }
        }
    }

    private func finishNoteEdit(_ id: UUID) {
        notesTasks.removeValue(forKey: id)?.cancel()
        guard let original = noteOriginals.removeValue(forKey: id) else { return }
        update(id) { meeting in
            if original != meeting.notes { meeting.revisions.append(.init(field: "notes", oldValue: original, newValue: meeting.notes)) }
        }
    }

    public func rename(_ id: UUID, to title: String) { update(id) { $0.title = title } }

    /// Ticks a next step off, or back on. A refreshed summary keeps the choice.
    public func setNextStep(_ itemID: UUID, completed: Bool, in id: UUID) {
        update(id) { meeting in
            guard let index = meeting.summary?.actionItems.firstIndex(where: { $0.id == itemID }) else { return }
            meeting.summary?.actionItems[index].completed = completed
        }
    }

    /// Recorded in Version History.
    public func renameSpeaker(_ speakerID: String, to name: String, in id: UUID) {
        update(id) { $0.renameSpeaker(id: speakerID, name: name) }
    }

    /// Corrects one passage of the transcript; the model's original stays, and the change is in Version History.
    public func correctPassage(_ segmentID: UUID, text: String, in id: UUID) {
        update(id) { $0.correctSegment(id: segmentID, text: text) }
    }

    /// Applies a correction from an earlier transcript to a passage of the new one, or dismisses it.
    public func resolveCorrectionTransfer(_ issueID: UUID, targetSegmentID: UUID?, in id: UUID) {
        update(id) { $0.resolveCorrectionTransfer(id: issueID, targetSegmentID: targetSegmentID) }
    }

    /// Version History › Restore. The text it replaces gets its own entry.
    public func restore(_ revision: MeetingRevision, in id: UUID) {
        update(id) { RevisionRestore.apply(revision, to: &$0) }
    }

    /// Chooses a template, or "auto". Returns whether the choice changed, so the app can summarize again.
    @discardableResult
    public func chooseTemplate(_ templateID: String, for id: UUID) -> Bool {
        guard let before = meeting(id) else { return false }
        let kind = templates.first { $0.id == templateID }?.kind ?? .auto
        update(id) { value in
            value.templateID = templateID == "auto" ? nil : templateID
            value.kind = kind
        }
        return meeting(id) != before
    }

    public func moveToFolder(_ ids: [UUID], _ folder: UUID?) {
        for id in ids { update(id) { $0.folderID = folder } }
    }

    public func setPlacement(_ ids: [UUID], _ placement: LibraryPlacement?) {
        for id in ids { update(id) { $0.placement = placement } }
    }

    /// Tags from comma-separated text: trimmed, without duplicates that differ only in case.
    public func setTags(_ id: UUID, text: String) {
        var seen = Set<String>()
        let tags = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        update(id) { $0.tags = tags }
    }

    /// A bookmark at a moment of the conversation (while recording, `trackID` is nil and the time
    /// is the recording's elapsed time) or of one recording (during playback).
    /// `bookmarkID` is the bookmark's own ID, when another device made it (Daybook on iPhone over the
    /// link), so its copy and this one are one bookmark once they sync. A bookmark already here is kept.
    public func addBookmark(id bookmarkID: UUID = UUID(), in id: UUID, trackID: UUID? = nil, at seconds: Double) {
        guard seconds.isFinite, let meeting = meeting(id), !meeting.highlights.contains(where: { $0.id == bookmarkID }) else { return }
        if let trackID {
            guard seconds >= 0, meeting.tracks.contains(where: { $0.id == trackID }) else { return }
            update(id) { $0.highlights.append(Highlight(id: bookmarkID, trackID: trackID, time: seconds, text: "")) }
        } else {
            update(id) { $0.highlights.append(Highlight(id: bookmarkID, time: max(0, seconds), text: "")) }
        }
    }

    public func setBookmarkText(_ highlightID: UUID, text: String, in id: UUID) {
        update(id) { value in
            if let index = value.highlights.firstIndex(where: { $0.id == highlightID }) { value.highlights[index].text = text }
        }
    }

    public func removeBookmark(_ highlightID: UUID, in id: UUID) {
        update(id) { $0.highlights.removeAll { $0.id == highlightID } }
    }

    /// Adjust Timing: places a recording on the conversation's timeline by hand, or clears it.
    public func setOffset(_ id: UUID, trackID: UUID, seconds: Double?) {
        update(id) { meeting in
            if let index = meeting.tracks.firstIndex(where: { $0.id == trackID }) {
                if let seconds { meeting.applyPlacements([trackID: SourceAlignment(method: .manual, offset: seconds)]) }
                else { meeting.tracks[index].alignment = nil }
                meeting.tracks[index].offset = seconds
            }
            for index in meeting.transcripts.indices where meeting.transcripts[index].trackID == trackID { meeting.transcripts[index].knownOffset = seconds }
        }
        Task { await realign(id) }
    }

    /// Fuses a conversation's transcripts again, and carries saved corrections over, off the main
    /// actor. Skipped if its recordings or transcripts changed meanwhile.
    public func realign(_ id: UUID) async {
        guard let snapshot = meeting(id) else { return }
        let (prepared, settled) = await detachedWork(priority: .userInitiated) {
            let fusion = SourceFusion.fuse(snapshot)
            return (snapshot.preparingFusion(fusion.fusion), fusion.settled)
        }
        // Applied even when the caller was cancelled meanwhile: it matches the transcripts kept.
        guard let current = meeting(id), current.transcripts == snapshot.transcripts,
              current.tracks == snapshot.tracks, current.audioAlignments == snapshot.audioAlignments else { return }
        update(id) { $0.applyFusion(prepared); $0.applyPlacements(settled) }
    }

    // MARK: Folders and templates

    public func saveFolder(_ folder: LibraryFolder) {
        let name = folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var value = Self.keepingNewerFields(folder, of: metadata.folders.first { $0.id == folder.id.uuidString }?.value)
        value.name = name
        metadata.folders.removeAll { $0.id == folder.id.uuidString }
        metadata.folders.append(.init(id: folder.id.uuidString, value: value))
        persistMetadata()
    }

    /// An edit made from a fresh value (a rename) keeps what a newer Daybook added to the item it edits.
    private static func keepingNewerFields<T>(_ value: T, of stored: T?) -> T where T: PreservesUnknownFields {
        guard value.unknownFields.isEmpty, let stored else { return value }
        var kept = value
        kept.unknownFields = stored.unknownFields
        return kept
    }

    /// Creates a folder and moves conversations into it. Returns the folder's ID.
    @discardableResult
    public func createFolder(named name: String, moving ids: [UUID] = []) -> UUID {
        let folder = LibraryFolder(name: name)
        saveFolder(folder)
        moveToFolder(ids, folder.id)
        return folder.id
    }

    /// Removes a folder; its conversations stay in the library, outside any folder.
    public func removeFolder(_ id: UUID) {
        metadata.folders.removeAll { $0.id == id.uuidString }
        metadata.folders.append(.init(id: id.uuidString, value: nil)); persistMetadata()
        for meeting in meetings where meeting.folderID == id { update(meeting.id) { $0.folderID = nil } }
    }

    public func saveTemplate(_ template: SummaryTemplate) {
        var value = Self.keepingNewerFields(template, of: metadata.templates.first { $0.id == template.id }?.value)
        value.updatedAt = Date()
        metadata.templates.removeAll { $0.id == value.id }
        metadata.templates.append(.init(id: value.id, value: value)); persistMetadata()
    }

    public func removeTemplate(_ id: String) {
        metadata.templates.removeAll { $0.id == id }
        metadata.templates.append(.init(id: id, value: nil)); persistMetadata()
    }

    // MARK: Recorder ownership

    /// Recorders a device manages over Bluetooth. Synced library settings, like folders and templates.
    public var recorderOwners: [RecorderOwnership] { metadata.recorderOwners }

    public func recorderOwner(kind: String, serial: String) -> RecorderOwnership? {
        metadata.recorderOwner(kind: kind, serial: serial)
    }

    /// This device takes over the recorder: other devices stop connecting to it and get its
    /// recordings through sync. Returns the record written.
    @discardableResult
    public func claimRecorder(kind: String, serial: String, deviceClass: SyncDeviceClass,
                              by device: ProcessingRequest.Device? = nil, at now: Date = Date()) -> RecorderOwnership {
        let owner = device ?? thisDevice
        let record = RecorderOwnership(kind: kind, serial: serial, ownerID: owner.id, ownerName: owner.name,
                                       ownerClass: deviceClass, claimedAt: now)
        var recorders = metadata.recorders ?? []
        recorders.removeAll { $0.id == record.id }
        recorders.append(.init(id: record.id, value: record, modifiedAt: now))
        metadata.recorders = recorders
        persistMetadata()
        return record
    }

    /// Nobody manages the recorder any more (a deletion marker, so it syncs). With `onlyIfOwnedBy`,
    /// only when that device is the owner, so removing a recorder here never undoes another
    /// device's claim.
    public func releaseRecorder(kind: String, serial: String, onlyIfOwnedBy deviceID: String? = nil) {
        guard let current = recorderOwner(kind: kind, serial: serial) else { return }
        if let deviceID, current.ownerID != deviceID { return }
        var recorders = metadata.recorders ?? []
        recorders.removeAll { $0.id == current.id }
        recorders.append(.init(id: current.id, value: nil))
        metadata.recorders = recorders
        persistMetadata()
    }

    // MARK: Recorder handoff

    /// Handoffs travelling through sync (docs/devices.md, "Handing a recorder over"). `RecorderHandoff`
    /// reads and writes them; they sync like ownership.
    public var recorderHandoffs: [RecorderHandoffRecord] { metadata.recorderHandoffs }

    public func recorderHandoff(kind: String, serial: String) -> RecorderHandoffRecord? {
        metadata.recorderHandoff(kind: kind, serial: serial)
    }

    /// Writes a recorder's handoff record (the later write wins on every device).
    public func saveRecorderHandoff(_ record: RecorderHandoffRecord, at now: Date = Date()) {
        var value = record
        value.updatedAt = now
        var handoffs = metadata.handoffs ?? []
        handoffs.removeAll { $0.id == value.recorderID }
        handoffs.append(.init(id: value.recorderID, value: value, modifiedAt: now))
        metadata.handoffs = handoffs
        persistMetadata()
    }

    /// The handoff is over: a deletion marker, so an older copy of the record doesn't come back.
    /// With `onlyID`, only when the record is that request's.
    public func clearRecorderHandoff(kind: String, serial: String, onlyID: UUID? = nil, at now: Date = Date()) {
        guard let current = recorderHandoff(kind: kind, serial: serial) else { return }
        if let onlyID, current.id != onlyID { return }
        var handoffs = metadata.handoffs ?? []
        handoffs.removeAll { $0.id == current.recorderID }
        handoffs.append(.init(id: current.recorderID, value: nil, modifiedAt: now))
        metadata.handoffs = handoffs
        persistMetadata()
    }

    // MARK: Vocabulary

    public func saveGlossaryTerm(_ term: GlossaryTerm) {
        if let index = glossary.firstIndex(where: { $0.id == term.id }) { glossary[index] = Self.keepingNewerFields(term, of: glossary[index]) }
        else { glossary.append(term) }
        persistGlossary()
    }

    public func removeGlossaryTerm(_ id: UUID) { glossary.removeAll { $0.id == id }; persistGlossary() }

    /// Terms a summary suggested, proposed for one conversation. Edits made meanwhile win.
    public func proposeTerms(_ terms: [String], for meetingID: UUID) async throws {
        guard let glossaryStore else { return }
        await flush()
        let before = glossary
        try await glossaryStore.propose(terms.map { GlossaryTerm(term: $0) }, for: meetingID)
        let loaded = try await glossaryStore.list()
        let removed = Set(before.map(\.id)).subtracting(glossary.map(\.id))
        let edited = glossary.filter { term in before.first(where: { $0.id == term.id }) != term }
        var merged = loaded.filter { !removed.contains($0.id) }
        for term in edited {
            if let index = merged.firstIndex(where: { $0.id == term.id }) { merged[index] = term } else { merged.append(term) }
        }
        glossary = merged
        persistGlossary()
    }

    private func persistGlossary() {
        let ids = Set(glossary.map { $0.id.uuidString })
        for index in metadata.vocabulary.indices where !ids.contains(metadata.vocabulary[index].id) && metadata.vocabulary[index].value != nil {
            metadata.vocabulary[index].value = nil; metadata.vocabulary[index].modifiedAt = Date()
        }
        for term in glossary {
            if let index = metadata.vocabulary.firstIndex(where: { $0.id == term.id.uuidString }) {
                if metadata.vocabulary[index].value != term { metadata.vocabulary[index] = .init(id: term.id.uuidString, value: term) }
            } else { metadata.vocabulary.append(.init(id: term.id.uuidString, value: term)) }
        }
        persistMetadata()
        persistGlossaryFile()
    }

    private func persistGlossaryFile() {
        guard let glossaryStore else { return }
        let snapshot = glossary
        saves.enqueue("glossary") { try await glossaryStore.save(snapshot) }
    }

    // MARK: Trash

    /// Moves a conversation to the library's Trash folder, where its audio and notes are kept.
    /// `allowed` is checked again once earlier imports and saves finish; returns whether it moved.
    @discardableResult
    public func moveToTrash(_ id: UUID, allowed: () -> Bool = { true }) async throws -> Bool {
        await acquireLock()
        defer { releaseLock() }
        await flush()
        guard allowed(), let store else { return false }
        _ = try await store.moveToTrash(id)
        meetings.removeAll { $0.id == id }
        // A save queued during the move, or one that failed before it, has nothing left to save.
        saves.forget(id.uuidString)
        sync?.requestSync()
        return true
    }

    /// Conversations in the Trash folder.
    public func trashedMeetingIDs() -> [UUID] {
        let trash = rootURL.appendingPathComponent("Trash")
        return ((try? FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)) ?? [])
            .compactMap { UUID(uuidString: $0.lastPathComponent) }
    }

    /// Puts a conversation back from the Trash. Once sync has published its deletion, that ID stays deleted
    /// everywhere (the next pass would move it back), so it comes back as a new conversation with the same
    /// content and a Version History entry; the result says which.
    @discardableResult
    public func restoreFromTrash(_ id: UUID) async throws -> Meeting {
        await acquireLock()
        defer { releaseLock() }
        guard let store else { throw DaybookError.libraryUnavailable }
        if let sync, sync.isSyncedDeletion(id) {
            let restored = try await restoreAsNewConversation(id, store: store)
            meetings.append(restored)
            sync.requestSync()
            return restored
        }
        let meeting = try await store.restoreFromTrash(id)
        if self.meeting(id) == nil { meetings.append(meeting) }
        return meeting
    }

    /// The trashed conversation's files, cloned into a new conversation's folder, and its last saved copy as
    /// that conversation. The Trash copy is removed once the new one is saved.
    private func restoreAsNewConversation(_ id: UUID, store: MeetingStore) async throws -> Meeting {
        let trashed = rootURL.appendingPathComponent("Trash/\(id.uuidString)", isDirectory: true)
        let newID = UUID()
        let folder = rootURL.appendingPathComponent("Meetings/\(newID.uuidString)", isDirectory: true)
        let restored = try await Task.detached(priority: .userInitiated) { () throws -> Meeting in
            let decoder = JSONDecoder()
            let saved = [trashed.appendingPathComponent("meeting.json"), trashed.appendingPathComponent("meeting.recovery.json")]
                .lazy.compactMap { try? decoder.decode(Meeting.self, from: Data(contentsOf: $0)) }.first { $0.id == id }
            guard let saved else { throw LibraryError.corruptMeeting(id) }
            try MeetingFolderCopy.copyFiles(from: trashed, to: folder)
            return saved.keptAs(newID, field: "source:restored", title: "Restored from the Trash")
        }.value
        do { try await store.save(restored) }
        catch { try? FileManager.default.removeItem(at: folder); throw error }
        try? FileManager.default.removeItem(at: trashed)
        return restored
    }

    // MARK: Bringing in recordings

    /// Serializes changes to the store that span awaits: imports, sync, and the Trash. Every
    /// `acquireLock()` needs a `releaseLock()`. Waits even if the task is cancelled meanwhile; see
    /// `acquireLockUnlessCancelled()`.
    public func acquireLock() async {
        _ = await waitForLock(cancellable: false)
    }

    /// The same, but a task cancelled while it waits stops waiting and throws `CancellationError`,
    /// without the lock: only a call that returns needs its `releaseLock()`.
    public func acquireLockUnlessCancelled() async throws {
        guard await waitForLock(cancellable: true) else { throw CancellationError() }
    }

    public func releaseLock() {
        if lockWaiters.isEmpty { locked = false } else { lockWaiters.removeFirst().waiting.resume(returning: true) }
    }

    /// How many callers are waiting for the lock now (diagnostics and tests).
    public var lockWaiterCount: Int { lockWaiters.count }

    /// True once this task holds the lock; false when it stopped waiting because it was cancelled. A
    /// cancellation that arrives after the lock was handed over leaves it held: the caller releases it.
    private func waitForLock(cancellable: Bool) async -> Bool {
        if cancellable && Task.isCancelled { return false }
        if !locked { locked = true; return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (waiting: CheckedContinuation<Bool, Never>) in
                lockWaiters.append((id, waiting))
            }
        } onCancel: {
            guard cancellable else { return }
            Task { @MainActor [weak self] in self?.stopWaiting(id) }
        }
    }

    private func stopWaiting(_ id: UUID) {
        guard let index = lockWaiters.firstIndex(where: { $0.id == id }) else { return }
        lockWaiters.remove(at: index).waiting.resume(returning: false)
    }

    /// Copies a recording into a conversation, with where it came from. The original file is
    /// never moved or changed; identical bytes already in the conversation become the same track.
    /// Callers hold the lock (`acquireLock()`).
    public func ingest(_ url: URL, into id: UUID, provenance: RecordingProvenance) async throws -> IngestedRecording {
        guard let store else { throw DaybookError.libraryUnavailable }
        try await flushDurably([id])
        guard let meeting = meeting(id) else { throw DaybookError.libraryUnavailable }
        let imported = try await store.importAudio(from: url, into: meeting, source: provenance.source,
                                                   sidecarURL: provenance.sidecarURL, offset: provenance.offset, device: provenance.device)
        var stored = imported.tracks.first { track in !meeting.tracks.contains { $0.id == track.id } && track.fileName == url.lastPathComponent }
        if stored == nil, provenance.capture != nil {
            // Same bytes imported before (recovery after a crash): find the existing track by digest.
            let digest = try await AudioDigest.sha256(contentsOf: url)
            stored = imported.tracks.first { $0.sha256 == digest }
        }
        update(id) { current in
            for track in imported.tracks where !current.tracks.contains(where: { $0.id == track.id }) { current.tracks.append(track) }
            if let capture = provenance.capture {
                // This device recorded it: what the capture measured replaces the track's own.
                if let stored, let index = current.tracks.firstIndex(where: { $0.id == stored.id }) {
                    if let duration = provenance.duration { current.tracks[index].duration = duration }
                    if let startedAt = provenance.startedAt {
                        // `startedAt` is the clock prior multipoint matching uses; `createdAt` follows it.
                        current.tracks[index].createdAt = startedAt
                        current.tracks[index].startedAt = startedAt
                    }
                    current.tracks[index].capture = capture
                    if let derivedFrom = provenance.derivedFrom {
                        current.tracks[index].derivedFrom = derivedFrom
                        current.tracks[index].processing = provenance.processing
                    }
                }
            } else {
                // A file: the same bytes from a recorder teach the library where they came from,
                // and a length read from the file fills in a track that has none.
                for track in imported.tracks where track.device != nil {
                    if let index = current.tracks.firstIndex(where: { $0.id == track.id && $0.device == nil }) { current.tracks[index].device = track.device }
                }
                if let duration = provenance.duration {
                    for index in current.tracks.indices where imported.tracks.contains(where: { $0.id == current.tracks[index].id && $0.fileName == url.lastPathComponent })
                        && current.tracks[index].duration == nil { current.tracks[index].duration = duration }
                }
                // The recorder's measured clock stays with its recording; the first one recorded is kept.
                if let clock = provenance.recorderClock, let device = provenance.device {
                    for index in current.tracks.indices where current.tracks[index].device == device
                        && imported.tracks.contains(where: { $0.id == current.tracks[index].id }) && current.tracks[index].capture?.recorderClock == nil {
                        var capture = current.tracks[index].capture ?? TrackCaptureDetails()
                        capture.recorderClock = clock
                        current.tracks[index].capture = capture
                    }
                }
                for highlight in imported.highlights where !current.highlights.contains(where: { $0.id == highlight.id }) { current.highlights.append(highlight) }
            }
            if let date = provenance.conversationDate { current.date = date }
            if !provenance.joinsConversation {
                current.status = .imported
                current.errorMessage = provenance.message
            }
        }
        return IngestedRecording(meetingID: id, track: stored, imported: imported)
    }

    // MARK: Sync

    /// One sync pass: exchanges changes with the sync folder, applies what arrived (merging
    /// concurrent edits, moving remote deletions to the Trash), and acknowledges it. `protecting`
    /// is a conversation this device is recording, which a remote deletion or status never touches.
    /// Returns what was applied, or nil when nothing was. `scope` `.metadataOnly` exchanges library settings alone
    /// (recorder ownership, handoffs), for a device busy recording.
    public func synchronize(protecting active: UUID? = nil, limits: SyncPassLimits = .unlimited, scope: SyncPassScope = .full) async -> SyncApplied? {
        guard !Task.isCancelled, isLoaded, let sync, sync.folder != nil, !isApplyingSync else { return nil }
        isApplyingSync = true
        editedDuringSync = []; settingsEditedDuringSync = false
        await acquireLock()
        var applied = await applyPass(sync, protecting: active, limits: limits, scope: scope)
        releaseLock(); isApplyingSync = false
        applied?.editedDuringPass = editedDuringSync; applied?.settingsEditedDuringPass = settingsEditedDuringSync
        if !editedDuringSync.isEmpty || settingsEditedDuringSync { sync.requestSync() }
        return applied
    }

    private func applyPass(_ sync: LibrarySyncController, protecting active: UUID?, limits: SyncPassLimits, scope: SyncPassScope) async -> SyncApplied? {
        await flush()
        guard let store else { return nil }
        var applied: SyncApplied?
        do {
            try Task.checkCancellation()
            let snapshot = meetings
            let deleted = Set(trashedMeetingIDs())
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            guard let result = try await sync.synchronize(meetings: snapshot, deletedMeetingIDs: deleted, metadata: encoder.encode(metadata),
                                                          limits: limits, protecting: active.map { [$0] } ?? [], scope: scope) else { return nil }
            // Save edits made while iCloud hydrated files before applying the pass.
            await flush()
            try Task.checkCancellation()
            guard sync.canApply(result) else { return nil }
            var mergeWarnings = result.warnings
            savingSyncResult = true
            defer { savingSyncResult = false }
            for remote in result.meetings where !result.deletedMeetingIDs.contains(remote.id) {
                try Task.checkCancellation()
                var merged = remote
                let local = meetings.first(where: { $0.id == remote.id })
                if let local {
                    let rebased = MeetingMerge.merge(base: snapshot.first { $0.id == remote.id }, local: local, remote: remote)
                    merged = rebased.meeting; mergeWarnings += rebased.warnings
                }
                // A status such as transcribing describes the device doing the work. It's kept as synced: rewriting it
                // here would publish it back and conflict with that device's next status. Views read processing
                // from `ProcessingStatus`, which never shows another device's work as running here.
                if merged != local {
                    if let index = meetings.firstIndex(where: { $0.id == merged.id }) { meetings[index] = merged } else { meetings.append(merged) }
                    persist(merged)
                } else if persistenceErrors[merged.id.uuidString] != nil {
                    // Retry a prior failed save even when the in-memory snapshot is unchanged.
                    persist(merged)
                }
            }
            let metadataBeforeMerge = metadata
            // Each version merges on its own: one this version can't read (a newer format) is left for an update
            // instead of stopping every pass, and settings inside one it can't read travel on unchanged.
            for data in result.metadataVersions {
                guard let remote = try? JSONDecoder().decode(LibraryMetadata.self, from: data), remote.schemaVersion == 1 else {
                    mergeWarnings.append(Self.newerSettingsWarning); continue
                }
                metadata = metadata.merging(remote)
            }
            if metadata.hasUnreadableValues { mergeWarnings.append(Self.newerSettingsWarning) }
            let mergedGlossary = metadata.vocabulary.compactMap(\.value)
            if mergedGlossary != glossary || metadata != metadataBeforeMerge ||
                persistenceErrors["library-settings"] != nil || persistenceErrors["glossary"] != nil {
                glossary = mergedGlossary
                persistGlossary()
            }
            savingSyncResult = false
            applied = SyncApplied(before: snapshot, received: result.meetings.map(\.id), acknowledged: false,
                                  changed: result.changedMeetingIDs.union(result.deletedMeetingIDs), published: result.publishedEvents,
                                  hasMoreWork: result.hasMoreWork, notLocalAudio: result.notLocalAudio)
            if !mergeWarnings.isEmpty { notice = Array(Set(mergeWarnings)).sorted().joined(separator: "\n") }
            // What this pass saved must be durable before it's acknowledged: what it received, changed, or
            // deleted, conversations kept from a deletion (new IDs), and the library settings. An unrelated
            // conversation's failed save doesn't hold the pass back.
            let known = Set(snapshot.map(\.id))
            let passIDs = Set(result.meetings.map(\.id)).union(result.changedMeetingIDs).union(result.deletedMeetingIDs)
                .union(meetings.map(\.id).filter { !known.contains($0) })
            try await flushDurably(passIDs, includingSettings: true)
            try Task.checkCancellation()
            guard sync.canApply(result) else { return applied }
            // Remote deletions go to the Trash once everything this pass returned is saved: a conversation kept from
            // a deletion is on disk before the one it came from moves.
            for id in result.deletedMeetingIDs {
                try Task.checkCancellation()
                guard sync.canApply(result) else { return applied }
                if meetings.contains(where: { $0.id == id }), id != active {
                    _ = try await store.moveToTrash(id)
                    meetings.removeAll { $0.id == id }
                    // A completed local move must be reflected in memory even if the account changed
                    // during the store await. Remaining changes from that receipt are discarded.
                    guard sync.canApply(result) else { return applied }
                }
            }
            try Task.checkCancellation()
            guard sync.canApply(result) else { return applied }
            try await sync.acknowledge(result)
            applied?.acknowledged = true
        } catch { sync.reportFailure(error.localizedDescription) }
        return applied
    }
}

extension LibraryController {
    static let newerSettingsWarning = "Some library settings were saved with a newer version of Daybook. Update Daybook to see them."
}

/// What one sync pass applied.
public struct SyncApplied: Sendable {
    /// The conversations before the pass.
    public var before: [Meeting]
    /// Conversations that arrived or changed.
    public var received: [UUID]
    /// The sync folder recorded that this device has these changes.
    public var acknowledged: Bool
    /// Conversations this pass changed here: arrived, changed elsewhere, or deleted elsewhere.
    public var changed: Set<UUID> = []
    /// Journal entries this device published in the pass (its own edits and recordings).
    public var published = 0
    /// The pass stopped at its `SyncPassLimits`; run another soon.
    public var hasMoreWork = false
    /// On an on-demand replica, tracks whose audio stays in iCloud until it's played, by conversation.
    public var notLocalAudio: [UUID: Set<UUID>] = [:]
    /// Conversations edited here while the pass ran, and whether library settings were: not in this pass.
    /// Another pass has been asked for.
    public var editedDuringPass: Set<UUID> = []
    public var settingsEditedDuringPass = false
    public var hasEditsAfterThisPass: Bool { !editedDuringPass.isEmpty || settingsEditedDuringPass }

    public init(before: [Meeting], received: [UUID], acknowledged: Bool, changed: Set<UUID> = [], published: Int = 0,
                hasMoreWork: Bool = false, notLocalAudio: [UUID: Set<UUID>] = [:]) {
        self.before = before; self.received = received; self.acknowledged = acknowledged; self.changed = changed
        self.published = published; self.hasMoreWork = hasMoreWork; self.notLocalAudio = notLocalAudio
    }

    /// Conversations that received recordings without a transcript.
    public func newAudio(in meetings: [Meeting]) -> [UUID] {
        received.filter { id in
            let previousTrackIDs = Set(before.first(where: { $0.id == id })?.tracks.map(\.id) ?? [])
            guard let meeting = meetings.first(where: { $0.id == id }) else { return false }
            return meeting.transcribableTracks.contains { track in
                !previousTrackIDs.contains(track.id) && !meeting.transcripts.contains(where: { $0.trackID == track.id })
            }
        }
    }
}

/// Where a recording came from, kept on its track.
public struct RecordingProvenance: Sendable {
    public var source: AudioSource
    /// A recorder's identity, so its recording joins the same conversation on every device.
    public var device: DeviceRecordingIdentity?
    /// Bookmarks exported beside the file (`<name>.highlights.json`).
    public var sidecarURL: URL?
    /// Where the recording starts on the conversation's timeline, when known.
    public var offset: TimeInterval?
    /// How long it is: measured by a capture, or read from a file.
    public var duration: TimeInterval?
    /// When this device started capturing it.
    public var startedAt: Date?
    /// This device recorded it: the capture's devices, formats, and clock. Nil for a file.
    public var capture: TrackCaptureDetails?
    /// A recorder's file (`device`): the recorder's clock as measured, and whether it dated the
    /// recording (`DeviceRecordingStart.clock(of:)`). Kept in the track's capture details.
    public var recorderClock: CaptureRecorderClock?
    /// The original a derived recording was made from (the microphone before echo removal), and how.
    public var derivedFrom: UUID?
    public var processing: String?
    /// Moves the conversation's date, for a capture.
    public var conversationDate: Date?
    /// Shown on the conversation (capture warnings); nil clears an earlier message.
    public var message: String?
    /// The recording joins a conversation another device leads (multipoint): the conversation's
    /// status and message are that device's, so they're left as they are.
    public var joinsConversation = false

    public init(source: AudioSource, device: DeviceRecordingIdentity? = nil, sidecarURL: URL? = nil, offset: TimeInterval? = nil,
                duration: TimeInterval? = nil, startedAt: Date? = nil, capture: TrackCaptureDetails? = nil,
                derivedFrom: UUID? = nil, processing: String? = nil, conversationDate: Date? = nil, message: String? = nil,
                recorderClock: CaptureRecorderClock? = nil) {
        self.source = source; self.device = device; self.sidecarURL = sidecarURL; self.offset = offset
        self.duration = duration; self.startedAt = startedAt; self.capture = capture
        self.derivedFrom = derivedFrom; self.processing = processing; self.conversationDate = conversationDate; self.message = message
        self.recorderClock = recorderClock
    }

    /// A file imported by hand or from a recorder.
    public static func file(source: AudioSource, device: DeviceRecordingIdentity? = nil, sidecarURL: URL? = nil,
                            duration: TimeInterval? = nil, recorderClock: CaptureRecorderClock? = nil) -> Self {
        Self(source: source, device: device, sidecarURL: sidecarURL, duration: duration, recorderClock: recorderClock)
    }
}

/// A recording now in a conversation.
public struct IngestedRecording: Sendable {
    public var meetingID: UUID
    /// The track holding these bytes, when it could be identified.
    public var track: RecordingTrack?
    /// The conversation as the store saved it.
    public var imported: Meeting
}
