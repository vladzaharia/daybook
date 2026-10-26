import SwiftUI

/// Asks about a library in the wrong place (`AppState.libraryMoveOffer`, docs/sandbox.md). For a move, the library stays
/// closed until the person answers, and after it the app starts over.
struct LibraryMoveSheet: View {
    @ObservedObject var state: AppState
    let offer: LibraryMoveOffer

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Text(text.title).font(.headline).foregroundStyle(Ink.title)
            Text(text.message).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = state.libraryMoveError {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Ink.warning)
            }
            HStack(spacing: Space.s2) {
                if state.isMovingLibrary {
                    ProgressView().controlSize(.small)
                    Text("Moving…").foregroundStyle(.secondary)
                }
                Spacer()
                if state.movedLibrary != nil {
                    Button("Keep It") { state.finishLibraryMove(trashingOldCopy: false) }
                        .keyboardShortcut(.cancelAction)
                    Button("Move to Trash") { state.finishLibraryMove(trashingOldCopy: true) }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(text.secondary) { Task { await state.declineLibraryMove() } }
                        .keyboardShortcut(.cancelAction)
                    Button(text.primary) { state.acceptLibraryMove() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .disabled(state.isMovingLibrary)
            .padding(.top, Space.s2)
        }
        .padding(Space.s5)
        .frame(width: 440)
        .interactiveDismissDisabled()
    }

    private var text: (title: String, message: String, secondary: String, primary: String) {
        if state.movedLibrary != nil {
            return ("Library moved", "The old copy is still in its old place, where other apps can read it.", "", "")
        }
        switch offer {
        case .returnFromContainer(let plan) where plan.replacesOlder:
            return ("Move your library back?", "A newer Daybook kept a more recent copy of your library. The older copy here is kept beside it.",
                    "Not Now", "Move Library Back")
        case .returnFromContainer:
            return ("Move your library back?", "Your library is where a newer Daybook kept it.", "Not Now", "Move Library Back")
        case .moveIntoContainer(let plan) where plan.legacyExists:
            return ("Move your library", "Daybook keeps its library in a new place now. Choose your library in the next window to move it.",
                    "Quit", "Move Library…")
        case .moveIntoContainer:
            return ("Find your library", "Daybook couldn’t find your library. Choose it to move it into place, or start a new one.",
                    "Start Fresh", "Move Library…")
        case .oldCopyRemains:
            return ("An old copy of your library remains", "It’s in its old place, where other apps can read it. Daybook doesn’t use it.",
                    "Keep It", "Show in Finder")
        }
    }
}
