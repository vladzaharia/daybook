import DaybookCore
import DaybookDesign
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

    /// The recording's notes as they were at Stop, while it's being saved: drawn, never written to.
    @MainActor
    static func stopped(_ model: PhoneAppModel, session: InkSession) -> NotesInkModel {
        let recorder = model.recorder
        return NotesInkModel(
            session: session,
            placements: NoteTimeline.inkPlacements(recorder.ink, anchors: recorder.timedNotes, text: recorder.notes),
            add: { _, _ in }, update: { _ in }, remove: { _, _ in nil })
    }
}

/// The notes, and the writing tools docked at their foot while a finger or Apple Pencil writes: the pen, highlighter,
/// eraser, lasso, undo, redo, and Keyboard, in a row of their own under the words, never over them. Nothing at rest:
/// Write by Hand is in the keyboard's bar beside Done, in the page's More menu, and between Bookmark and Stop while
/// recording, and Apple Pencil writes on the page with nothing to switch on.
struct WritableNotes<Editor: View>: View {
    let session: InkSession
    @ViewBuilder var editor: Editor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            editor
            if session.showsTools {
                InkTools(session: session)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DaybookSpacing.s2)
                    .transition(.opacity)
            }
        }
        .animation(DaybookMotion.resolved(DaybookMotion.state, reduceMotion: reduceMotion), value: session.showsTools)
    }
}
