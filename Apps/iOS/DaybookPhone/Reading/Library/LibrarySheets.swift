import DaybookKit
import SwiftUI

/// The Trash: conversations moved out of the library, with their audio and notes, and Restore.
struct TrashList: View {
    @ObservedObject var library: LibraryController
    let rootURL: URL
    @State private var trashed: [Meeting] = []
    @State private var restoreError: String?

    var body: some View {
        List {
            Section {
                ForEach(trashed) { meeting in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(meeting.title.isEmpty ? "Untitled Conversation" : meeting.title).font(.headline).lineLimit(1)
                        Text([meeting.date.formatted(date: .abbreviated, time: .shortened), meeting.duration.map(DurationLabel.format)]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(PhoneStyle.paper)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button { restore(meeting.id) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                            .tint(PhoneStyle.prominentFill)
                    }
                    .contextMenu {
                        Button { restore(meeting.id) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                    }
                    .accessibilityAction(named: "Restore") { restore(meeting.id) }
                }
            } footer: {
                if !trashed.isEmpty {
                    Text("Swipe right to restore a conversation.")
                        .font(.footnote).foregroundStyle(PhoneStyle.Ink.meta)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .paperBackground()
        .overlay {
            if trashed.isEmpty {
                ContentUnavailableView("Trash Is Empty", systemImage: "trash")
            }
        }
        .task(id: library.meetings.map(\.id)) { reload() }
        .alert("Couldn’t Restore", isPresented: Binding(get: { restoreError != nil }, set: { if !$0 { restoreError = nil } })) {
            Button("OK", role: .cancel) { }
        } message: { Text(restoreError ?? "") }
    }

    private func reload() {
        trashed = TrashedConversations.load(rootURL: rootURL, ids: library.trashedMeetingIDs())
    }

    private func restore(_ id: UUID) {
        Task {
            do {
                try await library.restoreFromTrash(id)
                reload()
            } catch {
                restoreError = error.localizedDescription
            }
        }
    }
}

/// Move to Folder: None, each folder, or a new one.
struct MoveSheet: View {
    @ObservedObject var library: LibraryController
    let ids: [UUID]
    @Environment(\.dismiss) private var dismiss
    @Environment(ReadingSession.self) private var session
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
                        Image(systemName: "folder.badge.plus").foregroundStyle(PhoneStyle.accent)
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
            library.moveToFolder(ids, folder)
            finish()
        } label: {
            HStack {
                Label(name, systemImage: symbol).foregroundStyle(.primary)
                Spacer()
                if current == .some(folder) { Image(systemName: "checkmark").foregroundStyle(PhoneStyle.accent).fontWeight(.semibold) }
            }
        }
    }

    private func createFolder() {
        let name = newFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        library.createFolder(named: name, moving: ids)
        finish()
    }

    private func finish() {
        if session.isSelecting { session.isSelecting = false; session.selection = [] }
        dismiss()
    }
}

/// Tags for one conversation or several: every tag in the library with a check when all of them
/// have it (a dash when some do), and a field for a new one.
struct TagsSheet: View {
    @ObservedObject var library: LibraryController
    let ids: [UUID]
    @Environment(\.dismiss) private var dismiss
    @Environment(ReadingSession.self) private var session
    @State private var newTag = ""

    private var meetings: [Meeting] { library.meetings.filter { ids.contains($0.id) } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: "tag").foregroundStyle(PhoneStyle.accent)
                        TextField("New Tag", text: $newTag).submitLabel(.done).onSubmit(addNew)
                        if !newTag.trimmingCharacters(in: .whitespaces).isEmpty {
                            Button("Add", action: addNew).buttonStyle(.daybookLink).fontWeight(.semibold)
                        }
                    }
                }
                if !library.allTags.isEmpty {
                    Section("Tags") {
                        ForEach(library.allTags, id: \.self) { tag in
                            Button { toggle(tag) } label: {
                                HStack {
                                    TagChip(tag: tag)
                                    Spacer()
                                    switch state(tag) {
                                    case .all: Image(systemName: "checkmark").foregroundStyle(PhoneStyle.accent).fontWeight(.semibold)
                                    case .some: Image(systemName: "minus").foregroundStyle(.secondary)
                                    case .none: EmptyView()
                                    }
                                }
                            }
                            .accessibilityValue(state(tag) == .all ? "On" : state(tag) == .some ? "Some" : "Off")
                        }
                    }
                }
            }
            .navigationTitle(ids.count == 1 ? "Tags" : "Tag \(ids.count) Conversations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { finish() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private enum Coverage { case all, some, none }

    private func state(_ tag: String) -> Coverage {
        let count = meetings.filter { ($0.tags ?? []).contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }.count
        return count == 0 ? .none : count == meetings.count ? .all : .some
    }

    private func toggle(_ tag: String) {
        let adding = state(tag) != .all
        for meeting in meetings {
            var tags = (meeting.tags ?? []).filter { $0.caseInsensitiveCompare(tag) != .orderedSame }
            if adding { tags.append(tag) }
            library.setTags(meeting.id, text: tags.joined(separator: ","))
        }
    }

    private func addNew() {
        let tag = newTag.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: " ")
        newTag = ""
        guard !tag.isEmpty else { return }
        for meeting in meetings where !(meeting.tags ?? []).contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            library.setTags(meeting.id, text: ((meeting.tags ?? []) + [tag]).joined(separator: ","))
        }
    }

    private func finish() {
        if session.isSelecting { session.isSelecting = false; session.selection = [] }
        dismiss()
    }
}
