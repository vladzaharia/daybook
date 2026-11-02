import DaybookKit
import DaybookUI
import SwiftUI

/// Your words with their recording times in the lane, then your bookmarks: DaybookUI's `YourNotes`, the same as the
/// Mac's, around this iPhone's notes editor. The notes save as you type, with a Version History entry once typing
/// pauses (`LibraryController.editNotes`).
struct PhoneNotes: View {
    let library: LibraryController
    let meeting: Meeting
    let play: (PlaybackTarget) -> Void
    let passages: PassageLinks
    @Environment(ReadingSession.self) private var session

    var body: some View {
        let times = meeting.paragraphTimes()
        let timed = times.contains { $0 != nil }
        YourNotes(meeting: meeting, library: library, canPlay: !meeting.presentTracks.isEmpty, play: play, passages: passages,
                  bookmarksID: SummaryBlockID.bookmarks) {
            MarginNotesEditor(
                text: Binding(get: { meeting.notes }, set: { library.editNotes(meeting.id, text: $0) }),
                times: times,
                placeholder: "Add a note…",
                // The lane appears only when a note has a recording time; notes typed while reading have none. It's the
                // bookmarks' lane, so their times line up.
                lane: timed ? PhoneStyle.Page.lane : 0,
                focusOnAppear: session.focusNotesFor == meeting.id,
                playTime: meeting.tracks.isEmpty ? nil : { play(.timeline($0)) },
                onFocusChange: { focused in if focused, session.focusNotesFor == meeting.id { session.focusNotesFor = nil } })
                .padding(.top, PhoneStyle.Space.s2)
        }
    }
}
