import Foundation

// Who is in a conversation (docs/architecture.md, "Speakers and profiles"). `Meeting.speakers` keeps every speaker label
// any recording's speaker detection made, for good: their voice embeddings, the matches between recordings, and the
// names and identities they were given are what processing again, fusion, and voice profiles work from. Many of them
// say nothing in the transcript: a recording's speaker matched by voice to one already here, the microphone's own
// speaker that fusion shows as the owner (or a call speaker its echo repeats), the speakers of a run processed again
// since. The people in the conversation are read from the fused transcript instead, here, so every list and count reads
// them the same way, on both apps, for conversations processed before this too.

extension Meeting {
    /// Speakers the unified transcript gives at least one passage.
    public var speakingSpeakerIDs: Set<String> { Set(unifiedTranscript.compactMap(\.speakerID)) }

    /// The speakers in the conversation, in `speakers` order: those with a passage in the unified transcript. One left
    /// with none stays in `speakers` for its voice and history, but isn't anyone here. Before anything is fused with
    /// speakers (no passage has one), every speaker counts.
    public var transcriptSpeakers: [Speaker] {
        let speaking = speakingSpeakerIDs
        guard !speaking.isEmpty else { return speakers }
        return speakers.filter { speaking.contains($0.id) }
    }

    /// Speakers in the conversation (`transcriptSpeakers`) that are one person, each mapped to the speaker that stands
    /// for them all; speakers that are no one else's aren't in it. Speakers are one person when their identities give
    /// the same profile by the person's choice (named, confirmed) or by a clear voice match (Recognized): the same voice
    /// found in two recordings, or found twice in one. A suggestion ("Maybe") joins no one until it's answered, and a
    /// match the person turned down ("Not …") is no longer an identity, so taking a label back separates the speaker
    /// again. Nothing is stored: the transcript keeps each speaker's own passages.
    ///
    /// The speaker that stands for them: one the person named or confirmed, then the owner fusion found on the
    /// microphone, then the first in `speakers`.
    public var samePersonSpeakers: [String: String] {
        let shown = transcriptSpeakers
        var groups: [UUID: [Int]] = [:]
        var order: [UUID] = []
        for (position, speaker) in shown.enumerated() {
            guard let identity = speakerIdentity(speaker.id), identity.$source.isKnown, let profile = identity.profileID,
                  [.named, .confirmed, .recognized].contains(identity.source) else { continue }
            if groups[profile] == nil { order.append(profile) }
            groups[profile, default: []].append(position)
        }
        let owner = fusionSummary?.ownerSpeakerID
        func rank(_ position: Int) -> (Int, Int, Int) {
            let speaker = shown[position]
            let chosen = speakerIdentity(speaker.id)?.source.isPersonChosen == true
            return (chosen ? 0 : 1, speaker.id == owner ? 0 : 1, position)
        }
        var result: [String: String] = [:]
        for profile in order {
            guard let members = groups[profile], members.count > 1, let lead = members.min(by: { rank($0) < rank($1) }) else { continue }
            for position in members { result[shown[position].id] = shown[lead].id }
        }
        return result
    }
}
