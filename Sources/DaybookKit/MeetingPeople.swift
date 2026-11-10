import DaybookCore
import Foundation

/// One of the people in a conversation, as the inspector's People and the iPhone's Info › People list them: the
/// speaker, its place among the conversation's speakers (which picks its ink, so colours keep their places), how long
/// it talked, and its share of the talking shown.
public struct MeetingPerson: Equatable, Identifiable, Sendable {
    public var speaker: Speaker
    /// Its index in `Meeting.speakers`.
    public var index: Int
    public var talkTime: TimeInterval
    /// Its talk time over all the people shown, 0...1.
    public var share: Double
    public var id: String { speaker.id }
}

extension Meeting {
    /// How long a speaker talked in the transcript.
    public func talkTime(of speakerID: String) -> TimeInterval {
        unifiedTranscript.filter { $0.speakerID == speakerID }.reduce(0) { $0 + max(0, $1.end - $1.start) }
    }

    /// The people in the conversation, in the speakers' order. A TV's presenter, left out as background audio, isn't
    /// one of them (`backgroundOnlySpeakerIDs`), nor is a speaker heard only in a recording taken out of the
    /// conversation; shares are of the talking the people shown did.
    public var peopleSpeakers: [MeetingPerson] {
        let background = backgroundOnlySpeakerIDs
        let removed = Set(tracks.filter(\.isRemoved).map(\.id))
        let timed = speakers.enumerated().map { (pair: $0, time: talkTime(of: $0.element.id)) }
        let shown = timed.filter { item in
            !background.contains(item.pair.element.id)
                && !(item.time == 0 && item.pair.element.sourceTrackID.map(removed.contains) == true)
        }
        let total = max(1, shown.map(\.time).reduce(0, +))
        return shown.map { item in
            MeetingPerson(speaker: item.pair.element, index: item.pair.offset, talkTime: item.time, share: item.time / total)
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
