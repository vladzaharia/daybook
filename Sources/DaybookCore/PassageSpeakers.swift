import Foundation

// Who said a passage, as the person puts it right. Diarization sometimes gives two people one speaker; the person moves
// a passage (or a run of them) to the right one. Each move is a Version History entry (`RevisionField.segmentSpeaker`),
// which syncs like every other edit and which processing again carries over to the new transcript
// (`CorrectionTransfer`), the way a corrected passage's words are. Nothing here touches a speaker's voice or its
// profile: a move changes the transcript, not what Daybook knows of anyone's voice.

extension Meeting {
    /// The speaker the person gave each passage, by passage ID: their latest word in Version History. A passage moved
    /// and moved back (undone) to the speaker it began with has none: the transcript's own reading stands.
    public var passageSpeakers: [UUID: String] {
        var entries: [UUID: [MeetingRevision]] = [:]
        for revision in revisions {
            if case .segmentSpeaker(let id) = revision.kind { entries[id, default: []].append(revision) }
        }
        var result: [UUID: String] = [:]
        for (id, list) in entries {
            // Stable by date: entries of one instant stay in the order they were written.
            let ordered = list.enumerated().sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }.map(\.element)
            guard let first = ordered.first, let latest = ordered.last, !latest.newValue.isEmpty, latest.newValue != first.oldValue else { continue }
            result[id] = latest.newValue
        }
        return result
    }

    /// Gives the passages to a speaker of the conversation. Each one that has another speaker now is recorded in
    /// Version History, with the speaker it had. False when nothing changed (no such speaker, or they were its already).
    @discardableResult
    public mutating func giveSpeaker(_ speakerID: String, toPassages ids: [UUID], at date: Date = Date()) -> Bool {
        guard speakers.contains(where: { $0.id == speakerID }) else { return false }
        let wanted = Set(ids)
        var changed = false
        for index in unifiedTranscript.indices where wanted.contains(unifiedTranscript[index].id) && unifiedTranscript[index].speakerID != speakerID {
            revisions.append(MeetingRevision(date: date, kind: .segmentSpeaker(unifiedTranscript[index].id),
                                             oldValue: unifiedTranscript[index].speakerID ?? "", newValue: speakerID))
            unifiedTranscript[index].speakerID = speakerID
            changed = true
        }
        if changed { updatedAt = date }
        return changed
    }

    /// The speaker called `name` in this conversation, added when there is none. Compared like profile names
    /// (case, accents, spaces). The new speaker is named as a rename names one, so it's the person's name for them,
    /// recorded in Version History; it has no voice yet.
    @discardableResult
    public mutating func speaker(named name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let key = SpeakerProfile.normalizedName(name)
        if let existing = speakers.first(where: { SpeakerProfile.normalizedName($0.name) == key }) { return existing.id }
        let id = "person-\(UUID().uuidString)"
        speakers.append(Speaker(id: id, name: "Speaker \(speakers.count + 1)"))
        renameSpeaker(id: id, name: name)
        return id
    }
}
