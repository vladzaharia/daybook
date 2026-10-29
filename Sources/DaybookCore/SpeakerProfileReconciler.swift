import Foundation

/// What a reconciliation may do.
public struct SpeakerProfileOptions: Equatable, Sendable {
    public var matching: SpeakerProfileMatching
    public var learning: SpeakerProfileLearning
    /// Label and suggest speakers by voice (Settings › Models › Match voices across recordings). Off,
    /// profiles still learn from the names the person gives, and labels already given stay.
    public var recognizes: Bool

    public init(matching: SpeakerProfileMatching = .init(), learning: SpeakerProfileLearning = .init(), recognizes: Bool = true) {
        self.matching = matching; self.learning = learning; self.recognizes = recognizes
    }
}

/// The library's speaker profiles and voiceprints, as `LibraryMetadata` stores them.
public struct SpeakerProfileState: Equatable, Sendable {
    public var profiles: [LibraryValue<SpeakerProfile>]
    public var voiceprints: [LibraryValue<Voiceprint>]

    public init(profiles: [LibraryValue<SpeakerProfile>] = [], voiceprints: [LibraryValue<Voiceprint>] = []) {
        self.profiles = profiles; self.voiceprints = voiceprints
    }

    public init(_ metadata: LibraryMetadata) {
        self.init(profiles: metadata.speakerProfiles ?? [], voiceprints: metadata.voiceprints ?? [])
    }
}

/// One speaker's new name and identity. Applied only while the speaker still has the name and
/// identity it was decided from, so a rename made meanwhile always wins.
public struct SpeakerIdentityChange: Equatable, Sendable {
    public var meetingID: UUID
    public var speakerID: String
    public var expectedName: String
    public var expectedIdentity: SpeakerIdentity?
    public var name: String
    public var identity: SpeakerIdentity?
}

/// What one reconciliation changed: profile and voiceprint records (deletion markers retire a
/// voiceprint), and speakers to label.
public struct SpeakerProfileReconciliation: Equatable, Sendable {
    public var profiles: [LibraryValue<SpeakerProfile>] = []
    public var voiceprints: [LibraryValue<Voiceprint>] = []
    public var speakers: [SpeakerIdentityChange] = []
    public var isEmpty: Bool { profiles.isEmpty && voiceprints.isEmpty && speakers.isEmpty }
    /// Conversations whose speakers change.
    public var meetingIDs: Set<UUID> { Set(speakers.map(\.meetingID)) }
}

/// Keeps speaker profiles and conversations in step, over the whole library at once:
///
/// 1. **Names teach profiles.** A speaker the person named (Version History holds the rename) joins
///    the profile with that name, created if needed, with its voiceprints. Renaming it again moves it;
///    renaming it to a placeholder ("Speaker 2") takes it out. Speakers named before profiles existed
///    are taught the same way the first time this runs.
/// 2. **Profiles label speakers.** Every other speaker with a voice embedding, in every conversation
///    (so recordings made before a profile existed too), is compared with the profiles: a close, clear
///    match is labelled (its name becomes the profile's), a looser one only suggested. A name the
///    person gave, or one Daybook didn't give, is never replaced. Two voices from one recording are
///    never both labelled the same person.
/// 3. **Confident labels teach profiles.** A recognized speaker with plenty of clean speech, close
///    both to the profile and to the person's own voiceprints, adds a learned voiceprint.
///
/// Pure and deterministic: the same library gives the same result on every device; run again on its
/// own result, it changes nothing more than what its learning makes newly recognizable.
public enum SpeakerProfileReconciler {
    public static func reconcile(meetings: [Meeting], state: SpeakerProfileState, options: SpeakerProfileOptions = .init(),
                                 skipping: Set<UUID> = [], now: Date = Date()) -> SpeakerProfileReconciliation {
        var work = Work(state: state, learning: options.learning, now: now)
        let ordered = meetings.filter { !skipping.contains($0.id) }
            .sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date > $1.date }
        var voices: [UUID: MeetingVoices] = [:]
        var current: [UUID: [String: (name: String, identity: SpeakerIdentity?)]] = [:]
        for meeting in ordered {
            voices[meeting.id] = MeetingVoices(meeting)
            current[meeting.id] = Dictionary(meeting.speakers.map { ($0.id, ($0.name, meeting.speakerIdentity($0.id))) }, uniquingKeysWith: { a, _ in a })
        }

        // 1. Names the person gave.
        for meeting in ordered {
            let voice = voices[meeting.id]!
            for speaker in meeting.speakers.sorted(by: { $0.id < $1.id }) {
                guard var entry = current[meeting.id]?[speaker.id] else { continue }
                if let identity = entry.identity, !identity.$source.isKnown { continue }
                let prints = voice.prints(of: speaker.id)
                let latest = voice.latestRename(of: speaker.id)
                if let latest, entry.identity?.basis != latest.id {
                    var rejected = entry.identity?.rejectedProfileIDs ?? []
                    // A name starts a profile only with a voice to learn; without one it joins a profile that exists.
                    let hasVoice = prints.contains { $0.cleanSeconds >= options.learning.minimumNamedSeconds }
                    let target = SpeakerProfile.isPlaceholder(latest.newValue) ? nil
                        : hasVoice ? work.profileID(named: latest.newValue) : work.existingProfileID(named: latest.newValue)
                    if let old = entry.identity, let profile = old.profileID, profile != target {
                        work.removeVoiceprints(meeting: meeting.id, speakers: voice.sources(of: speaker.id, prints), profile: profile)
                        // Daybook's label or suggestion was wrong: never offered for this speaker again.
                        if old.source == .recognized || old.source == .suggested { rejected.append(profile) }
                    }
                    if SpeakerProfile.isPlaceholder(latest.newValue) == false {
                        if let target { rejected.removeAll { $0 == target } }
                        entry.identity = SpeakerIdentity(speakerID: speaker.id, profileID: target, source: .named, basis: latest.id,
                                                         rejectedProfileIDs: Array(Set(rejected)).sorted { $0.uuidString < $1.uuidString })
                    } else {
                        entry.identity = rejected.isEmpty ? nil : SpeakerIdentity(speakerID: speaker.id, profileID: nil, source: .dismissed,
                            basis: latest.id, rejectedProfileIDs: Array(Set(rejected)).sorted { $0.uuidString < $1.uuidString })
                    }
                    // A label Daybook gave while the rename was on its way through sync gives way to the person's name.
                    entry.name = latest.newValue
                    current[meeting.id]?[speaker.id] = entry
                }
                // A profile the person said this speaker isn't (on any device) forgets what it learned from it.
                for rejected in entry.identity?.rejectedProfileIDs ?? [] {
                    work.removeVoiceprints(meeting: meeting.id, speakers: voice.sources(of: speaker.id, prints), profile: rejected)
                }
                // A name that joined no profile (no voice yet) joins one made since from another conversation.
                if var identity = entry.identity, identity.source == .named, identity.profileID == nil, !SpeakerProfile.isPlaceholder(entry.name),
                   let profile = work.existingProfileID(named: entry.name) {
                    identity.profileID = profile
                    entry.identity = identity
                    current[meeting.id]?[speaker.id] = entry
                }
                if let identity = entry.identity, identity.source.isPersonChosen, let profile = identity.profileID {
                    let origin: Voiceprint.Origin = identity.source == .named ? .named : .confirmed
                    work.teach(profile, origin: origin, basis: identity.basis?.uuidString ?? "", prints: prints, meeting: meeting)
                }
            }
        }
        work.retireBeyondLimits()

        // 2. Labels and suggestions from the profiles as they stand.
        let book = SpeakerProfileBook(profiles: work.activeProfiles, voiceprints: work.activeVoiceprints, learning: options.learning)
        var lessons: [Lesson] = []
        if options.recognizes {
            for meeting in ordered {
                let voice = voices[meeting.id]!
                var decisions: [String: Decision] = [:]
                for speaker in meeting.speakers.sorted(by: { $0.id < $1.id }) {
                    guard let entry = current[meeting.id]?[speaker.id] else { continue }
                    if let identity = entry.identity, !identity.$source.isKnown || identity.source.isPersonChosen { continue }
                    decisions[speaker.id] = decide(speaker.id, entry: entry, voice: voice, book: book, matching: options.matching, meetingID: meeting.id)
                }
                resolveConflicts(&decisions, meeting: meeting, voice: voice, current: current[meeting.id] ?? [:], margin: options.matching.margin)
                for (speakerID, decision) in decisions.sorted(by: { $0.key < $1.key }) {
                    guard var entry = current[meeting.id]?[speakerID] else { continue }
                    apply(decision, to: &entry, speakerID: speakerID, meeting: meeting, voice: voice, profiles: work.activeProfilesByID)
                    current[meeting.id]?[speakerID] = entry
                    if entry.identity?.source == .recognized, let lesson = decision.lesson(matching: options.matching, learning: options.learning, meeting: meeting) {
                        lessons.append(lesson)
                    }
                }
            }
        }

        // 3. Learning from what was recognized with confidence, newest conversations first.
        for lesson in lessons.sorted(by: { $0.recordedAt == $1.recordedAt ? $0.id < $1.id : $0.recordedAt > $1.recordedAt }) {
            work.learn(lesson)
        }
        work.retireBeyondLimits()

        var result = SpeakerProfileReconciliation()
        result.profiles = work.changedProfiles
        result.voiceprints = work.changedVoiceprints
        for meeting in ordered {
            for speaker in meeting.speakers.sorted(by: { $0.id < $1.id }) {
                guard let entry = current[meeting.id]?[speaker.id] else { continue }
                let identity = meeting.speakerIdentity(speaker.id)
                guard entry.name != speaker.name || entry.identity != identity else { continue }
                result.speakers.append(SpeakerIdentityChange(meetingID: meeting.id, speakerID: speaker.id, expectedName: speaker.name,
                                                             expectedIdentity: identity, name: entry.name, identity: entry.identity))
            }
        }
        return result
    }

    // MARK: Deciding

    struct Decision {
        var ranked: [SpeakerProfileCandidate]
        var best: SpeakerProfileCandidate?
        var print: MeetingVoices.Print?
        var outcome: SpeakerProfileIdentification.Decision
        var runnerUp: Double? { ranked.dropFirst().first?.similarity }

        func lesson(matching: SpeakerProfileMatching, learning: SpeakerProfileLearning, meeting: Meeting) -> Lesson? {
            guard outcome == .recognized, let best, let print, best.similarity >= matching.learnSimilarity,
                  best.similarity - (runnerUp ?? -1) >= matching.learnMargin, best.anchorSimilarity >= matching.anchorSimilarity,
                  print.cleanSeconds >= learning.minimumLearnSeconds, print.share >= learning.minimumLearnShare else { return nil }
            return Lesson(profileID: best.profileID, print: print, similarity: best.similarity, meeting: meeting)
        }
    }

    struct Lesson {
        var profileID: UUID
        var print: MeetingVoices.Print
        var similarity: Double
        var meeting: Meeting
        var recordedAt: Date { meeting.date }
        var id: String { Voiceprint.id(origin: .recognized, profileID: profileID, meetingID: meeting.id, speakerID: print.speakerID, space: print.vector.space) }
    }

    private static func decide(_ speakerID: String, entry: (name: String, identity: SpeakerIdentity?), voice: MeetingVoices,
                               book: SpeakerProfileBook, matching: SpeakerProfileMatching, meetingID: UUID) -> Decision {
        let prints = voice.prints(of: speakerID)
        let excluded = Set(entry.identity?.rejectedProfileIDs ?? [])
        // A voice is never compared with what was learned from itself.
        let own = voice.sources(of: speakerID, prints)
        var best: [UUID: (SpeakerProfileCandidate, MeetingVoices.Print)] = [:]
        for print in prints {
            for candidate in book.candidates(for: print.vector, excluding: excluded, excludingSource: (meetingID, own)) {
                if let current = best[candidate.profileID], current.0.similarity >= candidate.similarity { continue }
                best[candidate.profileID] = (candidate, print)
            }
        }
        let candidates: [SpeakerProfileCandidate] = best.values.map { $0.0 }
        let ranked = candidates.sorted { (a: SpeakerProfileCandidate, b: SpeakerProfileCandidate) -> Bool in
            a.similarity == b.similarity ? a.profileID.uuidString < b.profileID.uuidString : a.similarity > b.similarity
        }
        var identification = SpeakerProfileBook.decide(ranked, matching: matching)
        let top = identification.best
        let print = top.flatMap { best[$0.profileID]?.1 }
        if identification.decision == .recognized, (print?.cleanSeconds ?? 0) < matching.minimumLabelSeconds {
            identification.decision = .suggested
        }
        // A label already given stays while the voice is still clearly that profile's.
        if identification.decision == .suggested, let identity = entry.identity, identity.source == .recognized,
           let top, identity.profileID == top.profileID, top.similarity >= matching.keepSimilarity,
           top.similarity - (identification.runnerUp?.similarity ?? -1) >= matching.margin / 2,
           (print?.cleanSeconds ?? 0) >= matching.minimumLabelSeconds {
            identification.decision = .recognized
        }
        return Decision(ranked: ranked, best: top, print: print, outcome: identification.decision)
    }

    /// One recording can't have two voices labelled the same person: when two of its speakers (that
    /// aren't the same voice) match one profile, only one clearly closer than the other keeps the
    /// label; and a profile the person already gave someone in a recording isn't given to another of
    /// its voices. The others become suggestions.
    private static func resolveConflicts(_ decisions: inout [String: Decision], meeting: Meeting, voice: MeetingVoices,
                                         current: [String: (name: String, identity: SpeakerIdentity?)], margin: Double) {
        var claimedByPerson: [String: Set<String>] = [:]
        for (speakerID, entry) in current {
            guard let identity = entry.identity, identity.source.isPersonChosen, let profile = identity.profileID else { continue }
            for print in voice.prints(of: speakerID) { claimedByPerson["\(print.trackKey)|\(profile)", default: []].insert(print.speakerID) }
        }
        var claims: [String: [(speakerID: String, root: String, similarity: Double)]] = [:]
        for (speakerID, decision) in decisions where decision.outcome == .recognized {
            guard let best = decision.best, let print = decision.print else { continue }
            claims["\(print.trackKey)|\(best.profileID)", default: []].append((speakerID, print.speakerID, best.similarity))
        }
        for (key, claimants) in claims {
            let person = claimedByPerson[key] ?? []
            var open: [(speakerID: String, root: String, similarity: Double)] = []
            for claimant in claimants {
                if person.contains(claimant.root) { continue }
                if !person.isEmpty { decisions[claimant.speakerID]?.outcome = .suggested } else { open.append(claimant) }
            }
            var byRoot: [String: Double] = [:]
            for claimant in open { byRoot[claimant.root] = max(byRoot[claimant.root] ?? -1, claimant.similarity) }
            guard byRoot.count > 1 else { continue }
            let roots = byRoot.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            let keeps = roots[0].value - roots[1].value >= margin ? roots[0].key : nil
            for claimant in open where claimant.root != keeps { decisions[claimant.speakerID]?.outcome = .suggested }
        }
    }

    private static func apply(_ decision: Decision, to entry: inout (name: String, identity: SpeakerIdentity?), speakerID: String,
                              meeting: Meeting, voice: MeetingVoices, profiles: [UUID: SpeakerProfile]) {
        let old = entry.identity
        let rejected = old?.rejectedProfileIDs
        let basis = voice.latestRename(of: speakerID)?.id ?? old?.basis
        /// Daybook's own label, still as it gave it.
        let labelledHere = old?.source == .recognized && old?.appliedName == entry.name
        func withdraw() {
            if labelledHere, let previous = old?.previousName { entry.name = previous }
        }
        var outcome = decision.outcome
        if outcome != .unknown, decision.best.flatMap({ profiles[$0.profileID] }) == nil { outcome = .unknown }
        switch outcome {
        case .recognized:
            let best = decision.best!, profile = profiles[best.profileID]!
            if labelledHere || SpeakerProfile.isPlaceholder(entry.name) || voice.isOwnerDefault(speakerID, name: entry.name) {
                let previous = labelledHere ? old?.previousName : entry.name
                entry.name = profile.name
                entry.identity = SpeakerIdentity(speakerID: speakerID, profileID: profile.id, source: .recognized, similarity: rounded(best.similarity),
                                                 appliedName: profile.name, previousName: previous, basis: basis, rejectedProfileIDs: rejected)
            } else {
                // A name Daybook didn't give stays; the profile is only suggested.
                entry.identity = SpeakerIdentity(speakerID: speakerID, profileID: profile.id, source: .suggested,
                                                 similarity: rounded(best.similarity), basis: basis, rejectedProfileIDs: rejected)
            }
        case .suggested:
            withdraw()
            let best = decision.best!
            entry.identity = SpeakerIdentity(speakerID: speakerID, profileID: best.profileID, source: .suggested,
                                             similarity: rounded(best.similarity), basis: basis, rejectedProfileIDs: rejected)
        case .unknown:
            withdraw()
            entry.identity = (rejected ?? []).isEmpty ? nil
                : SpeakerIdentity(speakerID: speakerID, profileID: nil, source: .dismissed, basis: basis, rejectedProfileIDs: rejected)
        }
    }

    /// Similarities are kept to three places, so a conversation doesn't change over noise in the last digit.
    private static func rounded(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
}

// MARK: - Working state

extension SpeakerProfileReconciler {
    struct Work {
        var profiles: [String: LibraryValue<SpeakerProfile>]
        var voiceprints: [String: LibraryValue<Voiceprint>]
        let original: SpeakerProfileState
        let learning: SpeakerProfileLearning
        let now: Date
        private var changedProfileIDs = Set<String>(), changedVoiceprintIDs = Set<String>()

        init(state: SpeakerProfileState, learning: SpeakerProfileLearning, now: Date) {
            profiles = Dictionary(state.profiles.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.modifiedAt >= b.modifiedAt ? a : b })
            voiceprints = Dictionary(state.voiceprints.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.modifiedAt >= b.modifiedAt ? a : b })
            original = state; self.learning = learning; self.now = now
        }

        var activeProfiles: [SpeakerProfile] { profiles.values.compactMap(\.value).sorted { $0.id.uuidString < $1.id.uuidString } }
        var activeProfilesByID: [UUID: SpeakerProfile] { Dictionary(activeProfiles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }
        var activeVoiceprints: [Voiceprint] { voiceprints.values.compactMap(\.value).sorted { $0.id < $1.id } }
        var changedProfiles: [LibraryValue<SpeakerProfile>] { changedProfileIDs.sorted().compactMap { profiles[$0] } }
        var changedVoiceprints: [LibraryValue<Voiceprint>] { changedVoiceprintIDs.sorted().compactMap { voiceprints[$0] } }

        /// The active profile with this name, else a new one (`SpeakerProfile.id(forName:)`); a profile
        /// renamed since its name gave it that ID is the same person.
        func existingProfileID(named name: String) -> UUID? {
            let key = SpeakerProfile.normalizedName(name)
            if let existing = activeProfiles.first(where: { SpeakerProfile.normalizedName($0.name) == key }) { return existing.id }
            let id = SpeakerProfile.id(forName: name)
            return profiles[id.uuidString]?.value != nil ? id : nil
        }

        mutating func profileID(named name: String) -> UUID {
            if let existing = existingProfileID(named: name) { return existing }
            let id = SpeakerProfile.id(forName: name)
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            profiles[id.uuidString] = LibraryValue(id: id.uuidString, value: SpeakerProfile(id: id, name: trimmed, createdAt: now), modifiedAt: now)
            changedProfileIDs.insert(id.uuidString)
            return id
        }

        /// The voiceprints of a speaker the person named or confirmed: each of its prints with enough
        /// clean speech, unless it's far from what the person named before (an outlier) or was
        /// learned and then removed or retired (a record is kept for those).
        mutating func teach(_ profile: UUID, origin: Voiceprint.Origin, basis: String, prints: [MeetingVoices.Print], meeting: Meeting) {
            guard profiles[profile.uuidString]?.value != nil else { return }
            for print in prints where print.cleanSeconds >= learning.minimumNamedSeconds {
                let id = Voiceprint.id(origin: origin, profileID: profile, meetingID: meeting.id, speakerID: print.speakerID,
                                       space: print.vector.space, basis: basis)
                guard voiceprints[id] == nil else { continue }
                let chosen = active(profile, space: print.vector.space).filter { $0.origin.isPersonChosen && $0.vector.values.count == print.vector.values.count }
                if !chosen.isEmpty, let similarity = Self.centroidSimilarity(print.vector, chosen), similarity < learning.outlierSimilarity { continue }
                add(Voiceprint(id: id, profileID: profile, origin: origin, vector: print.vector, meetingID: meeting.id, speakerID: print.speakerID,
                               trackID: print.trackID, condition: print.condition, speechSeconds: rounded(print.cleanSeconds),
                               recordedAt: meeting.date, addedAt: now))
            }
        }

        /// A recognized voiceprint, unless it was learned before, adds nothing new, or is older than
        /// every learned voiceprint of a full profile (so a full profile doesn't churn over old recordings).
        mutating func learn(_ lesson: Lesson) {
            let print = lesson.print
            guard profiles[lesson.profileID.uuidString]?.value != nil, voiceprints[lesson.id] == nil else { return }
            let existing = active(lesson.profileID, space: print.vector.space).filter { $0.vector.values.count == print.vector.values.count }
            if existing.contains(where: { (SpeakerProfileBook.similarity($0.vector.values, print.vector.values) ?? 0) >= learning.duplicateSimilarity }) { return }
            let learned = existing.filter { !$0.origin.isPersonChosen }
            if learned.count >= learning.maximumRecognized, let oldest = learned.map(\.recordedAt).min(), lesson.recordedAt <= oldest { return }
            add(Voiceprint(id: lesson.id, profileID: lesson.profileID, origin: .recognized, vector: print.vector, meetingID: lesson.meeting.id,
                           speakerID: print.speakerID, trackID: print.trackID, condition: print.condition, speechSeconds: rounded(print.cleanSeconds),
                           similarity: SpeakerProfileReconciler.rounded(lesson.similarity), recordedAt: lesson.recordedAt, addedAt: now))
        }

        /// Takes a speaker's voiceprints out of a profile (a deletion marker each, which also keeps
        /// them from being learned again).
        mutating func removeVoiceprints(meeting: UUID, speakers: Set<String>, profile: UUID) {
            for print in activeVoiceprints where print.profileID == profile && print.meetingID == meeting && speakers.contains(print.speakerID) {
                retire(print.id)
            }
        }

        /// Beyond `maximumPersonChosen` or `maximumRecognized` per profile and space, the voiceprints
        /// that count least go first, keeping one per kind of recording where it can.
        mutating func retireBeyondLimits() {
            let grouped = Dictionary(grouping: activeVoiceprints) { "\($0.profileID.uuidString)|\($0.vector.space)" }
            for key in grouped.keys.sorted() {
                let prints = grouped[key]!
                guard let newest = prints.map(\.recordedAt).max() else { continue }
                for chosen in [true, false] {
                    var kind = prints.filter { ($0.origin.isPersonChosen && $0.$origin.isKnown) == chosen }
                    let limit = chosen ? learning.maximumPersonChosen : learning.maximumRecognized
                    while kind.count > limit {
                        let conditions = Dictionary(grouping: kind) { $0.condition ?? "unknown" }
                        let victim = kind.min { a, b in
                            let lastA = conditions[a.condition ?? "unknown"]?.count == 1, lastB = conditions[b.condition ?? "unknown"]?.count == 1
                            if lastA != lastB { return !lastA }
                            let wa = SpeakerProfileBook.weight(a, personChosen: chosen, newest: newest, learning: learning)
                            let wb = SpeakerProfileBook.weight(b, personChosen: chosen, newest: newest, learning: learning)
                            return wa == wb ? a.id < b.id : wa < wb
                        }!
                        retire(victim.id)
                        kind.removeAll { $0.id == victim.id }
                    }
                }
            }
        }

        private func active(_ profile: UUID, space: String) -> [Voiceprint] {
            activeVoiceprints.filter { $0.profileID == profile && $0.vector.space == space }
        }

        private mutating func add(_ print: Voiceprint) {
            voiceprints[print.id] = LibraryValue(id: print.id, value: print, modifiedAt: now)
            changedVoiceprintIDs.insert(print.id)
        }

        private mutating func retire(_ id: String) {
            guard voiceprints[id]?.value != nil else { return }
            voiceprints[id] = LibraryValue(id: id, value: nil, modifiedAt: now)
            changedVoiceprintIDs.insert(id)
        }

        private func rounded(_ seconds: Double) -> Double { (seconds * 10).rounded() / 10 }

        static func centroidSimilarity(_ vector: VoiceVector, _ prints: [Voiceprint]) -> Double? {
            let units = prints.compactMap { SpeakerProfileBook.unit($0.vector.values) }
            guard let first = units.first else { return nil }
            var sum = [Float](repeating: 0, count: first.count)
            for unit in units { for index in sum.indices { sum[index] += unit[index] } }
            return SpeakerProfileBook.similarity(vector.values, sum)
        }
    }
}

// MARK: - A conversation's voices

/// Each speaker's voice embeddings and how much clean speech is behind them. A speaker shown in the
/// unified transcript may have none of its own (the microphone's owner, or a speaker another
/// recording's voice was matched to); it has the embeddings of the recordings' speakers it stands for.
struct MeetingVoices {
    struct Print: Equatable {
        /// The speaker the embedding belongs to.
        var speakerID: String
        var vector: VoiceVector
        var trackID: UUID?
        var condition: String
        var cleanSeconds: Double
        var share: Double
        var trackKey: String { trackID?.uuidString ?? "none" }
    }

    private var own: [String: Print] = [:]
    private var aliases: [String: Set<String>] = [:]
    private var renames: [String: MeetingRevision] = [:]
    private var ownerSpeakerID: String?

    init(_ meeting: Meeting) {
        let stats = Self.speech(meeting)
        let tracks = Dictionary(meeting.tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var matchedTo: [String: String] = [:]
        for match in meeting.speakerMatches ?? [] where match.status == .matched {
            guard let target = match.targetSpeakerID else { continue }
            aliases[target, default: []].insert(match.sourceSpeakerID)
            matchedTo[match.sourceSpeakerID] = target
        }
        for speaker in meeting.speakers {
            guard let embedding = speaker.embedding, let space = speaker.embeddingModelID, !space.isEmpty else { continue }
            let vector = VoiceVector(space: space, values: embedding)
            guard vector.isUsable else { continue }
            let track = speaker.sourceTrackID.flatMap { tracks[$0] }
            let key = speaker.sourceTrackID?.uuidString ?? "none"
            // A speaker matched to another when its recording was added has its passages under that speaker's label.
            let stat = stats["\(key)|\(speaker.id)"] ?? matchedTo[speaker.id].flatMap { stats["\(key)|\($0)"] } ?? (0, 0)
            own[speaker.id] = Print(speakerID: speaker.id, vector: vector, trackID: speaker.sourceTrackID,
                                    condition: track.map(Self.condition) ?? "unknown", cleanSeconds: stat.clean, share: stat.share)
        }
        for mapping in meeting.fusionSummary?.speakerMappings ?? [] {
            if let source = mapping.sourceSpeakerID, source != mapping.speakerID { aliases[mapping.speakerID, default: []].insert(source) }
        }
        for revision in meeting.revisions where revision.field.hasPrefix("speaker:") {
            let id = String(revision.field.dropFirst("speaker:".count))
            if let current = renames[id], (current.date, current.id.uuidString) >= (revision.date, revision.id.uuidString) { continue }
            renames[id] = revision
        }
        ownerSpeakerID = meeting.fusionSummary?.ownerSpeakerID
    }

    /// The speaker's own embedding and those of the speakers it stands for, one per embedding.
    func prints(of speakerID: String) -> [Print] {
        var ids = [speakerID]
        ids += (aliases[speakerID] ?? []).sorted()
        var seen = Set<String>()
        return ids.compactMap { id in seen.insert(id).inserted ? own[id] : nil }
    }

    /// The speakers whose embeddings these prints are, and the speaker itself.
    func sources(of speakerID: String, _ prints: [Print]) -> Set<String> { Set(prints.map(\.speakerID)).union([speakerID]) }

    func latestRename(of speakerID: String) -> MeetingRevision? { renames[speakerID] }

    /// The fused microphone owner still with fusion's default name ("Me").
    func isOwnerDefault(_ speakerID: String, name: String) -> Bool {
        speakerID == ownerSpeakerID && name == FusionOptions().ownerName
    }

    /// What kind of recording a track is: the recorder's kind, else its source.
    static func condition(_ track: RecordingTrack) -> String { track.deviceKind ?? track.$source.rawValue }

    /// Per recording and speaker label ("<track>|<label>"): speech without anyone else talking over
    /// it, and its share of the recording's speech. A recording transcribed more than once takes its
    /// best run.
    static func speech(_ meeting: Meeting) -> [String: (clean: Double, share: Double)] {
        var result: [String: (clean: Double, share: Double)] = [:]
        for run in meeting.transcripts {
            let segments = run.segments.filter { $0.end > $0.start && $0.speakerID != nil }
            let total = segments.reduce(0) { $0 + ($1.end - $1.start) }
            guard total > 0 else { continue }
            let labels = Set(segments.compactMap(\.speakerID))
            for label in labels {
                let mine = merge(segments.filter { $0.speakerID == label }.map { ($0.start, $0.end) })
                let others = merge(segments.filter { $0.speakerID != label }.map { ($0.start, $0.end) })
                let spoken = mine.reduce(0) { $0 + ($1.1 - $1.0) }
                let clean = max(0, spoken - overlap(mine, others))
                let share = spoken / total
                let key = "\(run.trackID.uuidString)|\(label)"
                if let existing = result[key], existing.clean >= clean { continue }
                result[key] = (clean, share)
            }
        }
        return result
    }

    private static func merge(_ spans: [(Double, Double)]) -> [(Double, Double)] {
        var result: [(Double, Double)] = []
        for span in spans.sorted(by: { $0.0 < $1.0 }) {
            if let last = result.last, span.0 <= last.1 { result[result.count - 1].1 = max(last.1, span.1) } else { result.append(span) }
        }
        return result
    }

    private static func overlap(_ a: [(Double, Double)], _ b: [(Double, Double)]) -> Double {
        var i = 0, j = 0, total = 0.0
        while i < a.count, j < b.count {
            let start = max(a[i].0, b[j].0), end = min(a[i].1, b[j].1)
            if end > start { total += end - start }
            if a[i].1 < b[j].1 { i += 1 } else { j += 1 }
        }
        return total
    }
}

// MARK: - Applying

extension Meeting {
    /// The speakers whose voices stand for a speaker: itself, and the recordings' speakers matched or
    /// mapped to it (the microphone's own speaker for the owner).
    public func voiceSourceIDs(of speakerID: String) -> [String] {
        var ids = [speakerID]
        for match in speakerMatches ?? [] where match.status == .matched && match.targetSpeakerID == speakerID { ids.append(match.sourceSpeakerID) }
        for mapping in fusionSummary?.speakerMappings ?? [] where mapping.speakerID == speakerID {
            if let source = mapping.sourceSpeakerID { ids.append(source) }
        }
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// Applies the changes for this conversation's speakers, each only while the speaker still has
    /// the name and identity it was decided from. Returns whether every change applied.
    @discardableResult
    public mutating func apply(_ changes: [SpeakerIdentityChange]) -> Bool {
        var all = true
        for change in changes where change.meetingID == id {
            guard let index = speakers.firstIndex(where: { $0.id == change.speakerID }), speakers[index].name == change.expectedName,
                  speakerIdentity(change.speakerID) == change.expectedIdentity else { all = false; continue }
            speakers[index].name = change.name
            setSpeakerIdentity(change.identity, for: change.speakerID)
        }
        return all
    }
}

extension LibraryMetadata {
    /// Applies a reconciliation made from `base`, item by item: a profile or voiceprint changed here
    /// since then (the person renamed or removed it, or sync brought another device's) keeps that
    /// change. Returns whether every item applied.
    @discardableResult
    public mutating func apply(_ result: SpeakerProfileReconciliation, base: SpeakerProfileState) -> Bool {
        var all = true
        func applied<T>(_ changes: [LibraryValue<T>], current: [LibraryValue<T>]?, base: [LibraryValue<T>]) -> [LibraryValue<T>]? {
            guard !changes.isEmpty else { return current }
            var items = Dictionary((current ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let before = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for change in changes {
                guard items[change.id] == before[change.id] else { all = false; continue }
                items[change.id] = change
            }
            return items.values.sorted { $0.id < $1.id }
        }
        speakerProfiles = applied(result.profiles, current: speakerProfiles, base: base.profiles)
        voiceprints = applied(result.voiceprints, current: voiceprints, base: base.voiceprints)
        return all
    }
}
