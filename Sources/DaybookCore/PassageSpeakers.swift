import Foundation

// Who said a passage, as the person puts it right. Diarization sometimes gives two people one speaker; the person moves
// a passage (or a run of them) to the right one. Each move is a Version History entry (`RevisionField.segmentSpeaker`),
// which syncs like every other edit and which processing again carries over to the new transcript
// (`CorrectionTransfer`), the way a corrected passage's words are. Nothing here touches a speaker's voice or its
// profile: a move changes the transcript, not what Daybook knows of anyone's voice.
//
// A move names a passage by its ID and a speaker by its ID. Neither is reused for something else: a new transcript keeps
// a passage's ID only for the same passage (`CorrectionTransfer` carries it over), and every run of speaker detection
// names its speakers after the run ("<run>:S1"), while a conversation's speakers are only ever added to. So a speaker the
// person chose stays that speaker, whoever a later run finds.

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
            // In the order they were made; entries of one instant by their IDs, so every device reads the same.
            let ordered = list.sorted { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }
            guard let first = ordered.first, let latest = ordered.last, !latest.newValue.isEmpty, latest.newValue != first.oldValue else { continue }
            result[id] = latest.newValue
        }
        return result
    }

    /// Gives every passage the person moved (`passageSpeakers`) the speaker they gave it, where that passage and that
    /// speaker are here. Two devices' copies merge to one copy's transcript (`MeetingMerge`); this puts back a move
    /// made on the other one meanwhile, which Version History has from both.
    mutating func applyPassageSpeakers() {
        let pins = passageSpeakers
        guard !pins.isEmpty else { return }
        let known = Set(speakers.map(\.id))
        for index in unifiedTranscript.indices {
            guard let speakerID = pins[unifiedTranscript[index].id], known.contains(speakerID) else { continue }
            unifiedTranscript[index].speakerID = speakerID
        }
    }

    /// Gives the passages to a speaker of the conversation, or with "" to none (the speaker a passage began without,
    /// which Undo and Version History give back). Each one that has another speaker now is recorded in Version History,
    /// with the speaker it had. False when nothing changed (no such speaker, or they were its already).
    @discardableResult
    public mutating func giveSpeaker(_ speakerID: String, toPassages ids: [UUID], at date: Date = Date()) -> Bool {
        guard speakerID.isEmpty || speakers.contains(where: { $0.id == speakerID }) else { return false }
        let wanted = Set(ids)
        var changed = false
        for index in unifiedTranscript.indices where wanted.contains(unifiedTranscript[index].id) && (unifiedTranscript[index].speakerID ?? "") != speakerID {
            revisions.append(MeetingRevision(date: date, kind: .segmentSpeaker(unifiedTranscript[index].id),
                                             oldValue: unifiedTranscript[index].speakerID ?? "", newValue: speakerID))
            unifiedTranscript[index].speakerID = speakerID.isEmpty ? nil : speakerID
            changed = true
        }
        if changed { updatedAt = date }
        return changed
    }

    /// Gives the passages to the speaker called `name` (`speaker(named:)`), made only when a passage moves to them: nothing
    /// changes, and no speaker is added, otherwise. Returns that speaker's ID when a passage moved.
    @discardableResult
    public mutating func giveSpeaker(named name: String, toPassages ids: [UUID], at date: Date = Date()) -> String? {
        var moved = self
        guard let speakerID = moved.speaker(named: name), moved.giveSpeaker(speakerID, toPassages: ids, at: date) else { return nil }
        self = moved
        return speakerID
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
