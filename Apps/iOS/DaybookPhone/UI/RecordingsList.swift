import DaybookKit
import SwiftUI

/// Recent conversations, newest first, for surfaces that show a few of them beside something else
/// (the pocket recorder's "recent conversations"). Tapping one opens it in the library. The full
/// library is `LibraryPage`.
struct RecordingsList: View {
    @Environment(PhoneAppModel.self) private var model
    var limit: Int?

    var body: some View {
        RecentConversations(library: model.library.controller, limit: limit)
    }
}

private struct RecentConversations: View {
    @ObservedObject var library: LibraryController
    let limit: Int?
    @Environment(ReadingSession.self) private var session

    var body: some View {
        let all = LibraryPlace.section(.all).meetings(in: library.meetings)
        let meetings = limit.map { Array(all.prefix($0)) } ?? all
        let now = Date()
        VStack(alignment: .leading, spacing: 0) {
            ForEach(meetings) { meeting in
                Button { session.open(meeting.id) } label: {
                    ConversationRow(meeting: meeting, status: StatusPresentation.row(ProcessingStatus.phone(meeting, now: now), meeting: meeting),
                                    timeLabel: RowDate.format(meeting.date, group: DateGroup.title(for: meeting.date, now: now, calendar: .current), now: now))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
                if meeting.id != meetings.last?.id { Divider() }
            }
        }
    }
}
