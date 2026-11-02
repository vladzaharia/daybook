import DaybookKit
import DaybookUI
import SwiftUI

/// The Trash: what was moved out of the library, with its audio and notes, newest first, and Restore in sight, in
/// a row's menu, and on a swipe. The rows are DaybookUI's, the Mac's Trash's too; the list is read from the library
/// (`LibraryController.trashedMeetings()`) whenever its conversations change. On two pages, as on the Mac, the right
/// page shows one of them read only (`TrashedPage`): the newest, or the one tapped.
struct TrashList: View {
    let library: LibraryController
    var twoPage = false
    @Environment(ReadingSession.self) private var session
    @State private var trashed: [Meeting] = []
    @State private var loaded = false

    var body: some View {
        List {
            ForEach(trashed) { meeting in
                TrashRowView(meeting: meeting, restore: { restore(meeting.id) },
                             show: twoPage ? { session.trashedID = meeting.id } : nil)
                    .pageRowInsets(twoPage: twoPage)
                    .listRowBackground(PageRowBackground(shown: twoPage && session.trashedID == meeting.id))
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button { restore(meeting.id) } label: { Label(TrashWords.restore, systemImage: TrashWords.restoreSymbol) }
                            .tint(PhoneStyle.prominentFill)
                    }
                    .contextMenu {
                        Button { restore(meeting.id) } label: { Label(TrashWords.restore, systemImage: TrashWords.restoreSymbol) }
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .paperBackground()
        .overlay {
            if loaded && trashed.isEmpty, let words = LibraryWords.emptyPlace(.trash, libraryIsEmpty: library.meetings.isEmpty, platform: .iPhone) {
                LibraryEmptyPlaceView(words)
            }
        }
        // Moving to the Trash and restoring change the library's conversations, so its revision.
        .task(id: library.revision) {
            let read = await library.trashedMeetings()
            guard !Task.isCancelled else { return }
            trashed = read
            loaded = true
            if twoPage { session.showInTrash(from: read) }
        }
    }

    private func restore(_ id: UUID) {
        Self.restore(id, library: library, session: session)
    }

    /// Puts a conversation back in the library, or says it couldn't.
    static func restore(_ id: UUID, library: LibraryController, session: ReadingSession) {
        Task {
            do {
                try await library.restoreFromTrash(id)
            } catch {
                session.alert = ReadingAlert(title: "Couldn’t Restore", error: error, fallback: "Try again.")
            }
        }
    }
}

/// The right page beside the Trash on two pages: the conversation shown there, read only, with Restore (DaybookUI's
/// `TrashedConversationPage`, the Mac's page beside its Trash); paper while there's none.
struct TrashedPage: View {
    let library: LibraryController
    let id: UUID?
    @Environment(ReadingSession.self) private var session
    @State private var meeting: Meeting?

    var body: some View {
        ZStack {
            if let meeting {
                TrashedConversationPage(meeting: meeting) { TrashList.restore(meeting.id, library: library, session: session) }
            } else {
                PhoneStyle.paper.ignoresSafeArea()
            }
        }
        // Restoring it changes the library's revision; it's gone from the Trash then.
        .task(id: [id, library.revision] as [AnyHashable?]) {
            guard let id else { meeting = nil; return }
            let read = await library.trashedMeeting(id)
            guard !Task.isCancelled else { return }
            meeting = read
        }
    }
}

/// Move to Folder: None, each folder, or a new one. Edit › Undo (a shake) takes it back.
struct MoveSheet: View {
    let library: LibraryController
    let ids: [UUID]
    private let dismiss = SheetDismiss()
    @Environment(ReadingSession.self) private var session
    @Environment(\.undoManager) private var undoManager
    @State private var newFolder = ""
    @FocusState private var naming: Bool

    private var current: UUID?? {
        let folders = Set(library.meetings.filter { ids.contains($0.id) }.map(\.folderID))
        return folders.count == 1 ? folders.first : nil
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("No Folder", symbol: "tray", folder: nil)
                    ForEach(library.folders) { folder in row(folder.name, symbol: "folder", folder: folder.id) }
                }
                Section("New Folder") {
                    HStack {
                        Image(systemName: "folder.badge.plus").foregroundStyle(PhoneStyle.Ink.secondary)
                            .frame(width: 28).accessibilityHidden(true)
                        TextField("Name", text: $newFolder)
                            .focused($naming)
                            .submitLabel(.done)
                            .onSubmit(createFolder)
                        if !newFolder.trimmingCharacters(in: .whitespaces).isEmpty {
                            Button("Create", action: createFolder).buttonStyle(.daybookLink).fontWeight(.semibold)
                        }
                    }
                }
            }
            .navigationTitle(ids.count == 1 ? "Move to Folder" : "Move \(ids.count) Conversations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ name: String, symbol: String, folder: UUID?) -> some View {
        Button {
            library.moveToFolder(ids, folder, undoManager: undoManager)
            finish()
        } label: {
            // Explicit inks: in a list, a button tints its label, and `.primary` would follow that tint.
            LibraryChoiceRow(title: name, systemImage: symbol, mark: current == .some(folder) ? .all : .none)
        }
    }

    private func createFolder() {
        let name = newFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        library.createFolder(named: name, moving: ids, undoManager: undoManager)
        finish()
    }

    private func finish() {
        if session.isSelecting { session.isSelecting = false; session.selection = [] }
        dismiss()
    }
}

/// Tags for one conversation or several: DaybookUI's chooser, which the Mac's Tags… shows too.
struct TagsSheet: View {
    let library: LibraryController
    let ids: [UUID]
    private let dismiss = SheetDismiss()
    @Environment(ReadingSession.self) private var session

    var body: some View {
        ConversationTagsChooser(library: library, ids: ids) {
            if session.isSelecting { session.isSelecting = false; session.selection = [] }
            dismiss()
        }
    }
}
