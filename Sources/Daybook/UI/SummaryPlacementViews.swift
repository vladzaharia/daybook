import DaybookDesign
import DaybookKit
import SwiftUI

// A summary's countdown, and where it runs, wherever processing status shows (docs/interface.md, "Where
// summaries run"): the list row, the inspector, and Floating Notes. The page's status line is the shared
// `StatusBlock`. The words come from `SummaryPlacementPlanner`, shared with the iPhone; only the views that show
// a countdown read `AppState.placements`, and only a countdown ticks, once a second.

/// Text that follows a countdown, a second at a time, its digits rolling down (a fade under Reduce Motion); static
/// otherwise.
struct PlacementText: View {
    let planner: SummaryPlacementPlanner
    let words: (Date) -> String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if planner.deadline != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let text = words(context.date) ?? ""
                Text(text).monospacedDigit().daybookNumberRoll(value: text, countsDown: true)
            }
        } else {
            Text(words(Date()) ?? "")
        }
    }
}

/// Use the Cloud and Start Now as text links; Stop while it runs in the cloud.
struct PlacementActions: View {
    let state: AppState
    let meetingID: UUID
    let planner: SummaryPlacementPlanner

    var body: some View {
        HStack(spacing: Space.s3) {
            ForEach(planner.actions, id: \.self) { action in
                Button(action.title) { state.chooseSummaryPlacement(action, for: meetingID) }
                    .buttonStyle(.daybookLink)
            }
            if planner.started != nil {
                Button("Stop") { state.pauseProcessing(meetingID) }.buttonStyle(.daybookLink)
            }
        }
    }
}

/// The inspector's Processing section while a summary is placed: the line and its choices.
struct PlacementInspectorRow: View {
    let state: AppState
    let placements: SummaryPlacements
    let meetingID: UUID

    init(state: AppState, meetingID: UUID) {
        self.state = state
        self.meetingID = meetingID
        placements = state.placements
    }

    var body: some View {
        if let planner = placements[meetingID], planner.line(at: Date(), thisDevice: AppState.thisDeviceWords) != nil {
            VStack(alignment: .leading, spacing: Space.s1) {
                PlacementText(planner: planner) { planner.line(at: $0, thisDevice: AppState.thisDeviceWords) }
                    .foregroundStyle(.secondary)
                PlacementActions(state: state, meetingID: meetingID, planner: planner)
            }
        }
    }
}

extension SummaryPlacementPlanner {
    /// The list row's words for a deadline: "Summarizing in 12 s".
    static func rowLine(until: Date, at now: Date) -> String {
        "Summarizing in \(max(1, Int(until.timeIntervalSince(now).rounded(.up)))) s"
    }
}
