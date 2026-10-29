import SwiftUI

/// Asks about a library in the wrong place (`AppState.libraryMoveOffer`, docs/sandbox.md). For a move, the library stays
/// closed until the person answers, and after it the app starts over.
struct LibraryMoveSheet: View {
    @ObservedObject var state: AppState
    let offer: LibraryMoveOffer

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            // A sheet is chrome: the system's label colours, not the page's ink.
            Text(text.title).font(.headline)
            Text(text.message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let problem = state.libraryMoveError { ProblemLine(problem: problem) }
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
            return ("Library Moved", "The old copy is still in its old place, where other apps can read it.", "", "")
        }
        switch offer {
        case .returnFromContainer(let plan) where plan.replacesOlder:
            return ("Move your library back?", "A newer Daybook kept a more recent copy of your library. The older copy here is kept beside it.",
                    "Not Now", "Move Library Back")
        case .returnFromContainer:
            return ("Move your library back?", "Your library is where a newer Daybook kept it.", "Not Now", "Move Library Back")
        case .moveIntoContainer(let plan) where plan.legacyExists:
            return ("Move Your Library", "Daybook keeps its library in a new place now. Choose your library in the next window to move it.",
                    "Quit", "Move Library…")
        case .moveIntoContainer:
            return ("Find Your Library", "Daybook couldn’t find your library. Choose it to move it into place, or start a new one.",
                    "Start Fresh", "Move Library…")
        case .oldCopyRemains:
            return ("An Old Copy of Your Library Remains", "It’s in its old place, where other apps can read it. Daybook doesn’t use it.",
                    "Keep It", "Show in Finder")
        }
    }
}

#if DEBUG
/// Debug-only: `--move-demo <case>` asks about a library in the wrong place, for screenshots, without moving anything
/// unless a button is pressed: return, return-newer, move, find, old-copy, moved, failed. Only with `--library`; applied
/// when Settings › Library opens (`--open-settings library`), and the sheet opens on the main window.
@MainActor
enum LibraryMoveDemo {
    private static var applied = false

    static func apply(to state: AppState) {
        guard !applied, let scenario = LaunchOptions.value(after: "--move-demo") else { return }
        applied = true
        // Places that don't exist, inside the demo's own library, so a button pressed by mistake finds nothing to move.
        guard let root = LaunchOptions.libraryURL?.appendingPathComponent("Move Demo", isDirectory: true) else { return }
        let legacy = root.appendingPathComponent("Old Place", isDirectory: true)
        let container = root.appendingPathComponent("Container", isDirectory: true)
        func returning(newer: Bool) -> LibraryMoveOffer {
            .returnFromContainer(.init(container: container, library: legacy, containerPreferences: container, replacesOlder: newer, containerChanged: nil))
        }
        let moving = LibraryMoveOffer.moveIntoContainer(.init(legacy: legacy, library: container, legacyExists: true))
        switch scenario {
        case "return": state.libraryMoveOffer = returning(newer: false)
        case "return-newer": state.libraryMoveOffer = returning(newer: true)
        case "move": state.libraryMoveOffer = moving
        case "find": state.libraryMoveOffer = .moveIntoContainer(.init(legacy: legacy, library: container, legacyExists: false))
        case "old-copy": state.libraryMoveOffer = .oldCopyRemains(legacy)
        case "moved":
            state.libraryMoveOffer = moving
            state.movedLibrary = MovedLibrary(source: legacy, scoped: false, legacy: legacy)
        case "failed":
            state.libraryMoveOffer = moving
            state.libraryMoveError = AppProblem(title: "Couldn’t Move Your Library", fallback: "Your library couldn’t be moved. Try again.",
                                                error: CocoaError(.fileWriteOutOfSpace))
        default: break
        }
    }
}
#endif
