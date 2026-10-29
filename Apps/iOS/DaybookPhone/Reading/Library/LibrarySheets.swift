import DaybookKit
import SwiftUI

/// The Trash: conversations moved out of the library, with their audio and notes, and Restore.
struct TrashList: View {
    @ObservedObject var library: LibraryController
    let rootURL: URL
    @Environment(ReadingSession.self) private var session
    @State private var trashed: [Meeting] = []

    var body: some View {
        List {
            ForEach(trashed) { meeting in
                HStack(alignment: .center, spacing: PhoneStyle.Space.s3) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(meeting.title.isEmpty ? "Untitled Conversation" : meeting.title)
                            .font(.headline).foregroundStyle(PhoneStyle.Ink.title).lineLimit(1)
                        Text([meeting.date.formatted(date: .abbreviated, time: .shortened), meeting.duration.map(DurationLabel.format)]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(PhoneStyle.Ink.secondary).monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 0)
                    // Restore in sight, as the status sheet's Import is: no instructions needed.
                    Button { restore(meeting.id) } label: {
                        Text("Restore")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(PhoneStyle.Ink.link)
                            .padding(.horizontal, PhoneStyle.Space.s3)
                            .padding(.vertical, 5)
                            .background(PhoneStyle.accent.opacity(0.12), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Restore \(meeting.title.isEmpty ? "Untitled Conversation" : meeting.title)")
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
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .paperBackground()
        .overlay {
            if trashed.isEmpty {
                EmptyPlace(title: "Trash Is Empty", systemImage: "trash")
            }
        }
        .task(id: library.meetings.map(\.id)) { reload() }
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
                session.alert = ReadingAlert(title: "Couldn’t Restore", error: error, fallback: "Try again.")
            }
        }
    }
}

/// Move to Folder: None, each folder, or a new one.
struct MoveSheet: View {
    @ObservedObject var library: LibraryController
    let ids: [UUID]
    private let dismiss = SheetDismiss()
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
            library.moveToFolder(ids, folder)
            finish()
        } label: {
            // Explicit inks: in a list, a button tints its label, and `.primary` would follow that tint.
            SheetChoiceRow(title: name, systemImage: symbol, mark: current == .some(folder) ? .all : .none)
        }
        .accessibilityAddTraits(current == .some(folder) ? .isSelected : [])
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
    private let dismiss = SheetDismiss()
    @Environment(ReadingSession.self) private var session
    @State private var newTag = ""

    private var meetings: [Meeting] { library.meetings.filter { ids.contains($0.id) } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: "tag").foregroundStyle(PhoneStyle.Ink.secondary)
                            .frame(width: 28).accessibilityHidden(true)
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
                                SheetChoiceRow(title: tag, systemImage: "tag", mark: state(tag))
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

    private func state(_ tag: String) -> SheetChoiceRow.Mark {
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

/// A choice in Move or Tags: a neutral symbol, the name in the title ink, and a check when it's
/// chosen (a dash when only some of the conversations have it). The check is the row's only teal.
struct SheetChoiceRow: View {
    enum Mark { case all, some, none }
    let title: String
    let systemImage: String
    let mark: Mark

    var body: some View {
        HStack(spacing: PhoneStyle.Space.s3) {
            Image(systemName: systemImage)
                .foregroundStyle(PhoneStyle.Ink.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(PhoneStyle.Ink.title)
                .frame(maxWidth: .infinity, alignment: .leading)
            switch mark {
            case .all: Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(PhoneStyle.accent).accessibilityHidden(true)
            case .some: Image(systemName: "minus").fontWeight(.semibold).foregroundStyle(PhoneStyle.Ink.secondary).accessibilityHidden(true)
            case .none: EmptyView()
            }
        }
        .contentShape(Rectangle())
    }
}
