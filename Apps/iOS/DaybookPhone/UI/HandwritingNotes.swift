import DaybookCore
import DaybookKit
import DaybookUI
import SwiftUI

// Handwriting and typing in the same notes (docs/iphone.md, "Handwriting"). The editor (DaybookUI's
// `MarginNotesEditor`) draws the ink between the typed paragraphs; here it's told where the notes are kept: a saved
// conversation's in the library, or the recording's while it runs.

extension NotesInkModel {
    /// A saved conversation's notes.
    @MainActor
    static func conversation(_ id: UUID, library: LibraryController, session: InkSession) -> NotesInkModel {
        NotesInkModel(
            session: session,
            placements: library.meeting(id)?.inkPlacements() ?? [],
            add: { block, index in library.addInk(block, to: id, after: index) },
            update: { block in library.updateInk(block, in: id) },
            remove: { blockID, keepingWords in library.removeInk(blockID, from: id, keepingWords: keepingWords) })
    }

    /// The recording's notes, while it runs.
    @MainActor
    static func recording(_ model: PhoneAppModel, session: InkSession) -> NotesInkModel {
        let recorder = model.recorder
        return NotesInkModel(
            session: session,
            placements: NoteTimeline.inkPlacements(recorder.ink, anchors: recorder.timedNotes, text: recorder.notes),
            add: { block, index in model.addInk(block, after: index) },
            update: { block in model.updateInk(block) },
            remove: { blockID, keepingWords in model.removeInk(blockID, keepingWords: keepingWords) })
    }
}

/// The notes with the writing tools at their foot: Write by Hand, then the pen, highlighter, eraser, and lasso while
/// writing. Apple Pencil writes on the page without any of this; the tools come up once it has.
struct WritableNotes<Editor: View>: View {
    let session: InkSession
    /// Inside a page, where the tools would otherwise sit on the last line.
    var keepsRoomForTools = false
    @ViewBuilder var editor: Editor

    /// What the tools take at the foot of the notes, for a scrolling editor's `bottomInset`.
    static var toolsHeight: CGFloat { 44 + PhoneStyle.Space.s2 * 2 }

    var body: some View {
        editor
            .padding(.bottom, keepsRoomForTools ? Self.toolsHeight : 0)
            .overlay(alignment: .bottomTrailing) {
                InkTools(session: session)
                    .padding(.trailing, PhoneStyle.Space.s2)
                    .padding(.bottom, PhoneStyle.Space.s2)
            }
    }
}
