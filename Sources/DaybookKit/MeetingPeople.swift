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
    /// one of them (`backgroundOnlySpeakerIDs`), and shares are of the talking the people shown did.
    public var peopleSpeakers: [MeetingPerson] {
        let background = backgroundOnlySpeakerIDs
        let shown = speakers.enumerated().filter { !background.contains($0.element.id) }
        let times = shown.map { talkTime(of: $0.element.id) }
        let total = max(1, times.reduce(0, +))
        return zip(shown, times).map { pair, time in
            MeetingPerson(speaker: pair.element, index: pair.offset, talkTime: time, share: time / total)
        }
    }

    /// The template picker's first item, which carries the guess: "Automatic (Meeting)", or "Automatic" before
    /// there's a summary to guess from.
    public var automaticTemplateTitle: String {
        guard let kind = summary?.kind, kind != .auto else { return "Automatic" }
        return "Automatic (\(kind.title))"
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
