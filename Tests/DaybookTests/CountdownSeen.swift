import DaybookKit
import Foundation

/// Whether a summary countdown began for one conversation: "a countdown never appeared". Checked the moment
/// `SummaryPlacements` reports a change (`onChange`, which also tells phones a countdown began), so one that starts
/// and ends in the same turn still counts. Whatever handled `onChange` before still does.
@MainActor
final class CountdownSeen {
    private(set) var happened = false
    private weak var placements: SummaryPlacements?
    private let previous: ((UUID) -> Void)?

    init(_ placements: SummaryPlacements, for id: UUID) {
        self.placements = placements
        previous = placements.onChange
        happened = placements[id]?.deadline != nil
        placements.onChange = { [weak self, weak placements, previous] changed in
            if changed == id, placements?[id]?.deadline != nil { self?.happened = true }
            previous?(changed)
        }
    }

    /// `onChange` goes back to what it was.
    func cancel() { placements?.onChange = previous }
}
