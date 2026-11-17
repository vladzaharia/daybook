import DaybookCore
import Foundation

/// Merge… (several conversations selected, on both apps): they become one, the earliest, which is then transcribed again
/// in full as one (docs/architecture.md, "Merging conversations"). DaybookCore's `ConversationMerge` decides where each
/// one's timeline goes and folds it in; this copies their recordings and photos into the survivor's folder, saves it,
/// moves the others to the Trash (a deletion that syncs), and asks for the work where the app does it (`process`).
///
/// Nothing changes for the person until every file is here (on the iPhone a recording may download first). Each copy's
/// file goes into the survivor's folder under the ID every device gives it (`ConversationMerge.copyID`,
/// `MeetingStore.mergeCopy`), but its track joins the survivor only in the change that folds its conversation in, so no
/// copy ever waits in a conversation, here or on another device: one that stops partway leaves files and nothing else,
/// and another device's completed merge of the same conversations is the only copy there is. Asked for again, the files
/// already there are used, a conversation already folded in (its Version History entry, `ConversationMerge.hasFolded`)
/// only goes to the Trash, and each folded conversation's recordings are marked moved to the survivor before it does, so
/// the library holds each recording once either way. A recording of the survivor's own that moved out to a conversation
/// being folded in (Move to New Conversation) is put back by the fold.
extension LibraryController {
    /// Merges the conversations `ids` into the earliest by date and returns its ID. `audio` and `photo` find a folded
    /// conversation's files (on the iPhone they may download); `context` is what the app knows of each conversation, and
    /// one that's busy (`ConversationActions.Context.mergeBusy`) stops the merge. `startOf` says when a recording started
    /// by the wall clock and `policy` how much recordings made at once share of it (`ConversationMerge.placements`).
    @discardableResult
    public func mergeConversations(_ ids: [UUID], audio: (RecordingTrack, UUID) async throws -> URL,
                                   photo: (MeetingPhoto, UUID) async throws -> URL,
                                   context: (Meeting) -> ConversationActions.Context,
                                   policy: SourceMatcher.Policy = .init(), startOf: (RecordingTrack) -> Date? = { $0.startedAt },
                                   at now: Date = Date(),
                                   process: (@MainActor (UUID, ProcessingRequest.Mode) -> Void)? = nil) async throws -> UUID {
        let wanted = Array(Set(ids))
        // Another merge of any of them is running: it isn't asked twice.
        if let running = ConversationMerge.ordered(wanted.compactMap(meeting)).first(where: { mergingIDs.contains($0.id) }) { throw ConversationMergeError.busy(running.title) }
        mergingIDs.formUnion(wanted)
        defer { mergingIDs.subtract(wanted) }
        func current() throws -> [Meeting] {
            let selected = ConversationMerge.ordered(wanted.compactMap(meeting))
            guard selected.count > 1 else { throw ConversationMergeError.tooFew }
            for meeting in selected where meeting.status == .recording || context(meeting).mergeBusy != nil {
                throw ConversationMergeError.busy(meeting.title)
            }
            return selected
        }
        let selected = try current()
        let survivorID = selected[0].id
        let folding = selected.dropFirst().filter { !ConversationMerge.hasFolded($0.id, into: selected[0]) }

        // Every file first: nothing changes until they're all here.
        var recordings: [(meetingID: UUID, track: RecordingTrack, url: URL)] = []
        var pictures: [(meetingID: UUID, photo: MeetingPhoto, url: URL)] = []
        for folded in folding {
            for track in folded.tracks where !track.isMovedOut { recordings.append((folded.id, track, try await audio(track, folded.id))) }
            for item in folded.photos ?? [] where self.meeting(survivorID)?.photo(item.id) == nil {
                pictures.append((folded.id, item, try await photo(item, folded.id)))
            }
        }
        // Started or asked for elsewhere while the files came: it waits.
        _ = try current()

        // Each copy is the same wherever it's made (`ConversationMerge.copyID`): its file now, its track at the fold. A recording
        // is the survivor's own that moved out to the conversation being folded in, which comes back; the same bytes as one in
        // the survivor already (or in another conversation merged now), which is that one; or a copy.
        var copies: [UUID: [UUID: UUID]] = [:], fresh: [UUID: Set<UUID>] = [:], restored: [UUID: Set<UUID>] = [:]
        var made: [UUID: RecordingTrack] = [:], byBytes: [String: UUID] = [:]
        var stored: [UUID: [UUID: MeetingPhoto]] = [:]
        await acquireLock()
        do {
            guard let store else { throw DaybookError.libraryUnavailable }
            for file in recordings {
                guard let survivor = meeting(survivorID) else { throw DaybookError.libraryUnavailable }
                let digest = file.track.sha256.isEmpty ? try await AudioDigest.sha256(contentsOf: file.url) : file.track.sha256
                if let back = survivor.tracks.first(where: { $0.sha256 == digest && $0.removal?.movedTo == file.meetingID && !$0.isWaitingMergeCopy }) {
                    copies[file.meetingID, default: [:]][file.track.id] = back.id
                    restored[file.meetingID, default: []].insert(back.id)
                    continue
                }
                if let same = survivor.presentTracks.first(where: { $0.sha256 == digest })?.id ?? byBytes[digest] {
                    copies[file.meetingID, default: [:]][file.track.id] = same
                    continue
                }
                let id = ConversationMerge.copyID(of: file.track.id, folded: file.meetingID, into: survivorID)
                made[id] = try await store.mergeCopy(of: file.track, from: file.url, into: survivorID, id: id,
                                                     existing: survivor.tracks.first { $0.id == id })
                copies[file.meetingID, default: [:]][file.track.id] = id
                fresh[file.meetingID, default: []].insert(id)
                byBytes[digest] = id
            }
            for file in pictures {
                stored[file.meetingID, default: [:]][file.photo.id] = try await storedPhoto(file.photo, from: file.url, in: survivorID)
            }
        } catch {
            releaseLock()
            throw error
        }
        releaseLock()

        // One change to the survivor, then each folded conversation's recordings marked as moved there, with no wait
        // between: a sync pass sees all of it or none. Everything it decides is read now, not before the files came.
        let latest = try current()
        guard latest[0].id == survivorID else { throw ConversationMergeError.changed }
        let toFold = latest.dropFirst().filter { !ConversationMerge.hasFolded($0.id, into: latest[0]) }
        for folded in toFold {
            // A recording or photo it gained meanwhile isn't here: it waits for the next try. One it lost (moved elsewhere)
            // isn't carried: its copy stays a file in the survivor's folder.
            let carried = folded.tracks.filter { !$0.isMovedOut }
            guard carried.allSatisfy({ copies[folded.id]?[$0.id] != nil }),
                  (folded.photos ?? []).allSatisfy({ stored[folded.id]?[$0.id] != nil || latest[0].photo($0.id) != nil }) else { throw ConversationMergeError.changed }
        }
        // Where each goes, from the survivor as it is: the recordings coming back are on its timeline, and a copy an earlier
        // Daybook left waiting isn't.
        let comingBack = Set(restored.values.flatMap { $0 })
        var planned = latest[0]
        planned.tracks.removeAll(where: \.isWaitingMergeCopy)
        for index in planned.tracks.indices where comingBack.contains(planned.tracks[index].id) { planned.tracks[index].removal = nil }
        let placements = ConversationMerge.placements([planned] + toFold, policy: policy, startOf: startOf)
        let profiles = metadata.speakerProfileMerges
        let words = Dictionary(uniqueKeysWithValues: comingBack.compactMap { id in
            latest[0].tracks.first { $0.id == id }.map { (id, RecordingWords.inSentence($0, in: latest[0])) }
        })
        // Personal stays Personal: cloud summaries, the lock, and Spotlight follow the placement, so what a Personal
        // conversation said never lands in a Work one.
        let personal = selected.contains { $0.effectivePlacement == .personal }
        // The copies the fold carries join the survivor in the same change.
        let carriedCopies = Set(toFold.flatMap { folded in folded.tracks.filter { !$0.isMovedOut }.compactMap { copies[folded.id]?[$0.id] } })
        update(survivorID) { survivor in
            // A copy an earlier Daybook left waiting, whose conversation is folded in already, is back in it.
            survivor.settleMergeCopies()
            guard !toFold.isEmpty else { return }
            for id in carriedCopies.sorted(by: { $0.uuidString < $1.uuidString }) where !survivor.tracks.contains(where: { $0.id == id }) {
                if let copy = made[id] { survivor.tracks.append(copy) }
            }
            if personal { survivor.placement = .personal }
            for folded in latest.dropFirst() {
                guard let placement = placements[folded.id] else { continue }
                ConversationMerge.fold(folded, into: &survivor, placement: placement, copies: copies[folded.id] ?? [:], fresh: fresh[folded.id] ?? [],
                                       restoring: words.filter { restored[folded.id]?.contains($0.key) == true },
                                       photos: stored[folded.id] ?? [:], profiles: profiles, at: now)
            }
            survivor.status = survivor.summary == nil ? .imported : .ready
            survivor.errorMessage = nil
        }
        for folded in latest.dropFirst() {
            update(folded.id) { meeting in
                for index in meeting.tracks.indices where !meeting.tracks[index].isMovedOut {
                    meeting.tracks[index].removal = RecordingRemoval(removedAt: now, movedTo: survivorID)
                }
            }
        }
        // The survivor is on disk before the others go.
        try await flushDurably(Set(latest.map(\.id)))
        for folded in latest.dropFirst() { _ = try await moveToTrash(folded.id) }
        await realign(survivorID)
        if let process, meeting(survivorID)?.presentTracks.isEmpty == false { process(survivorID, .fullRetranscription) }
        return survivorID
    }

    /// A folded conversation's photo in the survivor's folder, under its own ID: copied, or found there already (a merge
    /// that stopped partway copied it). The same image there under another ID is that one, and this one isn't carried.
    private func storedPhoto(_ photo: MeetingPhoto, from url: URL, in survivorID: UUID) async throws -> MeetingPhoto {
        guard let store, let survivor = meeting(survivorID) else { throw DaybookError.libraryUnavailable }
        let target = try await store.photoURL(for: photo, in: survivorID)
        if FileManager.default.fileExists(atPath: target.path), (try? await AudioDigest.sha256(contentsOf: target)) == photo.sha256 {
            return photo
        }
        return try await store.storePhoto(from: url, in: survivor, id: photo.id, fileName: photo.fileName, capturedAt: photo.capturedAt,
                                          capturedAtSource: photo.capturedAtSource, origin: photo.origin,
                                          pixelSize: photo.pixelWidth.flatMap { width in photo.pixelHeight.map { (width, $0) } })
    }
}

/// Why a merge didn't happen, in Daybook's words.
public enum ConversationMergeError: LocalizedError, Equatable, PlainSentenceError {
    /// Fewer than two of the conversations are in the library.
    case tooFew
    /// It's being recorded or processed somewhere, or waits for a recording.
    case busy(String)
    /// One of them gained a recording while the files were fetched.
    case changed

    public var errorDescription: String? {
        switch self {
        case .tooFew: return "Choose two or more conversations to merge."
        case .busy(let title):
            let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "A conversation is busy. Try again when it’s done." : "“\(name)” is busy. Try again when it’s done."
        case .changed: return "A conversation changed while merging. Try again."
        }
    }
}
