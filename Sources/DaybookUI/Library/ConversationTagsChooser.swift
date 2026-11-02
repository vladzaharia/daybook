import DaybookDesign
import DaybookKit
import SwiftUI

/// Tags for one conversation or several, on both apps (Tags… in a row's menu and a selection's): every tag in the
/// library, checked when all of them have it (a dash when some do), and a field for a new one. Each change can be
/// undone (`setTags(_:text:undoManager:)`).
public struct ConversationTagsChooser: View {
    private let library: LibraryController
    private let ids: [UUID]
    private let done: () -> Void
    @State private var newTag = ""
    @Environment(\.undoManager) private var undoManager

    public init(library: LibraryController, ids: [UUID], done: @escaping () -> Void) {
        self.library = library
        self.ids = ids
        self.done = done
    }

    private var meetings: [Meeting] { library.meetings.filter { ids.contains($0.id) } }

    /// "Tags", or "Tag 3 Conversations".
    public static func title(count: Int) -> String { count == 1 ? "Tags" : "Tag \(count) Conversations" }

    public var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 0) {
            Text(Self.title(count: ids.count))
                .font(.headline)
                .padding([.horizontal, .top], DaybookSpacing.s5)
                .padding(.bottom, DaybookSpacing.s3)
            list.frame(minHeight: 260)
            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
            .padding(DaybookSpacing.s4)
        }
        .frame(width: 360)
        #else
        NavigationStack {
            list
                .navigationTitle(Self.title(count: ids.count))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) } }
        }
        .presentationDetents([.medium, .large])
        #endif
    }

    private var list: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "tag").foregroundStyle(DaybookPalette.Ink.secondary)
                        .frame(width: 28).accessibilityHidden(true)
                    TextField("New Tag", text: $newTag)
                        .onSubmit(addNew)
                        #if os(iOS)
                        .submitLabel(.done)
                        #endif
                    if !newTag.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button("Add", action: addNew).buttonStyle(.daybookLink).fontWeight(.semibold)
                    }
                }
            }
            if !library.allTags.isEmpty {
                Section("Tags") {
                    ForEach(library.allTags, id: \.self) { tag in
                        let mark = Self.mark(tag, in: meetings)
                        Button { toggle(tag) } label: {
                            LibraryChoiceRow(title: tag, systemImage: "tag", mark: mark)
                        }
                        #if os(macOS)
                        .buttonStyle(.plain)
                        #endif
                        .accessibilityValue(mark == .all ? "On" : mark == .some ? "Some" : "Off")
                    }
                }
            }
        }
    }

    /// Whether every one of `meetings` has the tag, some do, or none.
    public static func mark(_ tag: String, in meetings: [Meeting]) -> LibraryChoiceRow.Mark {
        let count = meetings.filter { ($0.tags ?? []).contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }.count
        return count == 0 ? .none : count == meetings.count ? .all : .some
    }

    /// Adds the tag to every conversation, or takes it off all of them when they all have it.
    private func toggle(_ tag: String) {
        let adding = Self.mark(tag, in: meetings) != .all
        for meeting in meetings {
            var tags = (meeting.tags ?? []).filter { $0.caseInsensitiveCompare(tag) != .orderedSame }
            if adding { tags.append(tag) }
            library.setTags(meeting.id, text: tags.joined(separator: ","), undoManager: undoManager)
        }
    }

    private func addNew() {
        // Tags split on commas on both apps, so a comma in a new tag would make two.
        let tag = newTag.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: " ")
        newTag = ""
        guard !tag.isEmpty else { return }
        for meeting in meetings where !(meeting.tags ?? []).contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            library.setTags(meeting.id, text: ((meeting.tags ?? []) + [tag]).joined(separator: ","), undoManager: undoManager)
        }
    }
}

/// A choice in Move to Folder or Tags: a neutral symbol, the name in the title ink, and a check when it's chosen (a
/// dash when only some of the conversations have it). The check is the row's only teal.
public struct LibraryChoiceRow: View {
    public enum Mark: Sendable { case all, some, none }
    private let title: String
    private let systemImage: String
    private let mark: Mark

    public init(title: String, systemImage: String, mark: Mark) {
        self.title = title
        self.systemImage = systemImage
        self.mark = mark
    }

    public var body: some View {
        HStack(spacing: DaybookSpacing.s3) {
            Image(systemName: systemImage)
                .foregroundStyle(DaybookPalette.Ink.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(DaybookPalette.Ink.title)
                .frame(maxWidth: .infinity, alignment: .leading)
            switch mark {
            case .all: Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(DaybookPalette.accent).accessibilityHidden(true)
            case .some: Image(systemName: "minus").fontWeight(.semibold).foregroundStyle(DaybookPalette.Ink.secondary).accessibilityHidden(true)
            case .none: EmptyView()
            }
        }
        .contentShape(Rectangle())
        .accessibilityAddTraits(mark == .all ? .isSelected : [])
    }
}
