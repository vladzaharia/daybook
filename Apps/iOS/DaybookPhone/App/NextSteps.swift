import DaybookKit
import Foundation

extension SharedNextSteps {
    /// Newest conversations first, with their unfinished actions in summary order. The library's
    /// meetings exclude Trash; Spotlight's rule also excludes explicitly and automatically Personal ones.
    @MainActor
    init(meetings: [Meeting]) {
        var items: [Item] = []
        items.reserveCapacity(Self.limit)
        for meeting in meetings where SpotlightPlan.isShown(meeting) {
            guard let actions = meeting.summary?.actionItems else { continue }
            let index = items.firstIndex { item in
                meeting.date > item.date || (meeting.date == item.date && meeting.id.uuidString < item.meetingID.uuidString)
            } ?? items.endIndex
            guard index < Self.limit else { continue }
            var offset = 0
            for action in actions where !action.completed {
                let position = index + offset
                guard position < Self.limit else { break }
                if items.count == Self.limit { items.removeLast() }
                items.insert(Item(meetingID: meeting.id, title: meeting.title, date: meeting.date, text: action.text), at: position)
                offset += 1
            }
        }
        self.init(items)
    }
}
