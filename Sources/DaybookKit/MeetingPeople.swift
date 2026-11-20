import DaybookCore
import Foundation

/// One of the people in a conversation, as the inspector's People and the iPhone's Info › People list them: the
/// speaker, its place among the conversation's speakers (which picks its ink, so colours keep their places), how long
/// it talked, and its share of the talking shown.
public struct MeetingPerson: Equatable, Identifiable, Sendable {
    /// The speaker that stands for the person: its name and identity are the row's.
    public var speaker: Speaker
    /// Every speaker the person is in the transcript, `speaker` first: more than one when the same voice was found
    /// more than once and named or recognized as one person (`Meeting.samePersonSpeakers`).
    public var speakerIDs: [String]
    /// Its index in `Meeting.speakers`.
    public var index: Int
    public var talkTime: TimeInterval
    /// Its talk time over all the people shown, 0...1.
    public var share: Double
    public var id: String { speaker.id }

    public init(speaker: Speaker, speakerIDs: [String]? = nil, index: Int, talkTime: TimeInterval, share: Double) {
        self.speaker = speaker; self.speakerIDs = speakerIDs ?? [speaker.id]; self.index = index
        self.talkTime = talkTime; self.share = share
    }
}

extension Meeting {
    /// How long a speaker talked in the transcript.
    public func talkTime(of speakerID: String) -> TimeInterval {
        unifiedTranscript.filter { $0.speakerID == speakerID }.reduce(0) { $0 + max(0, $1.end - $1.start) }
    }

    /// The people in the conversation, in the speakers' order: the speakers the transcript gives passages to
    /// (`transcriptSpeakers`), so a recording's speaker whose passages fused under another one, or a run's replaced
    /// since, isn't listed. Speakers that are one person (`samePersonSpeakers`) are one row, with their talking added
    /// up. A TV's presenter, left out as background audio, isn't one of them (`backgroundOnlySpeakerIDs`), nor, before
    /// anything is fused, is a speaker heard only in a recording taken out of the conversation; shares are of the
    /// talking the people shown did.
    public var peopleSpeakers: [MeetingPerson] {
        let background = backgroundOnlySpeakerIDs
        let removed = Set(tracks.filter(\.isRemoved).map(\.id))
        var times: [String: TimeInterval] = [:]
        for passage in unifiedTranscript { if let id = passage.speakerID { times[id, default: 0] += max(0, passage.end - passage.start) } }
        let shown = Set(transcriptSpeakers.map(\.id))
        let lead = samePersonSpeakers
        let indices = Dictionary(speakers.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var people: [(index: Int, members: [String], time: TimeInterval)] = []
        var row: [String: Int] = [:]
        for speaker in speakers where shown.contains(speaker.id) && !background.contains(speaker.id) {
            let time = times[speaker.id] ?? 0
            if time == 0, speaker.sourceTrackID.map(removed.contains) == true { continue }
            let person = lead[speaker.id] ?? speaker.id
            if let existing = row[person] {
                people[existing].members.append(speaker.id)
                people[existing].time += time
            } else {
                row[person] = people.count
                people.append((indices[person] ?? indices[speaker.id] ?? 0, [speaker.id], time))
            }
        }
        let total = max(1, people.map(\.time).reduce(0, +))
        return people.sorted { $0.index < $1.index }.map { item in
            let speaker = speakers[item.index]
            let members = [speaker.id] + item.members.filter { $0 != speaker.id }
            return MeetingPerson(speaker: speaker, speakerIDs: members, index: item.index, talkTime: item.time, share: item.time / total)
        }
    }

    /// The placement picker's automatic item, with where the conversation goes without a choice: "Work
    /// (automatic)", "Personal (automatic)", or "Automatic" while its kind isn't known.
    public var automaticPlacementTitle: String {
        var automatic = self
        automatic.placement = nil
        switch automatic.effectivePlacement {
        case .work?: return "Work (automatic)"
        case .personal?: return "Personal (automatic)"
        case nil: return "Automatic"
        }
    }
}
