import DaybookKit
import SwiftUI

/// Your words with their recording times in the lane, then your bookmarks. The notes save as you
/// type, with a Version History entry once typing pauses (`LibraryController.editNotes`).
struct YourNotes: View {
    @ObservedObject var library: LibraryController
    let meeting: Meeting
    let play: (PlaybackTarget) -> Void
    @Environment(ReadingSession.self) private var session

    private var bookmarks: [(highlight: Highlight, time: TimeInterval, context: HighlightContext?)] {
        let contexts = Dictionary(meeting.highlightContexts().map { ($0.highlight.id, $0) }, uniquingKeysWith: { first, _ in first })
        return meeting.highlights
            .map { (highlight: $0, time: meeting.alignedTime(for: $0) ?? $0.time, context: contexts[$0.id]) }
            .sorted { $0.time < $1.time }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let times = meeting.paragraphTimes()
            let timed = times.contains { $0 != nil }
            MarginNotesEditor(
                text: Binding(get: { meeting.notes }, set: { library.editNotes(meeting.id, text: $0) }),
                times: times,
                placeholder: "Add a note…",
                // The lane appears only when a note has a recording time; notes typed while reading have none.
                lane: timed ? PhoneStyle.Page.lane : 0,
                focusOnAppear: session.focusNotesFor == meeting.id,
                playTime: meeting.tracks.isEmpty ? nil : { play(.timeline($0)) },
                onFocusChange: { focused in if focused, session.focusNotesFor == meeting.id { session.focusNotesFor = nil } })
                .padding(.top, PhoneStyle.Space.s2)
                .padding(.leading, timed ? -leadingHang : 0)
            let marks = bookmarks
            if !marks.isEmpty {
                Text("Bookmarks")
                    .font(meeting.summary == nil ? PhoneStyle.Typeface.heading : .subheadline.weight(.semibold))
                    .foregroundStyle(meeting.summary == nil ? PhoneStyle.Ink.body : PhoneStyle.Ink.secondary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, meeting.summary == nil ? PhoneStyle.Space.s6 : PhoneStyle.Space.s4)
                    .id(SummaryBlockID.bookmarks)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(marks, id: \.highlight.id) { mark in
                        BookmarkRow(library: library, meeting: meeting, highlight: mark.highlight, time: mark.time,
                                    context: mark.context, play: play)
                            .transition(.opacity.combined(with: .offset(y: -6)))
                    }
                }
                .padding(.top, PhoneStyle.Space.s2)
                .padding(.leading, -leadingHang)
            }
        }
        .motion(.snappy(duration: 0.3), value: meeting.highlights.count)
    }

    /// Times hang a little into the page's gutter, so the notes' text isn't pushed too far in.
    private var leadingHang: CGFloat { 8 }
}

private struct BookmarkRow: View {
    @ObservedObject var library: LibraryController
    let meeting: Meeting
    let highlight: Highlight
    let time: TimeInterval
    let context: HighlightContext?
    let play: (PlaybackTarget) -> Void
    @State private var expanded = false
    @State private var draft = ""
    @FocusState private var editing: Bool
    @Environment(ReadingSession.self) private var session
    @Environment(\.isTwoPage) private var twoPage

    private var hasSpeech: Bool { context.map { !$0.speechContext.isEmpty } == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LaneRow {
                Image(systemName: "bookmark.fill").font(.caption2).foregroundStyle(PhoneStyle.bookmark)
                    .neonGlow(PhoneStyle.bookmark, radius: 3)
                    .accessibilityHidden(true)
                TimeButton(time: time, play: playFromHere)
            } content: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TextField(placeholder, text: $draft, axis: .vertical)
                        .font(PhoneStyle.Typeface.body)
                        .foregroundStyle(PhoneStyle.Ink.body)
                        .focused($editing)
                        .submitLabel(.done)
                        .onAppear { draft = shownText }
                        .onChange(of: highlight.text) { _, _ in if !editing { draft = shownText } }
                        .onChange(of: draft) { _, value in
                            if value.contains("\n") { draft = value.replacingOccurrences(of: "\n", with: ""); editing = false }
                        }
                        .onChange(of: editing) { _, now in if !now { commit() } }
                        .accessibilityLabel("Bookmark at \(SpokenTime.format(time))")
                    if hasSpeech {
                        Button { withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() } } label: {
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                                .frame(minWidth: 28, minHeight: 28).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(PhoneStyle.Ink.link)
                        .accessibilityLabel(expanded ? "Hide what was said" : "Show what was said")
                    }
                }
            }
            if expanded, let context { quote(context) }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // On two pages, a bookmark shows its moment on the right page.
            if twoPage, let holder = BookmarkMarks.holder(of: highlight, in: meeting) { session.showInTranscript(holder, switchPage: false) }
        }
        .contextMenu {
            Button { playFromHere() } label: { Label("Play from Here", systemImage: "play") }
            if let holder = BookmarkMarks.holder(of: highlight, in: meeting) {
                Button { session.showInTranscript(holder, switchPage: !twoPage) } label: { Label("Show in Transcript", systemImage: "text.quote") }
            }
            if hasSpeech {
                Button { expanded.toggle() } label: { Label(expanded ? "Hide What Was Said" : "Show What Was Said", systemImage: "quote.bubble") }
            }
            Divider()
            Button(role: .destructive) { library.removeBookmark(highlight.id, in: meeting.id) } label: { Label("Delete Bookmark", systemImage: "trash") }
        }
    }

    /// Labels an earlier version wrote automatically read as empty, so the placeholder shows.
    private var shownText: String { BookmarkMarks.automaticLabels.contains(highlight.text) ? "" : highlight.text }

    private var placeholder: String {
        let source = highlight.trackID.flatMap { id in meeting.tracks.first { $0.id == id } }
        return source?.source == .soundcore ? "Bookmark from Soundcore" : "Bookmark"
    }

    private func commit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text != shownText { library.setBookmarkText(highlight.id, text: text, in: meeting.id) }
    }

    private func playFromHere() {
        if let context, !context.isAligned, let track = meeting.tracks.first(where: { $0.id == highlight.trackID }) {
            play(.source(track, highlight.time))
        } else {
            play(.timeline(time))
        }
    }

    private func quote(_ context: HighlightContext) -> some View {
        LaneRow {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(context.speechContext) { segment in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(meeting.speakerName(segment.speakerID) ?? "Unknown speaker")
                                .font(PhoneStyle.Typeface.speaker)
                                .foregroundStyle(PhoneStyle.speakerInk(meeting.speakerIndex(segment.speakerID)))
                            TimeButton(time: segment.start) {
                                if context.isAligned { play(.segment(segment)) }
                                else if let track = meeting.tracks.first(where: { $0.id == highlight.trackID }) { play(.source(track, segment.start)) }
                            }
                        }
                        Text(segment.text).font(.callout).foregroundStyle(PhoneStyle.Ink.body).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if context.isAligned, let first = context.speechContext.first {
                    Button("Open in Transcript") { session.showInTranscript(first.id, switchPage: !twoPage) }
                        .buttonStyle(.daybookLink).font(.subheadline.weight(.medium))
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PhoneStyle.bookmark.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .leading) { Capsule().fill(PhoneStyle.bookmark.opacity(0.7)).frame(width: 2).padding(.vertical, 8) }
        }
        .transition(.opacity)
    }
}
