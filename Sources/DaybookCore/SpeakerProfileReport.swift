import Foundation

/// A dry run of `SpeakerProfileReconciler` over a whole library, in aggregate numbers, for checking
/// its thresholds against real recordings (`Daybook --speaker-report <library>`, debug builds;
/// docs/validation.md). It reconciles copies in memory, as the Mac would (a few rounds, until
/// nothing changes), then counts every speaker in the conversations' transcripts by kind of
/// recording and by what it ends up as, and how alike each voice is to the profiles. It works on
/// values, writes nothing, and its output holds no names, titles, or words.
public struct SpeakerProfileReport: Equatable, Sendable {
    /// What a speaker is after the dry run. A speaker with no voice embedding is `noVoice` whatever
    /// its name.
    public enum Outcome: String, CaseIterable, Sendable {
        case noVoice = "no voice", named, confirmed, labelled, suggested, dismissed, unknown
    }

    /// Similarities gathered, by what they measure.
    public enum Series: String, CaseIterable, Sendable {
        /// Speakers labelled, suggested, or unknown after the dry run: the closest profile.
        case labelled, suggested, unknown
        /// Speakers the person named or confirmed: their own profile with this conversation's
        /// voiceprints left out (the same person), and the closest other profile (someone else).
        case samePerson = "same person", otherPerson = "other people"
        /// Labelled speakers: how far the closest profile is ahead of the next, when there's another.
        case labelMargin = "label margin"
    }

    public struct Sample: Equatable, Sendable {
        public var series: Series
        /// The kind of recording ("microphone", "soundcore.work").
        public var kind: String
        public var value: Double
    }

    public var conversations = 0
    public var profiles = 0
    public var mergedProfiles = 0
    /// Active voiceprints after the dry run, by origin ("named", "confirmed", "recognized").
    public var voiceprints: [String: Int] = [:]
    public var options: SpeakerProfileOptions
    /// Reconciliation rounds run before nothing changed (at most the limit).
    public var rounds = 0
    /// What the dry run would change: speakers' names or identities, in how many conversations, and
    /// voiceprints added and retired.
    public var changedSpeakers = 0
    public var changedConversations = 0
    public var addedVoiceprints = 0
    public var retiredVoiceprints = 0
    /// Speakers by kind of recording and outcome.
    public var counts: [String: [Outcome: Int]] = [:]
    public var samples: [Sample] = []

    public init(options: SpeakerProfileOptions = .init()) { self.options = options }

    /// Reconciles copies of `meetings` and `metadata` until nothing changes (at most `rounds`), then
    /// measures. Nothing passed in is changed.
    public static func make(meetings: [Meeting], metadata: LibraryMetadata, options: SpeakerProfileOptions = .init(),
                            rounds limit: Int = 3, now: Date = Date()) -> SpeakerProfileReport {
        var report = SpeakerProfileReport(options: options)
        var meetings = meetings, metadata = metadata
        let before = Dictionary((metadata.voiceprints ?? []).map { ($0.id, $0.value != nil) }, uniquingKeysWith: { a, _ in a })
        var changed: [UUID: Set<String>] = [:]
        for round in 0..<limit {
            let base = SpeakerProfileState(metadata)
            let result = SpeakerProfileReconciler.reconcile(meetings: meetings, state: base, options: options, now: now.addingTimeInterval(Double(round)))
            guard !result.isEmpty else { break }
            report.rounds = round + 1
            metadata.apply(result, base: base)
            for index in meetings.indices where result.meetingIDs.contains(meetings[index].id) {
                meetings[index].apply(result.speakers)
            }
            for change in result.speakers { changed[change.meetingID, default: []].insert(change.speakerID) }
        }
        report.changedConversations = changed.count
        report.changedSpeakers = changed.values.reduce(0) { $0 + $1.count }
        for record in metadata.voiceprints ?? [] {
            let was = before[record.id], active = record.value != nil
            if active && was != true { report.addedVoiceprints += 1 }
            if !active && was == true { report.retiredVoiceprints += 1 }
        }
        report.conversations = meetings.count
        report.profiles = metadata.activeSpeakerProfiles.count
        report.mergedProfiles = (metadata.speakerProfiles ?? []).compactMap(\.value).filter { $0.mergedInto != nil }.count
        for print in metadata.resolvedVoiceprints { report.voiceprints[print.$origin.rawValue, default: 0] += 1 }

        let book = SpeakerProfileBook(metadata: metadata, learning: options.learning)
        for meeting in meetings { report.measure(meeting, book: book) }
        return report
    }

    /// The speakers people see (those in the transcript, a TV's presenter left out), so one voice
    /// that two speakers stand for (the owner and the microphone's speaker) counts once.
    private mutating func measure(_ meeting: Meeting, book: SpeakerProfileBook) {
        let voice = MeetingVoices(meeting)
        let tracks = Dictionary(meeting.tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let speaking = Set(meeting.unifiedTranscript.compactMap(\.speakerID))
        let background = meeting.backgroundOnlySpeakerIDs
        for speaker in meeting.speakers where (speaking.isEmpty || speaking.contains(speaker.id)) && !background.contains(speaker.id) {
            let prints = voice.prints(of: speaker.id)
            let kind = prints.first?.condition ?? speaker.sourceTrackID.flatMap { tracks[$0] }.map(MeetingVoices.condition) ?? "unknown"
            let identity = meeting.speakerIdentity(speaker.id).flatMap { $0.$source.isKnown ? $0 : nil }
            let outcome: Outcome
            if prints.isEmpty { outcome = .noVoice }
            else {
                switch identity?.source {
                case .named?: outcome = .named
                case .confirmed?: outcome = .confirmed
                case .recognized?: outcome = .labelled
                case .suggested?: outcome = .suggested
                case .dismissed?: outcome = .dismissed
                case nil: outcome = .unknown
                }
            }
            counts[kind, default: [:]][outcome, default: 0] += 1
            guard !prints.isEmpty else { continue }
            // As the reconciler compares: every recording's voice of the speaker, never with what was
            // learned from it, nor with a profile the person said it isn't.
            let sources = (meetingID: meeting.id, speakerIDs: voice.sources(of: speaker.id, prints))
            let excluded = Set(identity?.rejectedProfileIDs ?? [])
            var best: [UUID: Double] = [:]
            for print in prints {
                for candidate in book.candidates(for: print.vector, excluding: excluded, excludingSource: sources) {
                    best[candidate.profileID] = max(best[candidate.profileID] ?? -1, candidate.similarity)
                }
            }
            let ranked = best.sorted { $0.value == $1.value ? $0.key.uuidString < $1.key.uuidString : $0.value > $1.value }
            switch outcome {
            case .named, .confirmed:
                guard let own = identity?.profileID else { break }
                if let same = best[own] { samples.append(Sample(series: .samePerson, kind: kind, value: same)) }
                if let other = ranked.first(where: { $0.key != own }) { samples.append(Sample(series: .otherPerson, kind: kind, value: other.value)) }
            case .labelled:
                guard let top = ranked.first else { break }
                samples.append(Sample(series: .labelled, kind: kind, value: top.value))
                if let next = ranked.dropFirst().first { samples.append(Sample(series: .labelMargin, kind: kind, value: top.value - next.value)) }
            case .suggested:
                if let top = ranked.first { samples.append(Sample(series: .suggested, kind: kind, value: top.value)) }
            case .unknown, .dismissed:
                if let top = ranked.first { samples.append(Sample(series: .unknown, kind: kind, value: top.value)) }
            case .noVoice:
                break
            }
        }
    }

    // MARK: Text

    /// Similarity bins: below 0.40, then every 0.05 up to 1.
    static let bins: [Double] = (8...19).map { Double($0) / 20 }

    public var text: String {
        var lines: [String] = []
        let matching = options.matching
        lines.append("Speaker profile report (a dry run: nothing was written)")
        func count(_ value: Int, _ noun: String) -> String { "\(value) \(noun)\(value == 1 ? "" : "s")" }
        lines.append("Library: \(count(conversations, "conversation")), \(count(profiles, "profile"))"
                     + (mergedProfiles > 0 ? " (\(mergedProfiles) merged into others)" : "")
                     + ", voiceprints " + (voiceprints.isEmpty ? "none" : voiceprints.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")))
        lines.append(String(format: "Thresholds: label %.2f, margin %.2f, suggest %.2f, keep %.2f, learn %.2f (margin %.2f), %.0f s to label%@",
                            matching.labelSimilarity, matching.margin, matching.suggestionSimilarity, matching.keepSimilarity,
                            matching.learnSimilarity, matching.learnMargin, matching.minimumLabelSeconds,
                            options.recognizes ? "" : ", recognition off"))
        lines.append("Dry run: \(count(rounds, "round")); would change \(count(changedSpeakers, "speaker")) in \(count(changedConversations, "conversation")), "
                     + "add \(count(addedVoiceprints, "voiceprint")), retire \(retiredVoiceprints)")
        lines.append("")
        lines.append("Speakers by kind of recording")
        let outcomes = Outcome.allCases
        let kindWidth = max(16, (counts.keys.map(\.count).max() ?? 0) + 2)
        lines.append(pad("kind", kindWidth) + outcomes.map { pad($0.rawValue, 11, right: true) }.joined() + pad("all", 8, right: true))
        var totals: [Outcome: Int] = [:]
        for kind in counts.keys.sorted() {
            let row = counts[kind] ?? [:]
            for (outcome, count) in row { totals[outcome, default: 0] += count }
            lines.append(pad(kind, kindWidth) + outcomes.map { pad("\(row[$0] ?? 0)", 11, right: true) }.joined()
                         + pad("\(row.values.reduce(0, +))", 8, right: true))
        }
        lines.append(pad("all", kindWidth) + outcomes.map { pad("\(totals[$0] ?? 0)", 11, right: true) }.joined()
                     + pad("\(totals.values.reduce(0, +))", 8, right: true))
        lines.append("")
        lines.append("Similarity to the closest profile (speakers per bin; a bin is its lower edge)")
        let similaritySeries: [Series] = [.labelled, .suggested, .unknown, .samePerson, .otherPerson]
        lines.append(pad("", 14) + pad("<0.40", 7, right: true) + Self.bins.map { pad(String(format: "%.2f", $0), 6, right: true) }.joined()
                     + pad("n", 6, right: true) + pad("p10", 6, right: true) + pad("p50", 6, right: true) + pad("p90", 6, right: true))
        for series in similaritySeries {
            let values = samples.filter { $0.series == series }.map(\.value)
            var row = [Int](repeating: 0, count: Self.bins.count + 1)
            for value in values { row[Self.bins.lastIndex { value >= $0 }.map { $0 + 1 } ?? 0] += 1 }
            lines.append(pad(series.rawValue, 14) + pad("\(row[0])", 7, right: true) + row.dropFirst().map { pad("\($0)", 6, right: true) }.joined()
                         + pad("\(values.count)", 6, right: true) + Self.percentiles(values).map { pad($0, 6, right: true) }.joined())
        }
        lines.append("same person: speakers the person named or confirmed, against their own profile without this conversation's voiceprints;")
        lines.append("other people: the same speakers against the closest other profile.")
        lines.append("")
        lines.append("By kind of recording (p10 / p50 / p90, n)")
        let kinds = Set(samples.map(\.kind)).sorted()
        let columns: [Series] = [.samePerson, .otherPerson, .labelled, .labelMargin, .suggested, .unknown]
        lines.append(pad("kind", kindWidth) + columns.map { pad($0.rawValue, 24, right: true) }.joined())
        for kind in kinds {
            lines.append(pad(kind, kindWidth) + columns.map { series -> String in
                let values = samples.filter { $0.series == series && $0.kind == kind }.map(\.value)
                guard !values.isEmpty else { return pad("–", 24, right: true) }
                return pad(Self.percentiles(values).joined(separator: " / ") + " (\(values.count))", 24, right: true)
            }.joined())
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// p10, p50, and p90, two places each (nearest rank); dashes for none.
    static func percentiles(_ values: [Double]) -> [String] {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return ["–", "–", "–"] }
        return [0.1, 0.5, 0.9].map { fraction in
            let rank = min(sorted.count - 1, max(0, Int((fraction * Double(sorted.count)).rounded(.up)) - 1))
            return String(format: "%.2f", sorted[rank])
        }
    }

    private func pad(_ text: String, _ width: Int, right: Bool = false) -> String {
        guard text.count < width else { return right ? " " + text : text + " " }
        let space = String(repeating: " ", count: width - text.count)
        return right ? space + text : text + space
    }
}
