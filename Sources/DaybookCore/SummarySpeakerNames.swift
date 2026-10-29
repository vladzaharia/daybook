import Foundation

// A summary is written from the transcript with the speakers' names as they were then, so one written
// before a speaker was named says "Speaker 2". When a speaker loses a name Daybook gave it (a
// placeholder, fusion's "Me" for the microphone's owner, or a profile's name Daybook labelled it
// with), whoever renamed it (the person, Yes or Not on a label, a label given or taken off, a profile
// renamed or merged), the summary's mentions of that name follow. A name the person gave is theirs:
// renaming it again leaves the summary alone (Summarize Again rewrites it). The summary changes in
// place, so ticked next steps, photos, and IDs stay, and the summary it replaces is in Version
// History, as any summary change is (docs/architecture.md, "Speakers and profiles").

extension Meeting {
    /// Whether `name` is one Daybook gave this speaker rather than the person: a placeholder
    /// ("Speaker 2"), fusion's "Me" for the microphone's owner, or the profile name Daybook labelled
    /// it with (`identity`, the speaker's identity when it had that name).
    public func isDaybooksName(_ name: String, for speakerID: String, identity: SpeakerIdentity?) -> Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if SpeakerProfile.isPlaceholder(name) { return true }
        if speakerID == fusionSummary?.ownerSpeakerID, name == FusionOptions().ownerName { return true }
        guard let identity, identity.$source.isKnown else { return false }
        return identity.source == .recognized && identity.appliedName == name
    }

    /// After a speaker was renamed from `old`, a name Daybook gave it, to `new`: the summary's mentions
    /// of `old` become `new`. Only while no other speaker is still called `old`, so a mention can't
    /// mean someone else. Returns whether the summary changed.
    @discardableResult
    public mutating func summaryFollowsRename(of speakerID: String, from old: String, to new: String) -> Bool {
        let old = old.trimmingCharacters(in: .whitespacesAndNewlines), new = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var summary, !old.isEmpty, !new.isEmpty, old != new,
              !speakers.contains(where: { $0.id != speakerID && $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == old }) else { return false }
        let before = summary
        func follow(_ text: String) -> String { SummaryNames.replacing(old, with: new, in: text) }
        summary.title = follow(summary.title)
        summary.overview = follow(summary.overview)
        for index in summary.sections.indices {
            summary.sections[index].heading = follow(summary.sections[index].heading)
            summary.sections[index].body = follow(summary.sections[index].body)
        }
        for index in summary.actionItems.indices {
            summary.actionItems[index].text = follow(summary.actionItems[index].text)
            summary.actionItems[index].owner = summary.actionItems[index].owner.map(follow)
        }
        guard summary != before else { return false }
        let oldValue = SyncEncoding.string(before), newValue = SyncEncoding.string(summary)
        // The same change made on two Macs (a label each gives) is one entry in Version History.
        revisions.append(MeetingRevision(id: SyncEncoding.uuid("summary-names|\(id.uuidString)|\(oldValue)|\(newValue)"),
                                         field: "summary", oldValue: oldValue, newValue: newValue))
        self.summary = summary
        updatedAt = Date()
        return true
    }
}

/// Names in a summary's text.
public enum SummaryNames {
    /// `text` with each whole `name` (not part of a longer word or number: "Speaker 2" never matches
    /// "Speaker 20") replaced by `replacement`. Case matters.
    public static func replacing(_ name: String, with replacement: String, in text: String) -> String {
        guard !name.isEmpty, text.contains(name),
              let pattern = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: name) + "(?![\\p{L}\\p{N}_])")
        else { return text }
        return pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }
}
