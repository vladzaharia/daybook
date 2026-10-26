import DaybookCore
import DaybookKit
import SwiftUI
import UniformTypeIdentifiers

/// Places, the person's folders, and the recorder once it's set up. Nothing else.
struct SidebarView: View {
    @ObservedObject var state: AppState
    @State private var folderToDelete: LibraryFolder?
    @State private var hoveringFolders = false

    var body: some View {
        List(selection: Binding(get: { state.place }, set: { if let place = $0 { select(place) } })) {
            ForEach(LibrarySection.allCases) { section in
                Label(section.rawValue, systemImage: section.systemImage)
                    .tag(LibraryPlace.section(section))
                    .dropDestination(for: String.self) { ids, _ in drop(ids, on: .section(section)) }
            }
            if !state.folders.isEmpty {
                Section {
                    ForEach(state.folders) { folder in
                        FolderRow(state: state, folder: folder)
                            .tag(LibraryPlace.folder(folder.id))
                            .dropDestination(for: String.self) { ids, _ in drop(ids, on: .folder(folder.id)) }
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
            DevicesSidebarSection(state: state)
        }
        .listStyle(.sidebar)
        .labelStyle(.sidebar)
        .contextMenu { Button("New Folder") { state.requestNewFolder() } }
        .dropDestination(for: URL.self) { urls, _ in importAudio(urls) }
        .onChange(of: state.newFolderRequest) { _, request in
            guard let request else { return }
            createFolder(moving: request.moving)
            state.newFolderRequest = nil
        }
        .alert("Delete the folder “\(folderToDelete?.name ?? "")”?", isPresented: Binding(get: { folderToDelete != nil }, set: { if !$0 { folderToDelete = nil } })) {
            Button("Delete Folder", role: .destructive) {
                if let folder = folderToDelete { state.removeFolder(folder.id) }
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
        if !place.isDevice, let selected = state.selectedID, !state.visibleMeetings.contains(where: { $0.id == selected }) {
            state.selectedID = state.visibleMeetings.first?.id
        }
    }

    private func createFolder(moving ids: [UUID]) {
        let names = Set(state.folders.map(\.name))
        var name = "New Folder", number = 2
        while names.contains(name) { name = "New Folder \(number)"; number += 1 }
        let folder = LibraryFolder(name: name)
        state.saveFolder(folder)
        state.moveToFolder(ids, folder.id)
        state.renamingFolderID = folder.id
    }

    private func drop(_ ids: [String], on place: LibraryPlace) -> Bool {
        let meetings = ids.compactMap(UUID.init(uuidString:)).filter { id in state.meetings.contains { $0.id == id } }
        guard !meetings.isEmpty else { return false }
        switch place {
        case .section(.work): state.setPlacement(meetings, .work)
        case .section(.personal): state.setPlacement(meetings, .personal)
        case .folder(let id): state.moveToFolder(meetings, id)
        default: return false
        }
        return true
    }

    private func importAudio(_ urls: [URL]) -> Bool {
        let audio = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .audiovisualContent) == true }
        guard !audio.isEmpty else { return false }
        Task { do { try await state.importFiles(audio, source: .imported, attachTo: nil) } catch { state.errorMessage = error.localizedDescription } }
        return true
    }
}

private struct FolderRow: View {
    @ObservedObject var state: AppState
    let folder: LibraryFolder
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Label {
            if state.renamingFolderID == folder.id {
                TextField("Folder name", text: $draft)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { state.renamingFolderID = nil }
                    .onAppear { draft = folder.name; DispatchQueue.main.async { focused = true } }
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
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty && name != folder.name { state.saveFolder(LibraryFolder(id: folder.id, name: name)) }
        state.renamingFolderID = nil
    }
}

