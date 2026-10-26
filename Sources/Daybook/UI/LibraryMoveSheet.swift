import SwiftUI

/// Asks before the library moves (`AppState.libraryMoveOffer`, docs/sandbox.md). The library stays closed until the
/// person answers; after a move the app starts over.
struct LibraryMoveSheet: View {
    @ObservedObject var state: AppState
    let offer: LibraryMoveOffer

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Text(title).font(.headline).foregroundStyle(Ink.title)
            Text(message).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = state.libraryMoveError {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Ink.warning)
            }
            HStack(spacing: Space.s2) {
                if state.isMovingLibrary {
                    ProgressView().controlSize(.small)
                    Text("Moving…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Not Now") { Task { await state.declineLibraryMove() } }
                    .keyboardShortcut(.cancelAction)
                Button(action) { state.acceptLibraryMove() }
                    .keyboardShortcut(.defaultAction)
            }
            .disabled(state.isMovingLibrary)
            .padding(.top, Space.s2)
        }
        .padding(Space.s5)
        .frame(width: 440)
        .interactiveDismissDisabled()
    }

    private var title: String {
        switch offer {
        case .returnFromContainer: return "Move your library back?"
        }
    }

    private var message: String {
        switch offer {
        case .returnFromContainer(let plan) where plan.replacesOlder:
            return "A newer Daybook kept a more recent copy of your library. The older copy here is kept beside it."
        case .returnFromContainer:
            return "Your library is where a newer Daybook kept it."
        }
    }

    private var action: String {
        switch offer {
        case .returnFromContainer: return "Move Library Back"
        }
    }
}
