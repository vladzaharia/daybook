import AppKit
import DaybookCore
import DaybookKit
import DaybookUI
import Foundation
import SwiftUI

/// Presents the main window's one sheet for the selected conversation. Version History, Review Earlier Corrections,
/// Adjust Timing, and Original Transcript are DaybookUI's, the same sheets the iPhone shows.
struct ConversationSheet: View {
    let state: AppState
    let sheet: ActiveSheet
    var body: some View {
        if let meeting = state.selectedMeeting {
            switch sheet {
            case .versionHistory:
                // A restore would be overwritten while the conversation records or is processed here.
                VersionHistoryScreen(library: state.library, meetingID: meeting.id) {
                    state.recordingID == $0.id || state.processor.queue.runningID == $0.id
                }
            case .reviewCorrections:
                ReviewCorrectionsSheet(library: state.library, meetingID: meeting.id)
            case .adjustTiming(let id):
                AdjustTimingSheet(library: state.library, meetingID: meeting.id, trackID: id,
                                  recordingName: { state.recordingName($0, in: $1) },
                                  play: { MacPlayback.play($0, in: meeting, state: state) })
            case .originalTranscript(let id):
                OriginalTranscriptSheet(library: state.library, meetingID: meeting.id, trackID: id,
                                        recordingName: { state.recordingName($0, in: $1) })
            }
        } else {
            ContentUnavailableView("No Conversation Selected", systemImage: "text.bubble").frame(width: 360, height: 200)
        }
    }
}
