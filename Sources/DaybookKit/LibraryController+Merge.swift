import DaybookCore
import Foundation

/// Merge… (several conversations selected, on both apps): they become one, the earliest, which is then transcribed again
/// in full as one (docs/architecture.md, "Merging conversations"). DaybookCore's `ConversationMerge` decides where each
/// one's timeline goes and folds it in; this copies their recordings and photos into the survivor's folder, saves it,
/// moves the others to the Trash (a deletion that syncs), and asks for the work where the app does it (`process`).
///
/// Nothing changes until every file is here (on the iPhone a recording may download first). One that stops partway can
/// be asked for again: the copies already made are found by their bytes, a conversation already folded in (its Version
/// History entry, `ConversationMerge.hasFolded`) only goes to the Trash, and each folded conversation's recordings are
/// marked moved to the survivor before it does, so the library holds each recording once either way.
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
        func current() throws -> [Meeting] {
            let selected = ConversationMerge.ordered(wanted.compactMap(meeting))
            guard selected.count > 1 else { throw ConversationMergeError.tooFew }
            for meeting in selected { if context(meeting).mergeBusy != nil { throw ConversationMergeError.busy(meeting.title) } }
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

        var copies: [UUID: [UUID: UUID]] = [:], fresh: [UUID: Set<UUID>] = [:], stored: [UUID: [UUID: MeetingPhoto]] = [:]
        await acquireLock()
        do {
            for file in recordings {
                let before = Set(meeting(survivorID)?.tracks.map(\.id) ?? [])
                let ingested = try await ingest(file.url, into: survivorID, provenance: .file(source: file.track.source, device: file.track.device,
                                                                                               duration: file.track.duration))
                // The same bytes were here already (in both conversations, or copied by a merge that stopped partway).
                let digest = file.track.sha256.isEmpty ? try await AudioDigest.sha256(contentsOf: file.url) : file.track.sha256
                guard let copy = ingested.track ?? meeting(survivorID)?.tracks.first(where: { $0.sha256 == digest && !$0.isMovedOut }) else {
                    throw DaybookError.libraryUnavailable
                }
                copies[file.meetingID, default: [:]][file.track.id] = copy.id
                if !before.contains(copy.id) {
                    // Until it's folded in, a copy stays out of the survivor's transcript and processing, as a removed
                    // recording does, so one left by a merge that stopped partway changes nothing there.
                    update(survivorID) { survivor in
                        guard let index = survivor.tracks.firstIndex(where: { $0.id == copy.id }) else { return }
                        survivor.tracks[index].mergedFrom = file.meetingID
                        survivor.tracks[index].removal = RecordingRemoval(removedAt: now)
                    }
                }
                if meeting(survivorID)?.tracks.first(where: { $0.id == copy.id })?.mergedFrom == file.meetingID {
                    fresh[file.meetingID, default: []].insert(copy.id)
                }
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
        // between: a sync pass sees all of it or none.
        let latest = try current()
        let toFold = latest.dropFirst().filter { !ConversationMerge.hasFolded($0.id, into: latest[0]) }
        for folded in toFold {
            let carried = folded.tracks.filter { !$0.isMovedOut }
            guard carried.allSatisfy({ copies[folded.id]?[$0.id] != nil }) else { throw ConversationMergeError.changed }
        }
        // Where each goes, from the survivor as it was: the copies waiting to be folded in aren't on its timeline yet.
        let pending = Set(toFold.map(\.id))
        var planned = latest[0]
        planned.tracks.removeAll { $0.mergedFrom.map(pending.contains) == true }
        let placements = ConversationMerge.placements([planned] + toFold, policy: policy, startOf: startOf)
        let profiles = metadata.speakerProfileMerges
        update(survivorID) { survivor in
            for folded in latest.dropFirst() {
                guard let placement = placements[folded.id] else { continue }
                ConversationMerge.fold(folded, into: &survivor, placement: placement, copies: copies[folded.id] ?? [:], fresh: fresh[folded.id] ?? [],
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
