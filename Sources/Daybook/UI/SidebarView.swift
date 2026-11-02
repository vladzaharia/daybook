import DaybookCore
import DaybookKit
import DaybookUI
import SwiftUI
import UniformTypeIdentifiers

/// Places, the person's folders, the Trash once something is in it, and the recorder once it's set up. Nothing else.
/// Conversations dropped on a place are filed there, a dragged row's whole selection with it (and on the Trash,
/// asked about first); Edit › Undo takes a filing back.
struct SidebarView: View {
    let state: AppState
    @State private var folderToDelete: LibraryFolder?
    @State private var hoveringFolders = false
    @State private var hasTrash = false
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        List(selection: Binding(get: { state.place }, set: { if let place = $0 { select(place) } })) {
            ForEach(LibrarySection.allCases) { section in
                Label(section.rawValue, systemImage: section.systemImage)
                    .tag(LibraryPlace.section(section))
                    .dropDestination(for: ConversationTransfer.self) { items, _ in drop(items, on: .section(section)) }
            }
            if !state.folders.isEmpty {
                Section {
                    ForEach(state.folders) { folder in
                        FolderRow(state: state, folder: folder)
                            .tag(LibraryPlace.folder(folder.id))
                            .dropDestination(for: ConversationTransfer.self) { items, _ in drop(items, on: .folder(folder.id)) }
                            .contextMenu {
                                Button("New Folder") { state.requestNewFolder() }
                                Button("Rename") { state.renamingFolderID = folder.id }
                                Divider()
                                Button("Delete Folder…", role: .destructive) { folderToDelete = folder }
                            }
                    }
                } header: {
                    // "Folders" starts on the icon column's leading edge.
                    HStack {
                        Text("Folders")
                        Spacer()
                        Button { state.requestNewFolder() } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .opacity(hoveringFolders ? 1 : 0)
                            .motion(Motion.hover, value: hoveringFolders)
                            .help("New Folder")
                            .accessibilityLabel("New Folder")
                    }
                    .padding(.leading, 2)
                    .onHover { hoveringFolders = $0 }
                }
            }
            // After the folders, once something is in it (and while it's open).
            if hasTrash || state.place.isTrash {
                Section {
                    Label(LibraryWords.trash, systemImage: "trash")
                        .tag(LibraryPlace.trash)
                        .dropDestination(for: ConversationTransfer.self) { items, _ in drop(items, on: .trash) }
                }
            }
            DevicesSidebarSection(state: state)
        }
        .listStyle(.sidebar)
        .labelStyle(.sidebar)
        .contextMenu { Button("New Folder") { state.requestNewFolder() } }
        .dropDestination(for: URL.self) { urls, _ in importAudio(urls) }
        // Moving to the Trash and restoring change the library's conversations, so its revision.
        .task(id: state.libraryRevision) { hasTrash = await state.library.hasTrashedMeetings() }
        .onChange(of: state.newFolderRequest) { _, request in
            guard let request else { return }
            createFolder(moving: request.moving)
            state.newFolderRequest = nil
        }
        .alert("Delete the folder “\(folderToDelete?.name ?? "")”?", isPresented: Binding(get: { folderToDelete != nil }, set: { if !$0 { folderToDelete = nil } })) {
            Button("Delete Folder", role: .destructive) {
                if let folder = folderToDelete {
                    state.library.removeFolder(folder.id, undoManager: undoManager)
                    if state.place == .folder(folder.id) { state.place = .section(.all) }
                }
                folderToDelete = nil
            }
            Button("Cancel", role: .cancel) { folderToDelete = nil }
        } message: {
            Text(LibraryWords.folderDeletion(conversations: state.meetings.filter { $0.folderID == folderToDelete?.id }.count))
        }
    }

    private func select(_ place: LibraryPlace) {
        guard place != state.place else { return }
        state.place = place
        state.multiSelection = []
        // The Trash selects what it lists itself, once it has read them.
        if !place.isDevice, !place.isTrash, let selected = state.selectedID, !state.visibleMeetings.contains(where: { $0.id == selected }) {
            state.selectedID = state.visibleMeetings.first?.id
        }
    }

    private func createFolder(moving ids: [UUID]) {
        let names = Set(state.folders.map(\.name))
        var name = "New Folder", number = 2
        while names.contains(name) { name = "New Folder \(number)"; number += 1 }
        state.renamingFolderID = state.library.createFolder(named: name, moving: ids, undoManager: undoManager)
    }

    /// Files dropped conversations in a place, one step for Edit › Undo; the Trash asks first. A row dragged from a
    /// selection of several brings the selection along.
    private func drop(_ items: [ConversationTransfer], on place: LibraryPlace) -> Bool {
        let meetings = ConversationDrop.filed(items.map(\.id), selection: state.multiSelection, in: state.meetings)
        guard !meetings.isEmpty else { return false }
        switch place {
        case .section(.work): state.library.setPlacement(meetings, .work, undoManager: undoManager)
        case .section(.personal): state.library.setPlacement(meetings, .personal, undoManager: undoManager)
        case .folder(let id): state.library.moveToFolder(meetings, id, undoManager: undoManager)
        case .trash: state.trashRequestIDs = meetings
        default: return false
        }
        return true
    }

    private func importAudio(_ urls: [URL]) -> Bool {
        let audio = AppState.droppedRecordings(urls)
        guard !audio.isEmpty else { return false }
        Task { do { try await state.importFiles(audio, source: .imported, attachTo: nil) } catch { state.report("Couldn’t Import Audio", "Choose an audio or video file and try again.", error) } }
        return true
    }
}

private struct FolderRow: View {
    let state: AppState
    let folder: LibraryFolder
    @State private var draft = ""
    @FocusState private var focused: Bool
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Label {
            if state.renamingFolderID == folder.id {
                TextField("Folder name", text: $draft)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { state.renamingFolderID = nil }
                    .task { draft = folder.name; focused = true }
                    .onChange(of: focused) { _, active in if !active { commit() } }
            } else {
                Text(folder.name)
            }
        } icon: {
            Image(systemName: "folder")
        }
    }

    private func commit() {
        guard state.renamingFolderID == folder.id else { return }
        state.library.renameFolder(folder.id, to: draft, undoManager: undoManager)
        state.renamingFolderID = nil
    }
}
