import DaybookDesign
import DaybookKit
import SwiftUI

/// The summary a page opened with, kept with its conversation: only a summary that arrives while the page shows that
/// conversation is revealed. A page that turns to another conversation starts again from that one's summary
/// (`opening`), and until it has, reveals nothing.
public struct SummaryArrival: Equatable, Sendable {
    private let meetingID: UUID
    private let openedWith: Date?

    public init(opening meeting: Meeting) {
        meetingID = meeting.id
        openedWith = meeting.summary?.createdAt
    }

    /// Whether `summary` arrived while the page showed `meeting`.
    public func reveals(_ summary: MeetingSummary, in meeting: Meeting) -> Bool {
        meeting.id == meetingID && summary.createdAt != openedWith
    }
}

extension View {
    /// A block of a summary that arrived while its page was open fades up a moment after the one before it (40 ms
    /// apart, up to six); under Reduce Motion it only fades. Blocks of a summary that was there when the page opened
    /// don't move: opening a page never animates.
    public func summaryReveal(index: Int, revealing: Bool, shown: Bool) -> some View {
        modifier(SummaryReveal(index: index, revealing: revealing, shown: shown))
    }
}

/// The reveal's timing, as plain values.
public enum SummaryRevealTiming {
    /// Each block starts this long after the one before it.
    public static let step: Double = 0.04
    /// No block waits longer than the sixth.
    public static let lastStaggered = 5

    public static func delay(index: Int) -> Double { Double(min(max(0, index), lastStaggered)) * step }
}

private struct SummaryReveal: ViewModifier {
    let index: Int
    let revealing: Bool
    let shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if revealing {
            content
                .opacity(shown ? 1 : 0)
                .offset(y: shown || reduceMotion ? 0 : 8)
                .animation(reduceMotion ? DaybookMotion.reduced : DaybookMotion.page.delay(SummaryRevealTiming.delay(index: index)), value: shown)
        } else {
            content
        }
    }
}
