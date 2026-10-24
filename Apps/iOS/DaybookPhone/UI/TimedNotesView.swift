import DaybookCore
import SwiftUI

/// Notes while recording: each paragraph with its recording time in the margin, bookmarks in the
/// same lane, and a line at the bottom for the next note. Times come from `NoteTimeline`, exactly
/// as on the Mac: a new paragraph gets the time it was written; editing never moves it.
struct TimedNotesView: View {
    @Environment(PhoneAppModel.self) private var model
    @State private var draft = ""
    @FocusState private var composing: Bool

    private static let lane: CGFloat = 44

    var body: some View {
        let recorder = model.recorder
        let items = NotesTimeline.items(notes: recorder.notes, anchors: recorder.timedNotes, bookmarks: recorder.highlights)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: PhoneStyle.Space.s3) {
                    ForEach(items) { item in
                        row(item)
                    }
                    composer.id("composer")
                }
                .padding(.horizontal, PhoneStyle.Space.s4)
                .padding(.vertical, PhoneStyle.Space.s4)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: items.count) { proxy.scrollTo("composer", anchor: .bottom) }
        }
    }

    @ViewBuilder
    private func row(_ item: NotesTimeline.Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PhoneStyle.Space.s2) {
            Text(item.time.map(TimeLabel.short) ?? "")
                .font(PhoneStyle.Typeface.marginTime)
                .foregroundStyle(item.isBookmark ? PhoneStyle.bookmark : PhoneStyle.Ink.meta)
                .frame(width: Self.lane, alignment: .trailing)
            switch item.kind {
            case .paragraph(let index, let text):
                TextField("", text: Binding(get: { text }, set: { replaceParagraph(index, with: $0) }), axis: .vertical)
                    .font(.body)
                    .foregroundStyle(PhoneStyle.Ink.body)
            case .bookmark:
                Label("Bookmark", systemImage: "bookmark.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(PhoneStyle.bookmark)
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .firstTextBaseline, spacing: PhoneStyle.Space.s2) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(composing || !draft.isEmpty ? TimeLabel.short(model.recorder.elapsedTime) : "")
                    .font(PhoneStyle.Typeface.marginTime)
                    .foregroundStyle(PhoneStyle.Ink.faint)
            }
            .frame(width: Self.lane, alignment: .trailing)
            TextField("Write a note", text: $draft)
                .font(.body)
                .foregroundStyle(PhoneStyle.Ink.body)
                .focused($composing)
                .submitLabel(.return)
                .onSubmit(appendDraft)
        }
    }

    private func appendDraft() {
        let line = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        composing = true
        guard !line.isEmpty else { return }
        let notes = model.recorder.notes
        model.editNotes(notes.isEmpty ? line : notes + "\n" + line)
    }

    private func replaceParagraph(_ index: Int, with text: String) {
        var paragraphs = NotesTimeline.paragraphs(model.recorder.notes)
        guard paragraphs.indices.contains(index) else { return }
        paragraphs[index] = text
        model.editNotes(paragraphs.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n"))
    }
}

/// Paragraphs and bookmarks in reading order, with their times.
enum NotesTimeline {
    struct Item: Identifiable, Equatable {
        enum Kind: Equatable {
            case paragraph(index: Int, text: String)
            case bookmark(UUID)
        }
        var kind: Kind
        var time: TimeInterval?
        var id: String {
            switch kind {
            case .paragraph(let index, _): return "p\(index)"
            case .bookmark(let id): return "b\(id.uuidString)"
            }
        }
        var isBookmark: Bool { if case .bookmark = kind { return true } else { return false } }
    }

    /// Nonempty paragraphs, split the way `NoteTimeline` splits them.
    static func paragraphs(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Paragraphs stay in text order; each bookmark goes before the first paragraph written after it.
    static func items(notes: String, anchors: [TimedNote], bookmarks: [Highlight]) -> [Item] {
        let paragraphs = paragraphs(notes)
        let times = NoteTimeline.paragraphTimes(anchors: anchors, text: notes)
        var items = paragraphs.enumerated().map { index, text in
            Item(kind: .paragraph(index: index, text: text), time: times.indices.contains(index) ? times[index] : nil)
        }
        for mark in bookmarks.sorted(by: { $0.time < $1.time }) {
            let position = items.firstIndex { item in
                guard !item.isBookmark, let time = item.time else { return false }
                return time > mark.time
            } ?? items.endIndex
            items.insert(Item(kind: .bookmark(mark.id), time: mark.time), at: position)
        }
        return items
    }
}
