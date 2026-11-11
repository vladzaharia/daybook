import DaybookDesign
import DaybookKit
import SwiftUI

/// Your own words on the page, the same on both apps: the notes (each app's notes editor, with their recording times
/// in the margin), then your bookmarks, each with its time, a label you can type, and what was said around it.
public struct YourNotes<Editor: View>: View {
    private let meeting: Meeting
    private let library: LibraryController
    private let canPlay: Bool
    private let play: (PlaybackTarget) -> Void
    private let passages: PassageLinks
    private let bookmarksID: String?
    private let editor: Editor

    /// - Parameters:
    ///   - canPlay: Its times play: it has audio, and this device isn't recording it.
    ///   - bookmarksID: The bookmarks' scroll ID, for an app that scrolls to them.
    ///   - editor: The app's notes editor.
    public init(meeting: Meeting, library: LibraryController, canPlay: Bool, play: @escaping (PlaybackTarget) -> Void,
                passages: PassageLinks = .none, bookmarksID: String? = nil, @ViewBuilder editor: () -> Editor) {
        self.meeting = meeting
        self.library = library
        self.canPlay = canPlay
        self.play = play
        self.passages = passages
        self.bookmarksID = bookmarksID
        self.editor = editor()
    }

    private var bookmarks: [(highlight: Highlight, time: TimeInterval, context: HighlightContext?)] {
        let contexts = Dictionary(meeting.highlightContexts().map { ($0.highlight.id, $0) }, uniquingKeysWith: { first, _ in first })
        return meeting.presentHighlights
            .map { (highlight: $0, time: meeting.alignedTime(for: $0) ?? $0.time, context: contexts[$0.id]) }
            .sorted { $0.time < $1.time }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            editor
            let marks = bookmarks
            if !marks.isEmpty {
                MarginRow {
                    // Under a summary a subheading says why the times start again after the notes.
                    if meeting.summary == nil {
                        Text("Bookmarks").daybookFont(.heading).foregroundStyle(DaybookPalette.Ink.body)
                    } else {
                        Text("Bookmarks").daybookFont(.status).fontWeight(.semibold).foregroundStyle(DaybookPalette.Ink.secondary)
                    }
                }
                .accessibilityAddTraits(.isHeader)
                .padding(.top, meeting.summary == nil ? DaybookSpacing.s6 : DaybookSpacing.s4)
                .blockID(bookmarksID)
                VStack(alignment: .leading, spacing: DaybookSpacing.s1) {
                    ForEach(marks, id: \.highlight.id) { mark in
                        BookmarkRow(highlight: mark.highlight, time: mark.time, context: mark.context, meeting: meeting, library: library,
                                    canPlay: canPlay, play: play, passages: passages)
                            .daybookTransition(.opacity.combined(with: .offset(y: -6)))
                    }
                }
                .padding(.top, DaybookSpacing.s2)
            }
        }
        .padding(.bottom, DaybookSpacing.s2)
        .daybookMotion(DaybookMotion.state, value: meeting.presentHighlights.map(\.id))
    }
}

/// What a bookmark's label shows, the same on both apps: labels an earlier version wrote by itself read as none, so
/// the placeholder shows; a typed one is saved once editing ends, trimmed.
public enum BookmarkLabel {
    /// A bookmark with no words of its own, in placeholder ink: its row in the summary, and the notes' line after the
    /// last paragraph when one sits there (`NoteParagraphs.isWordless`).
    public static let untitled = "Bookmark"

    /// The label as the field shows it.
    public static func shown(_ text: String) -> String {
        BookmarkMarks.automaticLabels.contains(text) ? "" : text
    }

    /// What to save for `draft`, or nil when nothing changed.
    public static func committed(draft: String, stored: String) -> String? {
        let text = draft.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return text == shown(stored) ? nil : text
    }

    /// "Bookmark", or "Bookmark from Soundcore" for one a Soundcore button made.
    public static func placeholder(for highlight: Highlight, in meeting: Meeting) -> String {
        let source = highlight.trackID.flatMap { id in meeting.tracks.first { $0.id == id } }
        return source?.source == .soundcore ? "\(untitled) from Soundcore" : untitled
    }
}

/// One bookmark: the amber glyph and its time in the margin (the glyphs in one column, beside their times), the label
/// on the time's baseline whether or not it has words yet, and the chevron that opens what was said. Its menu plays from
/// it, shows it in the transcript, and deletes it, which can be undone.
struct BookmarkRow: View {
    let highlight: Highlight
    let time: TimeInterval
    let context: HighlightContext?
    let meeting: Meeting
    let library: LibraryController
    let canPlay: Bool
    let play: (PlaybackTarget) -> Void
    let passages: PassageLinks
    @State private var expanded = false
    @State private var hovering = false
    @State private var draft = ""
    @FocusState private var editing: Bool
    @Environment(\.undoManager) private var undoManager
    @Environment(\.daybookDensity) private var density
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasSpeech: Bool { context.map { !$0.speechContext.isEmpty } == true }
    private var holder: UUID? { BookmarkMarks.holder(of: highlight, in: meeting) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MarginRow {
                BookmarkMargin(time: time, canPlay: canPlay, play: playFromHere)
            } content: {
                HStack(alignment: .firstTextBaseline, spacing: DaybookSpacing.s2) {
                    label
                    if hasSpeech { disclosure }
                }
            }
            if expanded, let context { quote(context) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            // With the transcript beside the page, a bookmark shows its moment there.
            if passages.onTap, !editing, let holder { passages.show(holder) }
        }
        .contextMenu {
            if canPlay { Button { playFromHere() } label: { Label("Play from Here", systemImage: "play") } }
            if let holder { Button { passages.show(holder) } label: { Label("Show in Transcript", systemImage: "text.quote") } }
            if hasSpeech {
                Button { toggle() } label: { Label(expanded ? "Hide What Was Said" : "Show What Was Said", systemImage: "quote.bubble") }
            }
            Divider()
            Button(role: .destructive) { delete() } label: { Label("Delete Bookmark", systemImage: "trash") }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bookmark at \(SpokenTime.format(time))")
    }

    /// The label, on the time's first baseline: an invisible copy of the words (or the placeholder) gives the row its
    /// baseline and height, and the field sits over it, so an empty label never drops below its time.
    private var label: some View {
        let placeholder = BookmarkLabel.placeholder(for: highlight, in: meeting)
        return Text(draft.isEmpty ? placeholder : draft)
            .daybookFont(.body)
            .foregroundStyle(.clear)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(true)
            .overlay(alignment: .topLeading) {
                TextField(placeholder, text: draftBinding, axis: .vertical)
                    .daybookFont(.body)
                    .foregroundStyle(DaybookPalette.Ink.body)
                    .textFieldStyle(.plain)
                    .focused($editing)
                    .touchKeyboard(submit: .done)
                    .onSubmit { editing = false }
                    .accessibilityLabel("Bookmark at \(SpokenTime.format(time))")
            }
            .onAppear { draft = BookmarkLabel.shown(highlight.text) }
            .onChange(of: highlight.text) { _, text in if !editing { draft = BookmarkLabel.shown(text) } }
            .onChange(of: editing) { _, now in if !now { commit() } }
            .onDisappear { if editing { commit() } }
    }

    private var draftBinding: Binding<String> {
        Binding(get: { draft }, set: { value in
            if value.contains("\n") {
                draft = value.replacingOccurrences(of: "\n", with: "")
                editing = false
            } else {
                draft = value
            }
        })
    }

    /// The chevron on both apps; in a window, "Show What Was Said" beside it while the pointer is over the row.
    private var disclosure: some View {
        Button(action: toggle) {
            HStack(spacing: DaybookSpacing.s1) {
                if density != .touch && (hovering || editing || expanded) {
                    Text(expanded ? "Hide What Was Said" : "Show What Was Said").daybookFont(.status)
                }
                Image(systemName: "chevron.right")
                    .font(density == .touch ? .caption.weight(.semibold) : .system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(minWidth: density == .touch ? 28 : 12, minHeight: density == .touch ? 28 : 12)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.daybookLink)
        .accessibilityLabel(expanded ? "Hide what was said" : "Show what was said")
    }

    private func toggle() {
        withAnimation(DaybookMotion.resolved(DaybookMotion.state, reduceMotion: reduceMotion)) { expanded.toggle() }
    }

    private func commit() {
        guard let text = BookmarkLabel.committed(draft: draft, stored: highlight.text) else {
            draft = BookmarkLabel.shown(highlight.text)
            return
        }
        draft = text
        library.setBookmarkText(highlight.id, text: text, in: meeting.id, undoManager: undoManager)
    }

    private func delete() {
        library.removeBookmark(highlight.id, in: meeting.id, undoManager: undoManager)
    }

    private func playFromHere() {
        if let context, !context.isAligned, let track = meeting.tracks.first(where: { $0.id == highlight.trackID }) {
            play(.source(track, highlight.time))
        } else {
            play(.timeline(time))
        }
    }

    private func quote(_ context: HighlightContext) -> some View {
        MarginRow {
            VStack(alignment: .leading, spacing: density == .touch ? 10 : DaybookSpacing.s2) {
                ForEach(context.speechContext) { segment in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(meeting.speakerName(segment.speakerID) ?? "Unknown speaker")
                                .daybookFont(.speaker)
                                .foregroundStyle(DaybookPalette.speakerInk(meeting.speakerIndex(segment.speakerID)))
                            Button {
                                if context.isAligned { play(.segment(segment)) }
                                else if let track = meeting.tracks.first(where: { $0.id == highlight.trackID }) { play(.source(track, segment.start)) }
                            } label: {
                                QuietLink(rest: DaybookPalette.Ink.meta) { Text(TimeLabel.short(segment.start)).daybookFont(.marginTime) }
                                    .daybookHitTarget()
                            }
                            .buttonStyle(.plain)
                            .disabled(!canPlay)
                            .accessibilityLabel("Play from \(SpokenTime.format(segment.start))")
                        }
                        Text(segment.text)
                            .daybookFont(.body)
                            .foregroundStyle(DaybookPalette.Ink.body)
                            .fixedSize(horizontal: false, vertical: true)
                            .selectableInWindow()
                    }
                }
                if context.isAligned, let first = context.speechContext.first {
                    Button("Open in Transcript") { passages.show(first.id) }
                        .buttonStyle(.daybookLink)
                        .daybookFont(.status)
                        .fontWeight(.medium)
                }
            }
            .padding(DaybookSpacing.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DaybookPalette.bookmark.opacity(0.08), in: DaybookRadius.shape(DaybookRadius.box))
            .overlay(alignment: .leading) {
                Capsule().fill(DaybookPalette.bookmark.opacity(0.7)).frame(width: 2).padding(.vertical, DaybookSpacing.s2)
            }
        }
        .daybookTransition(.opacity)
    }
}

/// A bookmark's margin: its glyph in a column of its own and its time, right-aligned in a slot as wide as "00:00", so
/// every glyph in the list lines up whatever the time's width.
struct BookmarkMargin: View {
    let time: TimeInterval
    let canPlay: Bool
    let play: () -> Void
    @Environment(\.daybookDensity) private var density
    @Environment(\.readingScale) private var scale
    /// "00:00" in the margin's monospaced digits, growing with Dynamic Type under touch.
    @ScaledMetric(relativeTo: .caption2) private var touchSlot: CGFloat = 31

    /// "00:00" at the window's 12 pt margin time.
    private var slot: CGFloat { density == .touch ? touchSlot : 34 * scale }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: density == .touch ? 3 : DaybookSpacing.s1) {
            Image(systemName: "bookmark.fill")
                .font(density == .touch ? .caption2 : .system(size: 9 * scale))
                .foregroundStyle(DaybookPalette.bookmark)
                .daybookGlow(DaybookPalette.bookmark, radius: 3)
                .accessibilityHidden(true)
            Button(action: play) {
                QuietLink(rest: DaybookPalette.Ink.meta, touch: DaybookPalette.Ink.meta) { Text(TimeLabel.short(time)) }
                    .frame(minWidth: slot, alignment: .trailing)
                .daybookFont(.marginTime)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .daybookHitTarget()
            }
            .buttonStyle(.plain)
            .disabled(!canPlay)
            .help("Play from here")
            .accessibilityLabel("Play from \(SpokenTime.format(time))")
        }
    }
}
