import DaybookCore
import DaybookDevices
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
              let stored = identity.profileID, let profile = metadata.speakerProfile(stored) else { return }
        update(id) { meeting in
            if meeting.speakerName(speakerID) != profile.name { meeting.renameSpeaker(id: speakerID, name: profile.name) }
            let basis = meeting.revisions.filter { $0.kind == .speaker(speakerID) }
                .max { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date }?.id
            meeting.setSpeakerIdentity(SpeakerIdentity(speakerID: speakerID, profileID: profile.id, source: .confirmed, basis: basis,
                                                       rejectedProfileIDs: identity.rejectedProfileIDs?.filter { $0 != profile.id }), for: speakerID)
        }
    }

    /// The person says the speaker isn't the profile Daybook labelled or suggested: a label comes off
    /// (the speaker gets back the name it had), the profile isn't offered for this speaker again, and
    /// it forgets what it learned from it (but not a voice another speaker the person named that
    /// profile still stands for).
    public func rejectSpeakerProfile(_ speakerID: String, in id: UUID) {
        guard let meeting = meeting(id), let identity = meeting.speakerIdentity(speakerID), identity.$source.isKnown,
              identity.source == .recognized || identity.source == .suggested, let stored = identity.profileID else { return }
        let merges = metadata.speakerProfileMerges
        let profileID = merges.resolve(stored) ?? stored
        update(id) { meeting in
            if identity.source == .recognized, let previous = identity.previousName, meeting.speakerName(speakerID) == identity.appliedName,
               let index = meeting.speakers.firstIndex(where: { $0.id == speakerID }) {
                meeting.speakers[index].name = previous
                meeting.summaryFollowsRename(of: speakerID, from: identity.appliedName ?? "", to: previous)
            }
            let rejected = Array(Set((identity.rejectedProfileIDs ?? []) + [profileID])).sorted { $0.uuidString < $1.uuidString }
            meeting.setSpeakerIdentity(SpeakerIdentity(speakerID: speakerID, profileID: nil, source: .dismissed, basis: identity.basis,
                                                       rejectedProfileIDs: rejected), for: speakerID)
        }
        let sources = Set(meeting.voiceSourceIDs(of: speakerID)).subtracting(meeting.voiceSourceIDs(claimedFor: profileID, besides: speakerID, merges: merges))
        let members = merges.members(of: profileID)
        updateMetadata { metadata in
            Self.retireVoiceprints(in: &metadata) { members.contains($0.profileID) && $0.meetingID == id && sources.contains($0.speakerID) }
        }
    }

    /// What "This Is Me" would do for a person (`speakerIDs`) in a conversation.
    private enum MeMark {
        /// The profile that is me is already offered for the speaker: the person agrees.
        case confirm(speakerID: String)
        /// A me-profile exists: the speakers are named as it, the way the person would by hand.
        case name(profile: SpeakerProfile)
        /// No me-profile yet: the speaker's own profile becomes it (confirmed first when Daybook gave it).
        case adopt(profile: UUID, confirming: String?)
        /// No me-profile yet, and a name the person gave with no profile made yet: its profile, once it exists, becomes it.
        case pending(profile: UUID)
    }

    /// Never changes the library's choice from inside a conversation when one exists; the person can't mark a speaker
    /// who has nothing to go by (a placeholder, or fusion's "Me", with no me-profile yet).
    private func meMark(_ speakerIDs: [String], in id: UUID) -> MeMark? {
        guard let meeting = meeting(id) else { return nil }
        let merges = metadata.speakerProfileMerges
        func profile(of speakerID: String) -> (identity: SpeakerIdentity, id: UUID)? {
            guard let identity = meeting.speakerIdentity(speakerID), identity.$source.isKnown, identity.source != .dismissed,
                  let stored = identity.profileID, let resolved = merges.resolve(stored) else { return nil }
            return (identity, resolved)
        }
        if let ownerID = ownerProfileID, let me = metadata.speakerProfile(ownerID) {
            var held = false
            for speakerID in speakerIDs {
                guard let (identity, resolved) = profile(of: speakerID), resolved == me.id else { continue }
                if identity.source == .recognized || identity.source == .suggested { return .confirm(speakerID: speakerID) }
                held = true
            }
            return held ? nil : .name(profile: me)
        }
        for speakerID in speakerIDs {
            guard let (identity, resolved) = profile(of: speakerID), identity.source != .suggested else { continue }
            return .adopt(profile: resolved, confirming: identity.source == .recognized ? speakerID : nil)
        }
        for speakerID in speakerIDs {
            let name = (meeting.speakerName(speakerID) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !SpeakerProfile.isPlaceholder(name), name != FusionOptions().ownerName,
                  meeting.revisions.contains(where: { $0.kind == .speaker(speakerID) }) else { continue }
            let key = SpeakerProfile.normalizedName(name)
            if let existing = speakerProfiles.first(where: { SpeakerProfile.normalizedName($0.name) == key }) { return .pending(profile: existing.id) }
            let started = SpeakerProfile.id(forName: name)
            // A profile of that name that was deleted is not the person's.
            if metadata.speakerProfiles?.contains(where: { $0.id == started.uuidString }) == true { continue }
            return .pending(profile: started)
        }
        return nil
    }

    /// Whether "This Is Me" does anything for the person (`speakerIDs`): offered only then.
    public func canMarkSpeakerAsMe(_ speakerIDs: [String], in id: UUID) -> Bool { meMark(speakerIDs, in: id) != nil }

    /// The person says this speaker is them. With a me-profile, the speaker is the person's (confirmed when Daybook
    /// offered that profile, else named as it by hand, which also takes it off what the speaker rejected) and the
    /// library's choice stays. Without one, the profile the speaker has (a name, confirmation, or recognition of
    /// the person's) becomes it. Returns whether anything was done (`canMarkSpeakerAsMe`).
    @discardableResult
    public func markSpeakerAsMe(_ speakerIDs: [String], in id: UUID, at now: Date = Date()) -> Bool {
        guard let mark = meMark(speakerIDs, in: id) else { return false }
        switch mark {
        case .confirm(let speakerID):
            confirmSpeakerProfile(speakerID, in: id)
        case .name(let me):
            update(id) { meeting in
                for speakerID in speakerIDs {
                    meeting.renameSpeaker(id: speakerID, name: me.name)
                    guard let identity = meeting.speakerIdentity(speakerID), identity.$source.isKnown,
                          identity.rejectedProfileIDs?.contains(me.id) == true else { continue }
                    let rejected = identity.rejectedProfileIDs?.filter { $0 != me.id }
                    var changed = identity
                    changed.rejectedProfileIDs = rejected?.isEmpty == true ? nil : rejected
                    meeting.setSpeakerIdentity(changed.source == .dismissed && changed.rejectedProfileIDs == nil ? nil : changed, for: speakerID)
                }
            }
        case .adopt(let profile, let confirming):
            if let confirming { confirmSpeakerProfile(confirming, in: id) }
            setOwnerProfile(profile, at: now)
        case .pending(let profile):
            setOwnerProfile(profile, at: now)
        }
        return true
    }

    // MARK: Profiles

    /// Renames a profile; speakers Daybook labelled with it follow. A name another profile has is
    /// refused (`speakerProfile(named:besides:)` finds it, to offer a merge instead).
    @discardableResult
    public func renameSpeakerProfile(_ profileID: UUID, to name: String, at now: Date = Date()) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !SpeakerProfile.isPlaceholder(trimmed), let current = metadata.speakerProfile(profileID),
              let record = metadata.speakerProfiles?.first(where: { $0.id == current.id.uuidString }) else { return false }
        guard current.name != trimmed else { return true }
        guard speakerProfile(named: trimmed, besides: current.id) == nil else { return false }
        var profile = current
        profile.name = trimmed
        updateMetadata { metadata in
            var profiles = metadata.speakerProfiles ?? []
            profiles.removeAll { $0.id == record.id }
            profiles.append(.edit(record.id, value: profile, replacing: record, at: now))
            metadata.speakerProfiles = profiles.sorted { $0.id < $1.id }
        }
        return true
    }

    /// Another profile already called `name` (names compare without case or accents).
    public func speakerProfile(named name: String, besides profileID: UUID) -> SpeakerProfile? {
        let key = SpeakerProfile.normalizedName(name.trimmingCharacters(in: .whitespacesAndNewlines))
        return speakerProfiles.first { $0.id != profileID && SpeakerProfile.normalizedName($0.name) == key }
    }

    /// Merges a profile into another, the same person named two ways (`LibraryMetadata.mergeSpeakerProfile`):
    /// its voiceprints and conversations go to `target`, which keeps its name, and it leaves the list.
    /// Speakers Daybook labelled with it take `target`'s name; names the person gave stay. Returns
    /// whether it merged.
    @discardableResult
    public func mergeSpeakerProfile(_ profileID: UUID, into target: UUID, at now: Date = Date()) -> Bool {
        let merges = metadata.speakerProfileMerges
        guard merges.isActive(profileID), merges.isActive(target), profileID != target else { return false }
        var merged = false
        updateMetadata { merged = $0.mergeSpeakerProfile(profileID, into: target, at: now) }
        return merged
    }

    /// Deletes a profile and its voiceprints (those of profiles merged into it too). Speakers Daybook
    /// labelled with it lose the label; names the person gave stay.
    public func deleteSpeakerProfile(_ profileID: UUID, at now: Date = Date()) {
        guard let profile = metadata.speakerProfile(profileID) else { return }
        let members = metadata.speakerProfileMerges.members(of: profile.id)
        let wasMe = metadata.ownerProfileID == profile.id
        updateMetadata { metadata in
            var profiles = metadata.speakerProfiles ?? []
            let stored = profiles.first { $0.id == profile.id.uuidString }
            profiles.removeAll { $0.id == profile.id.uuidString }
            profiles.append(.edit(profile.id.uuidString, value: nil, replacing: stored, at: now))
            metadata.speakerProfiles = profiles.sorted { $0.id < $1.id }
            Self.retireVoiceprints(in: &metadata, at: now) { members.contains($0.profileID) }
        }
        if wasMe { setOwnerProfile(nil, at: now) }
    }

    /// Takes one voiceprint out of its profile; it isn't learned again.
    public func removeVoiceprint(_ voiceprintID: String, at now: Date = Date()) {
        updateMetadata { Self.retireVoiceprints(in: &$0, at: now) { $0.id == voiceprintID } }
    }

    /// Undoes what a profile learned on its own: every recognized voiceprint goes, leaving the ones from
    /// names the person gave or confirmed.
    public func forgetLearnedVoiceprints(of profileID: UUID, at now: Date = Date()) {
        let members = metadata.speakerProfileMerges.members(of: profileID)
        updateMetadata { Self.retireVoiceprints(in: &$0, at: now) { members.contains($0.profileID) && !$0.origin.isPersonChosen } }
    }

    /// Conversations and speakers a profile is given to (through profiles merged into it too), newest first: the
    /// speakers in each conversation's transcript (`Meeting.transcriptSpeakers`), not a recording's label that says
    /// nothing there.
    public func speakers(of profileID: UUID) -> [(meeting: Meeting, speaker: Speaker, identity: SpeakerIdentity)] {
        let merges = metadata.speakerProfileMerges
        return meetings.sorted { $0.date > $1.date }.flatMap { meeting in
            meeting.transcriptSpeakers.compactMap { speaker in
                guard let identity = meeting.speakerIdentity(speaker.id), identity.$source.isKnown, let stored = identity.profileID,
                      (merges.resolve(stored) ?? stored) == profileID,
                      identity.source != .suggested, identity.source != .dismissed else { return nil }
                return (meeting, speaker, identity)
            }
        }
    }

    private static func retireVoiceprints(in metadata: inout LibraryMetadata, at now: Date = Date(), where matches: (Voiceprint) -> Bool) {
        guard var prints = metadata.voiceprints else { return }
        for index in prints.indices {
            guard let print = prints[index].value, matches(print) else { continue }
            prints[index] = .edit(print.id, value: nil, replacing: prints[index], at: now)
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
    private var observation: ObservationWatch?
    private var scheduled: Task<Void, Never>?
    private var running = false
    private var again = false
    private var reconciled: Int?
    public var delay: Duration = .seconds(2)
    /// After each look at the library (the Mac gives voices to speakers without them from here).
    public var didRefresh: (() -> Void)?

    public init(library: LibraryController, options: @escaping () -> SpeakerProfileOptions, skipping: @escaping () -> Set<UUID> = { [] }) {
        self.library = library; self.options = options; self.skipping = skipping
    }

    /// Watches the library from now on, and reconciles once soon.
    public func start() {
        guard observation == nil else { return }
        let library = self.library
        observation = ObservationWatch({ _ = library.meetings; _ = library.metadata; _ = library.isLoaded }) { [weak self] in self?.schedule() }
        schedule()
    }

    public func stop() {
        observation?.cancel()
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
        didRefresh?()
        return changedAny
    }

    /// What a reconciliation reads, hashed: speakers, their names, embeddings and identities, renames,
    /// transcripts, passages left out as background audio, speaker mappings, profiles and voiceprints,
    /// and the options.
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
            for revision in meeting.revisions { if case .speaker = revision.kind { hasher.combine(revision.id) } }
            for run in meeting.transcripts { hasher.combine(run.id); hasher.combine(run.segments.count) }
            for passage in meeting.backgroundPassages ?? [] { hasher.combine(passage.id) }
            for match in meeting.speakerMatches ?? [] { hasher.combine(match.sourceSpeakerID); hasher.combine(match.targetSpeakerID) }
            for mapping in meeting.fusionSummary?.speakerMappings ?? [] { hasher.combine(mapping.sourceSpeakerID); hasher.combine(mapping.speakerID) }
            hasher.combine(meeting.fusionSummary?.ownerSpeakerID)
        }
        for item in library.metadata.speakerProfiles ?? [] { hasher.combine(item.id); hasher.combine(item.modifiedAt); hasher.combine(item.value?.name) }
        for item in library.metadata.voiceprints ?? [] { hasher.combine(item.id); hasher.combine(item.modifiedAt) }
        hasher.combine(library.metadata.ownerProfileSelection)
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
