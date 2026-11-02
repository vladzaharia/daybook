import DaybookKit
import DaybookUI
import SwiftUI

// The library's rows are DaybookUI's, the Mac's too: `ConversationRowView`, `SearchResultRowView`, and
// `CaptionHitRowView` (docs/interface.md, "Window structure"). What's here is how this iPhone feeds them.

/// The shared label style, by the name the reading screens use.
typealias CompactLabelStyle = DaybookUI.CompactLabelStyle

/// A summary snippet as plain words, by the shared rule (`SearchHit.plainText(fromMarkdown:)`), under the name the
/// reading tests know it by.
enum SearchSnippet {
    static func plain(_ markdown: String) -> String { SearchHit.plainText(fromMarkdown: markdown) }
}

/// What a row says on this iPhone (`ConversationStatusPresentation.row`): a Mac recording it now (over the link),
/// a Mac's live progress on it before sync says so, where its summary runs, this iPhone's own work, and what the
/// library says; and the mint waveform while it plays here.
@MainActor
enum PhoneRowStatus {
    /// What the iPhone knows besides the conversation, read once for the whole list.
    struct Context {
        var thisDeviceID: String
        /// Conversations a connected Mac is recording now.
        var recordingOnMac: Set<UUID>
        var live: [UUID: LiveProgress]
        var placement: PhoneSummaryPlacement
        var playing: UUID?
    }

    static func context(model: PhoneAppModel, library: LibraryController, player: PlaybackController) -> Context {
        let recording = Set(model.link.connectedMacs.compactMap { mac -> UUID? in
            guard let state = mac.recording, [.starting, .recording, .paused].contains(state.phase) else { return nil }
            return state.conversationID
        })
        return Context(thisDeviceID: library.thisDevice.id, recordingOnMac: recording, live: model.liveProgress,
                       placement: model.placement, playing: player.isPlaying ? player.meetingID : nil)
    }

    static func make(_ meeting: Meeting, context: Context, now: Date) -> ConversationRowStatus? {
        let link = context.live[meeting.id].map { live in
            ConversationStatusPresentation.LinkWork(phase: live.phase, fraction: live.fraction, device: live.macName,
                                                    countdownUntil: live.countdownUntil, cloudModel: live.cloudModel,
                                                    placementActions: live.placementActions)
        }
        let inputs = ConversationStatusPresentation.Inputs(
            words: .iPhone(id: context.thisDeviceID), local: .iPhone(),
            isRecording: context.recordingOnMac.contains(meeting.id), link: link,
            placement: .init(planner: context.placement.planners[meeting.id], run: context.placement.runs[meeting.id]),
            isPlaying: context.playing == meeting.id)
        return ConversationStatusPresentation.row(ProcessingStatus.phone(meeting, now: now), meeting: meeting, inputs: inputs, now: now)
    }
}

/// The library row, for the screens that still hand it the reading status's `RowStatus` (the recent list behind the
/// recorder). The library draws `ConversationRowView` with `PhoneRowStatus` itself.
struct ConversationRow: View {
    let meeting: Meeting
    let status: RowStatus?
    let timeLabel: String

    var body: some View {
        ConversationRowView(meeting: meeting, status: status.map(Self.shared), timeLabel: timeLabel)
    }

    static func shared(_ status: RowStatus) -> ConversationRowStatus {
        let kind: ConversationRowStatus.Kind
        switch status.kind {
        case .notTranscribed: kind = .notTranscribed
        case .waiting: kind = status.text == "Paused" ? .paused : .waiting
        case .processing: kind = .processing
        case .failed: kind = .failed
        }
        return ConversationRowStatus(kind: kind, text: status.text, fraction: status.fraction, countdownUntil: status.countdownUntil)
    }
}
