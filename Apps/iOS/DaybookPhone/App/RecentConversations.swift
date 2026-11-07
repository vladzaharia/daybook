import DaybookKit
import Foundation

extension SharedRecentConversations {
    /// Projects only the newest six non-Personal conversations. `meetings` excludes the Trash;
    /// Spotlight's rule also keeps both explicitly and automatically Personal ones off this surface.
    @MainActor
    init(meetings: [Meeting]) {
        var recent: [Conversation] = []
        recent.reserveCapacity(Self.limit)
        for meeting in meetings where ConversationIndex.isShown(meeting) {
            let index = recent.firstIndex { entry in
                meeting.date > entry.date || (meeting.date == entry.date && meeting.id.uuidString < entry.id.uuidString)
            } ?? recent.endIndex
            guard index < Self.limit else { continue }
            if recent.count == Self.limit { recent.removeLast() }
            recent.insert(Conversation(id: meeting.id, title: meeting.title, date: meeting.date), at: index)
        }
        self.init(recent)
    }
}
