import DaybookKit
import SwiftUI

// A summary's countdown, and where it runs, wherever processing status shows (docs/interface.md, "Where
// summaries run"): the page's status line, the list row, the inspector, and Floating Notes. The words come
// from `SummaryPlacementPlanner`, shared with the iPhone; only the views that show a countdown observe
// `AppState.placements`, and only a countdown ticks, once a second.

/// Redraws its content when what's being placed changes (a countdown begins, the person chooses, it ends).
struct PlacementReader<Content: View>: View {
    @ObservedObject var placements: SummaryPlacements
    @ViewBuilder var content: () -> Content

    var body: some View { content() }
}

/// Text that follows a countdown, a second at a time; static otherwise.
struct PlacementText: View {
    let planner: SummaryPlacementPlanner
    let words: (Date) -> String?

    var body: some View {
        if planner.deadline != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(words(context.date) ?? "").monospacedDigit().contentTransition(.numericText(countsDown: true))
            }
        } else {
            Text(words(Date()) ?? "")
        }
    }
}

/// The page's status line while a summary is placed: "Summarizing on this Mac in 12 s", then Use the Cloud
/// and Start Now; "Summarizing with Claude Sonnet 5.5" with Stop while the cloud works.
struct PlacementStatusLine: View {
    @ObservedObject var state: AppState
    let meetingID: UUID
    let planner: SummaryPlacementPlanner

    var body: some View {
        HStack(spacing: Space.s2) {
            if case .started(.cloud) = planner.phase {
                if state.processingProgress.fraction > 0 {
                    PlacementText(planner: planner) { planner.line(at: $0, thisDevice: AppState.thisDeviceWords) }
                    ProgressView(value: state.processingProgress.fraction).progressViewStyle(.brand(width: 140))
                } else {
                    ProgressView().controlSize(.small)
                    PlacementText(planner: planner) { planner.line(at: $0, thisDevice: AppState.thisDeviceWords) }
                }
            } else {
                Image(systemName: "clock").foregroundStyle(Ink.secondary)
                PlacementText(planner: planner) { planner.line(at: $0, thisDevice: AppState.thisDeviceWords) }
            }
            Spacer(minLength: Space.s2)
            PlacementActions(state: state, meetingID: meetingID, planner: planner)
        }
    }
}

/// Use the Cloud and Start Now as text links; Stop while it runs in the cloud.
struct PlacementActions: View {
    @ObservedObject var state: AppState
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
    @ObservedObject var state: AppState
    @ObservedObject var placements: SummaryPlacements
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
