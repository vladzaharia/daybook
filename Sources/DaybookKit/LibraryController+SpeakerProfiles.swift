import Combine
import DaybookCore
import Foundation

/// Speaker profiles (DaybookCore's SpeakerProfiles.swift): people known by voice across the library.
/// Profiles and voiceprints are library settings and sync with them; which speaker is which profile
/// is kept in each conversation.
extension LibraryController {
    /// Profiles, by name.
    public var speakerProfiles: [SpeakerProfile] { metadata.activeSpeakerProfiles }

    /// Brings profiles and conversations into step over the whole library (`SpeakerProfileReconciler`):
    /// names the person gave teach profiles, profiles label and suggest speakers in every conversation,
    /// and confident labels teach profiles. Worked out off the main actor from a snapshot; a speaker,
    /// profile, or voiceprint changed meanwhile keeps that change. Conversations in `skipping` (one
    /// being recorded or processed) are left alone. Returns whether anything changed.
    @discardableResult
    public func reconcileSpeakerProfiles(options: SpeakerProfileOptions, skipping: Set<UUID> = [], now: Date = Date()) async -> Bool {
        guard isLoaded, !isApplyingSync else { return false }
        let snapshot = meetings, base = SpeakerProfileState(metadata)
        let result = await detachedWork(priority: .utility) {
            SpeakerProfileReconciler.reconcile(meetings: snapshot, state: base, options: options, skipping: skipping, now: now)
        }
        guard !result.isEmpty, isLoaded, !isApplyingSync else { return false }
        if !result.profiles.isEmpty || !result.voiceprints.isEmpty { updateMetadata { $0.apply(result, base: base) } }
        for id in result.meetingIDs.sorted(by: { $0.uuidString < $1.uuidString }) { update(id) { $0.apply(result.speakers) } }
        return true
    }

    // MARK: A conversation's speakers

    /// The person agrees with Daybook's label or suggestion: the speaker is theirs from now on (named
    /// like the profile) and teaches the profile.
    public func confirmSpeakerProfile(_ speakerID: String, in id: UUID) {
        guard let meeting = meeting(id), let identity = meeting.speakerIdentity(speakerID), identity.$source.isKnown,
              identity.source == .recognized || identity.source == .suggested,
              let profileID = identity.profileID, let profile = metadata.speakerProfile(profileID) else { return }
        update(id) { meeting in
            if meeting.speakerName(speakerID) != profile.name { meeting.renameSpeaker(id: speakerID, name: profile.name) }
            let basis = meeting.revisions.filter { $0.field == "speaker:\(speakerID)" }
                .max { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date }?.id
            meeting.setSpeakerIdentity(SpeakerIdentity(speakerID: speakerID, profileID: profileID, source: .confirmed, basis: basis,
                                                       rejectedProfileIDs: identity.rejectedProfileIDs), for: speakerID)
        }
    }

    /// The person says the speaker isn't the profile Daybook labelled or suggested: a label comes off
    /// (the speaker gets back the name it had), the profile isn't offered for this speaker again, and
    /// it forgets what it learned from it.
    public func rejectSpeakerProfile(_ speakerID: String, in id: UUID) {
        guard let meeting = meeting(id), let identity = meeting.speakerIdentity(speakerID), identity.$source.isKnown,
              identity.source == .recognized || identity.source == .suggested, let profileID = identity.profileID else { return }
        update(id) { meeting in
            if identity.source == .recognized, let previous = identity.previousName, meeting.speakerName(speakerID) == identity.appliedName,
               let index = meeting.speakers.firstIndex(where: { $0.id == speakerID }) {
                meeting.speakers[index].name = previous
            }
            let rejected = Array(Set((identity.rejectedProfileIDs ?? []) + [profileID])).sorted { $0.uuidString < $1.uuidString }
            meeting.setSpeakerIdentity(SpeakerIdentity(speakerID: speakerID, profileID: nil, source: .dismissed, basis: identity.basis,
                                                       rejectedProfileIDs: rejected), for: speakerID)
        }
        let sources = Set(meeting.voiceSourceIDs(of: speakerID))
        updateMetadata { metadata in
            Self.retireVoiceprints(in: &metadata) { $0.profileID == profileID && $0.meetingID == id && sources.contains($0.speakerID) }
        }
    }

    // MARK: Profiles

    /// Renames a profile; speakers Daybook labelled with it follow. A name another profile has is refused.
    @discardableResult
    public func renameSpeakerProfile(_ profileID: UUID, to name: String, at now: Date = Date()) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !SpeakerProfile.isPlaceholder(trimmed), var profile = metadata.speakerProfile(profileID) else { return false }
        guard profile.name != trimmed else { return true }
        let key = SpeakerProfile.normalizedName(trimmed)
        guard !speakerProfiles.contains(where: { $0.id != profileID && SpeakerProfile.normalizedName($0.name) == key }) else { return false }
        profile.name = trimmed
        updateMetadata { metadata in
            var profiles = metadata.speakerProfiles ?? []
            profiles.removeAll { $0.id == profileID.uuidString }
            profiles.append(LibraryValue(id: profileID.uuidString, value: profile, modifiedAt: now))
            metadata.speakerProfiles = profiles.sorted { $0.id < $1.id }
        }
        return true
    }

    /// Deletes a profile and its voiceprints. Speakers Daybook labelled with it lose the label; names
    /// the person gave stay.
    public func deleteSpeakerProfile(_ profileID: UUID, at now: Date = Date()) {
        guard metadata.speakerProfile(profileID) != nil else { return }
        updateMetadata { metadata in
            var profiles = metadata.speakerProfiles ?? []
            profiles.removeAll { $0.id == profileID.uuidString }
            profiles.append(LibraryValue(id: profileID.uuidString, value: nil, modifiedAt: now))
            metadata.speakerProfiles = profiles.sorted { $0.id < $1.id }
            Self.retireVoiceprints(in: &metadata, at: now) { $0.profileID == profileID }
        }
    }

    /// Takes one voiceprint out of its profile; it isn't learned again.
    public func removeVoiceprint(_ voiceprintID: String, at now: Date = Date()) {
        updateMetadata { Self.retireVoiceprints(in: &$0, at: now) { $0.id == voiceprintID } }
    }

    /// Undoes what a profile learned on its own: every recognized voiceprint goes, leaving the ones from
    /// names the person gave or confirmed.
    public func forgetLearnedVoiceprints(of profileID: UUID, at now: Date = Date()) {
        updateMetadata { Self.retireVoiceprints(in: &$0, at: now) { $0.profileID == profileID && !$0.origin.isPersonChosen } }
    }

    /// Conversations and speakers a profile is given to, newest first.
    public func speakers(of profileID: UUID) -> [(meeting: Meeting, speaker: Speaker, identity: SpeakerIdentity)] {
        meetings.sorted { $0.date > $1.date }.flatMap { meeting in
            meeting.speakers.compactMap { speaker in
                guard let identity = meeting.speakerIdentity(speaker.id), identity.profileID == profileID,
                      identity.source != .suggested, identity.source != .dismissed else { return nil }
                return (meeting, speaker, identity)
            }
        }
    }

    private static func retireVoiceprints(in metadata: inout LibraryMetadata, at now: Date = Date(), where matches: (Voiceprint) -> Bool) {
        guard var prints = metadata.voiceprints else { return }
        for index in prints.indices {
            guard let print = prints[index].value, matches(print) else { continue }
            prints[index] = LibraryValue(id: print.id, value: nil, modifiedAt: now)
        }
        metadata.voiceprints = prints
    }
}

/// Keeps speaker profiles in step with the library as it changes: a name given on any device, a
/// conversation processed or synced, a profile renamed or a voiceprint removed. Changes are gathered
/// for `delay`, and a reconciliation runs only when what it reads changed. The Mac owns one.
@MainActor
public final class SpeakerProfileCoordinator {
    private let library: LibraryController
    private let options: () -> SpeakerProfileOptions
    private let skipping: () -> Set<UUID>
    private var observation: AnyCancellable?
    private var scheduled: Task<Void, Never>?
    private var running = false
    private var again = false
    private var reconciled: Int?
    public var delay: Duration = .seconds(2)

    public init(library: LibraryController, options: @escaping () -> SpeakerProfileOptions, skipping: @escaping () -> Set<UUID> = { [] }) {
        self.library = library; self.options = options; self.skipping = skipping
    }

    /// Watches the library from now on, and reconciles once soon.
    public func start() {
        guard observation == nil else { return }
        observation = library.objectWillChange.sink { [weak self] _ in self?.schedule() }
        schedule()
    }

    public func stop() {
        observation = nil
        scheduled?.cancel(); scheduled = nil
    }

    /// Reconciles after `delay`, once for any number of changes meanwhile.
    public func schedule() {
        scheduled?.cancel()
        scheduled = Task { [weak self, delay] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.refresh()
        }
    }

    /// Reconciles now if anything it reads changed since the last time. Returns whether it changed something.
    @discardableResult
    public func refresh() async -> Bool {
        guard !running else { again = true; return false }
        guard library.isLoaded else { return false }
        if library.isApplyingSync { schedule(); return false }
        running = true
        defer { running = false }
        var changedAny = false
        // A pass's own learning can make more speakers recognizable; a few rounds settle it.
        for _ in 0..<3 {
            let options = options(), skipping = skipping()
            let inputs = Self.inputs(library, options: options, skipping: skipping)
            guard inputs != reconciled else { break }
            let changed = await library.reconcileSpeakerProfiles(options: options, skipping: skipping)
            changedAny = changedAny || changed
            if !changed { reconciled = inputs; break }
        }
        if again { again = false; schedule() }
        return changedAny
    }

    /// What a reconciliation reads, hashed: speakers, their names, embeddings and identities, renames,
    /// transcripts, speaker mappings, profiles and voiceprints, and the options.
    static func inputs(_ library: LibraryController, options: SpeakerProfileOptions, skipping: Set<UUID>) -> Int {
        var hasher = Hasher()
        hasher.combine(options.recognizes)
        hasher.combine(options.matching.labelSimilarity); hasher.combine(options.matching.margin)
        hasher.combine(options.matching.suggestionSimilarity); hasher.combine(options.matching.minimumLabelSeconds)
        hasher.combine(skipping)
        for meeting in library.meetings where !skipping.contains(meeting.id) {
            hasher.combine(meeting.id); hasher.combine(meeting.date)
            for speaker in meeting.speakers {
                hasher.combine(speaker.id); hasher.combine(speaker.name); hasher.combine(speaker.sourceTrackID)
                hasher.combine(speaker.embeddingModelID); hasher.combine(speaker.embedding)
            }
            for identity in meeting.speakerIdentities ?? [] { hasher.combine(SyncValueText.of(identity)) }
            for revision in meeting.revisions where revision.field.hasPrefix("speaker:") { hasher.combine(revision.id) }
            for run in meeting.transcripts { hasher.combine(run.id); hasher.combine(run.segments.count) }
            for match in meeting.speakerMatches ?? [] { hasher.combine(match.sourceSpeakerID); hasher.combine(match.targetSpeakerID) }
            for mapping in meeting.fusionSummary?.speakerMappings ?? [] { hasher.combine(mapping.sourceSpeakerID); hasher.combine(mapping.speakerID) }
            hasher.combine(meeting.fusionSummary?.ownerSpeakerID)
        }
        for item in library.metadata.speakerProfiles ?? [] { hasher.combine(item.id); hasher.combine(item.modifiedAt); hasher.combine(item.value?.name) }
        for item in library.metadata.voiceprints ?? [] { hasher.combine(item.id); hasher.combine(item.modifiedAt) }
        return hasher.finalize()
    }
}

/// A value's JSON, for hashing values that aren't `Hashable`.
enum SyncValueText {
    static func of<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}
