import DaybookUI
import SwiftUI

/// Vocabulary (Direction A §5.15): DaybookUI's `VocabularyScreen`, the iPhone's screen, as a window: a table of
/// terms edited in place, with Show Conversation for a term from one conversation. `--vocabulary-demo` fills a
/// scratch library's vocabulary (DaybookUI's `VocabularyDemo`).
struct GlossaryView: View {
    let state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VocabularyScreen(library: state.library) { id in
            state.window.place = .section(.all)
            state.window.openID = id
            openWindow(id: WindowID.library)
        }
    }
}
