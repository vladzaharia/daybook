import DaybookCore
import DaybookKit
import SwiftUI

/// Inspector › Audio: how much was left out as music or TV, with Include; once included, Leave Out.
/// Unstyled, like `SourceHooks`.
struct BackgroundAudioHook: View {
    @ObservedObject var state: AppState
    let meeting: Meeting

    var body: some View {
        if let line = Self.line(meeting) {
            HStack(alignment: .firstTextBaseline) {
                Text(line).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                let included = meeting.includesBackgroundAudio == true
                Button(included ? "Leave Out" : "Include") { Task { await state.includeBackgroundAudio(!included, in: meeting.id) } }
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(state.processingID == meeting.id)
            }
        }
    }

    /// "Left out 2 min of music or TV", "Includes music or TV", or nil when there's none.
    static func line(_ meeting: Meeting) -> String? {
        if meeting.includesBackgroundAudio == true {
            var leftOut = meeting
            leftOut.includesBackgroundAudio = nil
            return leftOut.backgroundSegmentKinds().isEmpty ? nil : "Includes music or TV"
        }
        guard meeting.backgroundDuration > 0 else { return nil }
        return "Left out \(DurationLabel.format(meeting.backgroundDuration)) of music or TV"
    }
}
