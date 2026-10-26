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
    private var persistence: Task<Void, Never>?
    private var persistenceErrors: [String: String] = [:]
    private var notesTasks: [UUID: Task<Void, Never>] = [:]
    private var noteOriginals: [UUID: String] = [:]
    private var locked = false
    private var lockWaiters: [CheckedContinuation<Void, Never>] = []

    public init(rootURL: URL, sync: LibrarySyncController?) {
        self.rootURL = rootURL
        self.sync = sync
    }

    // MARK: Loading

    /// Opens the store and loads the conversations, vocabulary, and library settings. Work that was
    /// running when the app last quit is marked interrupted; nothing is lost.
    public func load() async throws {
        guard !isLoaded else { return }
        let store = try MeetingStore(rootURL: rootURL)
        let glossaryStore = try GlossaryStore(rootURL: rootURL)
        self.store = store; self.glossaryStore = glossaryStore
        meetings = try await store.list()
        glossary = try await glossaryStore.list()
        if let data = try? Data(contentsOf: rootURL.appendingPathComponent("library.json")) {
            metadata = try JSONDecoder().decode(LibraryMetadata.self, from: data)
            guard metadata.schemaVersion == 1 else { throw DaybookError.libraryUnavailable }
            if !metadata.vocabulary.isEmpty { glossary = metadata.vocabulary.compactMap(\.value) }
        } else {
            metadata.vocabulary = glossary.map { .init(id: $0.id.uuidString, value: $0) }
        }
        for index in meetings.indices where [.transcribing, .summarizing, .recording].contains(meetings[index].status) {
            meetings[index].status = .imported
            meetings[index].errorMessage = "Processing was interrupted. Your audio and notes are saved."
            try await store.save(meetings[index])
        }
        let warnings = await store.warnings
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

    /// The conversation that already holds these exact bytes, if any.
    public func existingMeeting(containingAudioAt url: URL) async throws -> Meeting? {
        guard let store else { throw DaybookError.libraryUnavailable }
        return try await store.existingMeeting(containingAudioAt: url)
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

    /// Saves are ordered: each waits for the one before, so the last edit is the one on disk.
    private func persist(_ meeting: Meeting) {
        guard let store else { return }
        if !isApplyingSync { sync?.requestSync() }
        let prior = persistence
        persistence = Task { [weak self] in
            await prior?.value
            do { try await store.save(meeting); self?.persistenceErrors.removeValue(forKey: meeting.id.uuidString) }
            catch { self?.persistenceErrors[meeting.id.uuidString] = error.localizedDescription; self?.errorMessage = "Couldn’t save \(meeting.title): \(error.localizedDescription)" }
        }
    }

    private func persistMetadata() {
        if !isApplyingSync { sync?.requestSync() }
        let snapshot = metadata, url = rootURL.appendingPathComponent("library.json"), prior = persistence
        persistence = Task { [weak self] in
            await prior?.value
            do {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(snapshot).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                self?.persistenceErrors.removeValue(forKey: "library-settings")
            } catch { self?.persistenceErrors["library-settings"] = error.localizedDescription; self?.errorMessage = "Couldn’t save library settings: \(error.localizedDescription)" }
        }
    }

    /// Finishes note edits in progress and waits for every save.
    public func flush() async {
        for id in Array(noteOriginals.keys) { finishNoteEdit(id) }
        await persistence?.value
    }

    /// A durability barrier for operations that discard recovery data or acknowledge a sync pull.
    /// Waiting for the save queue alone does not mean its writes succeeded.
    public func flushDurably() async throws {
        await flush()
        guard persistenceErrors.isEmpty else {
            throw DaybookError.saveFailed(persistenceErrors.values.sorted().joined(separator: "\n"))
        }
    }

    // MARK: Editing a conversation

    /// The notes as typed. The text saves at once; a Version History entry is written once typing
    /// pauses. `captureTime`, while this conversation is being recorded, timestamps new paragraphs.
    public func editNotes(_ id: UUID, text: String, captureTime: TimeInterval? = nil) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        if noteOriginals[id] == nil { noteOriginals[id] = meetings[index].notes }
        let previous = meetings[index].timedNotes ?? NoteTimeline.reconcile(previous: [], text: meetings[index].notes, captureTime: nil)
        meetings[index].timedNotes = NoteTimeline.reconcile(previous: previous, text: text, captureTime: captureTime)
        meetings[index].notes = text
        // Save the current text immediately, while grouping history entries after typing pauses.
        meetings[index].updatedAt = Date(); persist(meetings[index])
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

    /// Fuses a conversation's transcripts again, off the main actor. Skipped if its recordings or
    /// transcripts changed meanwhile.
    public func realign(_ id: UUID) async {
        guard let snapshot = meeting(id) else { return }
        let fusion = await Task.detached(priority: .userInitiated) {
            SourceFusion.fuse(snapshot)
        }.value
        guard let current = meeting(id), current.transcripts == snapshot.transcripts,
              current.tracks == snapshot.tracks, current.audioAlignments == snapshot.audioAlignments else { return }
        update(id) { $0.applyFusion(fusion.fusion); $0.applyPlacements(fusion.settled) }
    }

    // MARK: Folders and templates

    public func saveFolder(_ folder: LibraryFolder) {
        let name = folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        metadata.folders.removeAll { $0.id == folder.id.uuidString }
        metadata.folders.append(.init(id: folder.id.uuidString, value: LibraryFolder(id: folder.id, name: name)))
        persistMetadata()
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
        var value = template; value.updatedAt = Date()
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
        if let index = glossary.firstIndex(where: { $0.id == term.id }) { glossary[index] = term } else { glossary.append(term) }
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
        guard let glossaryStore else { return }
        let snapshot = glossary, prior = persistence
        persistence = Task { [weak self] in
            await prior?.value
            do { try await glossaryStore.save(snapshot); self?.persistenceErrors.removeValue(forKey: "glossary") }
            catch { self?.persistenceErrors["glossary"] = error.localizedDescription; self?.errorMessage = error.localizedDescription }
        }
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
        sync?.requestSync()
        return true
    }

    /// Conversations in the Trash folder.
    public func trashedMeetingIDs() -> [UUID] {
        let trash = rootURL.appendingPathComponent("Trash")
        return ((try? FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)) ?? [])
            .compactMap { UUID(uuidString: $0.lastPathComponent) }
    }

    /// Puts a conversation back from the Trash. Refused while sync is on: the sync journal keeps
    /// deletions final, so the next sync would move it back.
    @discardableResult
    public func restoreFromTrash(_ id: UUID) async throws -> Meeting {
        guard sync?.folder == nil else { throw LibraryControllerError.restoreWhileSyncing }
        await acquireLock()
        defer { releaseLock() }
        guard let store else { throw DaybookError.libraryUnavailable }
        let meeting = try await store.restoreFromTrash(id)
        if self.meeting(id) == nil { meetings.append(meeting) }
        return meeting
    }

    // MARK: Bringing in recordings

    /// Serializes changes to the store that span awaits: imports, sync, and the Trash. Every
    /// `acquireLock()` needs a `releaseLock()`.
    public func acquireLock() async {
        if !locked { locked = true; return }
        await withCheckedContinuation { lockWaiters.append($0) }
    }

    public func releaseLock() {
        if lockWaiters.isEmpty { locked = false } else { lockWaiters.removeFirst().resume() }
    }

    /// Copies a recording into a conversation, with where it came from. The original file is
    /// never moved or changed; identical bytes already in the conversation become the same track.
    /// Callers hold the lock (`acquireLock()`).
    public func ingest(_ url: URL, into id: UUID, provenance: RecordingProvenance) async throws -> IngestedRecording {
        guard let store else { throw DaybookError.libraryUnavailable }
        try await flushDurably()
        guard let meeting = meeting(id) else { throw DaybookError.libraryUnavailable }
        let imported = try await store.importAudio(from: url, into: meeting, source: provenance.source,
                                                   sidecarURL: provenance.sidecarURL, offset: provenance.offset, device: provenance.device)
        var stored = imported.tracks.first { track in !meeting.tracks.contains { $0.id == track.id } && track.fileName == url.lastPathComponent }
        if stored == nil, provenance.capture != nil {
            // Same bytes imported before (recovery after a crash): find the existing track by digest.
            let digest = try await Task.detached { try AudioDigest.sha256(fileURL: url) }.value
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
    /// Returns what was applied, or nil when nothing was.
    public func synchronize(protecting active: UUID? = nil, limits: SyncPassLimits = .unlimited) async -> SyncApplied? {
        guard !Task.isCancelled, isLoaded, let sync, sync.folder != nil, !isApplyingSync else { return nil }
        isApplyingSync = true
        await acquireLock()
        defer { releaseLock(); isApplyingSync = false }
        await flush()
        guard let store else { return nil }
        var applied: SyncApplied?
        do {
            try Task.checkCancellation()
            let snapshot = meetings
            let deleted = Set(trashedMeetingIDs())
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            guard let result = try await sync.synchronize(meetings: snapshot, deletedMeetingIDs: deleted, metadata: encoder.encode(metadata), limits: limits) else { return nil }
            // Save edits made while iCloud hydrated files before applying a remote deletion.
            await flush()
            try Task.checkCancellation()
            guard sync.canApply(result) else { return nil }
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
            var mergeWarnings = result.warnings
            for remote in result.meetings where !result.deletedMeetingIDs.contains(remote.id) {
                try Task.checkCancellation()
                var merged = remote
                let local = meetings.first(where: { $0.id == remote.id })
                if let local {
                    let rebased = MeetingMerge.merge(base: snapshot.first { $0.id == remote.id }, local: local, remote: remote)
                    merged = rebased.meeting; mergeWarnings += rebased.warnings
                }
                // Remote process status describes another device, not a job running here.
                if [.recording, .transcribing, .summarizing].contains(merged.status), merged.id != active { merged.status = merged.summary == nil ? .imported : .ready }
                if merged != local {
                    if let index = meetings.firstIndex(where: { $0.id == merged.id }) { meetings[index] = merged } else { meetings.append(merged) }
                    persist(merged)
                } else if persistenceErrors[merged.id.uuidString] != nil {
                    // Retry a prior failed save even when the in-memory snapshot is unchanged.
                    persist(merged)
                }
            }
            let metadataBeforeMerge = metadata
            for data in result.metadataVersions {
                let remote = try JSONDecoder().decode(LibraryMetadata.self, from: data)
                guard remote.schemaVersion == 1 else { throw DaybookError.libraryUnavailable }
                metadata = metadata.merging(remote)
            }
            let mergedGlossary = metadata.vocabulary.compactMap(\.value)
            if mergedGlossary != glossary || metadata != metadataBeforeMerge ||
                persistenceErrors["library-settings"] != nil || persistenceErrors["glossary"] != nil {
                glossary = mergedGlossary
                persistGlossary()
            }
            applied = SyncApplied(before: snapshot, received: result.meetings.map(\.id), acknowledged: false,
                                  changed: result.changedMeetingIDs.union(result.deletedMeetingIDs), published: result.publishedEvents,
                                  hasMoreWork: result.hasMoreWork, notLocalAudio: result.notLocalAudio)
            if !mergeWarnings.isEmpty { notice = Array(Set(mergeWarnings)).sorted().joined(separator: "\n") }
            try await flushDurably()
            try Task.checkCancellation()
            guard sync.canApply(result) else { return applied }
            try await sync.acknowledge(result)
            applied?.acknowledged = true
        } catch { sync.reportFailure(error.localizedDescription) }
        return applied
    }
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
                derivedFrom: UUID? = nil, processing: String? = nil, conversationDate: Date? = nil, message: String? = nil) {
        self.source = source; self.device = device; self.sidecarURL = sidecarURL; self.offset = offset
        self.duration = duration; self.startedAt = startedAt; self.capture = capture
        self.derivedFrom = derivedFrom; self.processing = processing; self.conversationDate = conversationDate; self.message = message
    }

    /// A file imported by hand or from a recorder.
    public static func file(source: AudioSource, device: DeviceRecordingIdentity? = nil, sidecarURL: URL? = nil,
                            duration: TimeInterval? = nil) -> Self {
        Self(source: source, device: device, sidecarURL: sidecarURL, duration: duration)
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

public enum LibraryControllerError: LocalizedError {
    case restoreWhileSyncing
    public var errorDescription: String? {
        switch self {
        case .restoreWhileSyncing: return "Turn off sync to restore a conversation from the Trash."
        }
    }
}
