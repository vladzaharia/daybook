import DaybookKit
import DaybookLink
import DaybookUI
import SwiftUI

// The library's rows are DaybookUI's, the Mac's too: `ConversationRowView`, `SearchResultRowView`, and
// `CaptionHitRowView` (docs/interface.md, "Window structure"). What's here is how this iPhone feeds them.

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
        var live: [UUID: LiveProgress] = [:]
        /// Where summaries run: this iPhone's countdowns and waits, and summaries running here or in the cloud.
        var planners: [UUID: SummaryPlacementPlanner] = [:]
        var runs: [UUID: SummaryPlace] = [:]
        var playing: UUID?
    }

    static func context(model: PhoneAppModel, library: LibraryController, player: PlaybackController) -> Context {
        Context(thisDeviceID: library.thisDevice.id, recordingOnMac: recording(model.link.connectedMacs.compactMap(\.recording)),
                live: model.liveProgress, planners: model.placement.planners, runs: model.placement.runs,
                playing: player.isPlaying ? player.meetingID : nil)
    }

    /// The conversations connected Macs say they're recording (starting, recording, or paused; not saving).
    static func recording(_ states: [LinkRecordingState]) -> Set<UUID> {
        Set(states.compactMap { state in
            [.starting, .recording, .paused].contains(state.phase) ? state.conversationID : nil
        })
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
            placement: .init(planner: context.planners[meeting.id], run: context.runs[meeting.id]),
            isPlaying: context.playing == meeting.id)
        return ConversationStatusPresentation.row(ProcessingStatus.phone(meeting, now: now), meeting: meeting, inputs: inputs, now: now)
    }
}

/// One row of the library, in a view of its own: it reads what its status follows (a Mac's live progress, where
/// summaries run, playback), so a progress report redraws the rows and never rebuilds the list around them.
struct PhoneConversationRow: View {
    let library: LibraryController
    let meeting: Meeting
    let timeLabel: String
    @Environment(ReadingSession.self) private var session
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        let context = PhoneRowStatus.context(model: model, library: library, player: session.player)
        ConversationRowView(meeting: meeting, status: PhoneRowStatus.make(meeting, context: context, now: Date()), timeLabel: timeLabel)
    }
}
