import DaybookCore
import DaybookKit
import SwiftUI

/// The default page: what happened, what's next, the template's sections, then your own notes.
struct SummaryPage: View {
    @ObservedObject var state: AppState
    @ObservedObject var player: AudioPlaybackController
    let meeting: Meeting
    let play: (PlaybackTarget) -> Void
    /// The summary present when the page opened. Any later one arrived while the page was on screen,
    /// so it's revealed block by block; opening a page never animates.
    @State private var openedWith: Date?

    init(state: AppState, player: AudioPlaybackController, meeting: Meeting, play: @escaping (PlaybackTarget) -> Void) {
        self.state = state; self.player = player; self.meeting = meeting; self.play = play
        _openedWith = State(initialValue: meeting.summary?.createdAt)
    }

    var body: some View {
        PageScroll(bottomInset: player.meetingID == meeting.id && player.duration > 0 ? 56 : 0) {
            PageHeader(state: state, player: player, meeting: meeting, play: play)
            ConversationStatus(state: state, meeting: meeting)
            if let summary = meeting.summary {
                SummaryBody(state: state, meeting: meeting, summary: summary, revealing: summary.createdAt != openedWith)
                    .id(summary.createdAt)
                    // Summarize Again: the old summary steps back while the new one is written.
                    .opacity(meeting.status == .summarizing ? 0.5 : 1)
                    .transition(.opacity)
            } else if meeting.tracks.isEmpty && state.recordingID != meeting.id {
                MarginRow {
                    HStack(spacing: Space.s4) {
                        Text("No audio yet.").foregroundStyle(Ink.secondary)
                        Button("Start Recording") { Task { await state.startRecording(into: meeting.id) } }
                            .disabled(state.isRecording || state.isStartingRecording)
                        Button("Add Recording…") { state.chooseImport(attachTo: meeting.id) }
                    }
                    .buttonStyle(.daybookLink)
                    .font(TypeStyle.status)
                }
                .padding(.top, Space.s4)
            }
            YourNotes(state: state, meeting: meeting, play: play)
                .padding(.top, meeting.summary == nil ? Space.s5 : Space.s2)
            // Every photo, in the order taken; the summary's sections show the ones they illustrate.
            PhotoStrip(state: state, meeting: meeting)
            // Tentative captions while recording and until the transcript exists; after the notes,
            // so arriving words never move what you're typing.
            LiveCaptionsSection(captions: state.captions, meeting: meeting, isRecording: state.recordingID == meeting.id)
            // How the page was made, once there is a page; never while recording.
            if meeting.summary != nil && state.recordingID != meeting.id {
                Colophon(state: state, meeting: meeting)
            }
        }
        .environment(\.findQuery, state.search)
        .motion(Motion.page, value: meeting.summary?.createdAt)
        .motion(Motion.state, value: meeting.status == .summarizing)
    }
}

/// Reveals a block of a newly arrived summary a moment after the one before it.
private struct Arrival: ViewModifier {
    let index: Int
    let revealing: Bool
    let shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        if revealing {
            content
                .opacity(shown ? 1 : 0)
                .offset(y: shown || reduceMotion ? 0 : 8)
                .animation(reduceMotion ? .easeOut(duration: 0.15) : Motion.page.delay(Double(min(index, 5)) * 0.04), value: shown)
        } else {
            content
        }
    }
}

/// The summary itself: lede, next steps, and the template's sections, ending at the "Your notes" heading.
private struct SummaryBody: View {
    @ObservedObject var state: AppState
    let meeting: Meeting
    let summary: MeetingSummary
    var revealing = false
    @State private var shown = false
    @Environment(\.readingScale) private var scale
    @Environment(\.findQuery) private var query

    private var sections: [SummarySection] {
        summary.sections.filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        let offset = summary.actionItems.isEmpty ? 1 : 2
        VStack(alignment: .leading, spacing: 0) {
            MarginRow {
                Text(FindHighlight.mark(AttributedString(summary.overview), query: query))
                    .font(TypeStyle.lede(scale))
                    .foregroundStyle(Ink.body)
                    .lineSpacing(5 * scale)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, Space.s5)
            .modifier(Arrival(index: 0, revealing: revealing, shown: shown))
            if !summary.actionItems.isEmpty {
                nextSteps(summary.actionItems)
                    .modifier(Arrival(index: 1, revealing: revealing, shown: shown))
            }
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                VStack(alignment: .leading, spacing: 0) {
                    heading(section.heading)
                    MarginRow { MarkdownText(source: section.body).foregroundStyle(Ink.body) }
                        .padding(.top, Space.s2)
                    let pictures = meeting.photos(in: section)
                    if !pictures.isEmpty { SectionPhotos(state: state, meeting: meeting, photos: pictures) }
                }
                .modifier(Arrival(index: offset + index, revealing: revealing, shown: shown))
            }
            heading("Your notes")
        }
        .onAppear { if revealing { shown = true } }
    }

    /// Lede → first heading (32) is clearly more than title → lede (24); weight, not grey, makes the heading.
    private func heading(_ text: String) -> some View {
        MarginRow { Text(text).font(TypeStyle.heading(scale)).foregroundStyle(Ink.body).accessibilityAddTraits(.isHeader) }
            .padding(.top, Space.s6)
    }

    private func nextSteps(_ items: [ActionItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("Next steps")
            VStack(alignment: .leading, spacing: Space.s2) {
                ForEach(items) { item in
                    MarginRow {
                        Toggle(isOn: Binding(get: { item.completed }, set: { done in
                            state.update(meeting.id) { value in
                                guard let index = value.summary?.actionItems.firstIndex(where: { $0.id == item.id }) else { return }
                                value.summary?.actionItems[index].completed = done
                            }
                        })) {
                            HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                                Text(MarkdownText.inline(item.text, highlighting: query))
                                    .strikethrough(item.completed, color: Ink.meta)
                                    .foregroundStyle(item.completed ? Ink.secondary : Ink.body)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .layoutPriority(1)
                                if let owner = item.owner, !owner.isEmpty {
                                    // A finished list isn't confetti: done rows keep the name, not the chip.
                                    OwnerChip(name: owner, ink: ownerInk(owner), filled: !item.completed).opacity(item.completed ? 0.5 : 1)
                                }
                                Spacer(minLength: 0)
                            }
                            .font(TypeStyle.body(scale))
                            .motion(.easeOut(duration: 0.2), value: item.completed)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .padding(.top, Space.s2)
        }
    }

    /// An owner who spoke takes their speaker colour, tying them to the transcript and inspector.
    private func ownerInk(_ owner: String) -> Color? {
        meeting.speakers.firstIndex { $0.name.caseInsensitiveCompare(owner) == .orderedSame }.map(DaybookStyle.speakerInk)
    }
}

private struct OwnerChip: View {
    let name: String
    let ink: Color?
    var filled = true
    @Environment(\.readingScale) private var scale
    var body: some View {
        Text(name)
            .font(.system(size: 11 * scale, weight: .semibold))
            .foregroundStyle(ink ?? Ink.secondary)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background((ink ?? .clear).opacity(filled ? 0.14 : 0), in: Capsule())
            .background(ink == nil && filled ? DaybookStyle.quietFill : .clear, in: Capsule())
            .fixedSize()
    }
}

/// Your words with their recording times, then your bookmarks.
struct YourNotes: View {
    @ObservedObject var state: AppState
    let meeting: Meeting
    let play: (PlaybackTarget) -> Void
    @Environment(\.readingScale) private var scale
    @Environment(\.pageIsNarrow) private var narrow

    private var isRecording: Bool { state.recordingID == meeting.id }

    /// Each non-empty paragraph's time, matched to the saved anchors by text; nil where there is none.
    private var times: [TimeInterval?] { meeting.paragraphTimes() }

    private var bookmarks: [(highlight: Highlight, time: TimeInterval, context: HighlightContext?)] {
        let contexts = Dictionary(meeting.highlightContexts().map { ($0.highlight.id, $0) }, uniquingKeysWith: { first, _ in first })
        return meeting.highlights
            .map { (highlight: $0, time: meeting.alignedTime(for: $0) ?? $0.time, context: contexts[$0.id]) }
            .sorted { $0.time < $1.time }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MarginNotesEditor(
                text: Binding(get: { meeting.notes }, set: { state.editNotes(meeting.id, text: $0) }),
                times: times,
                placeholder: "Add a note…",
                fontSize: 14 * scale, lineSpacing: 5 * scale,
                margin: narrow ? 0 : DaybookStyle.margin,
                focusOnAppear: isRecording && meeting.notes.isEmpty,
                playTime: state.isRecording ? nil : { play(.timeline($0)) })
            if !bookmarks.isEmpty {
                if meeting.summary == nil {
                    MarginRow { Text("Bookmarks").font(TypeStyle.heading(scale)).foregroundStyle(Ink.body).accessibilityAddTraits(.isHeader) }
                        .padding(.top, Space.s6).padding(.bottom, Space.s1)
                } else {
                    // A subheading explains why the bookmarks' times start again after the notes.
                    MarginRow {
                        Text("Bookmarks").font(.system(size: 12 * scale, weight: .semibold)).foregroundStyle(Ink.secondary)
                            .accessibilityAddTraits(.isHeader)
                    }
                    .padding(.top, Space.s3)
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(bookmarks, id: \.highlight.id) { bookmark in
                        BookmarkRow(state: state, meeting: meeting, highlight: bookmark.highlight, time: bookmark.time, context: bookmark.context, play: play)
                            .transition(.opacity.combined(with: .offset(y: -6)))
                    }
                }
                .padding(.top, Space.s2)
            }
        }
        .padding(.bottom, Space.s2)
        .contentShape(Rectangle())
        .motion(.snappy(duration: 0.3), value: meeting.highlights.count)
    }
}

private struct BookmarkRow: View {
    @ObservedObject var state: AppState
    let meeting: Meeting
    let highlight: Highlight
    let time: TimeInterval
    let context: HighlightContext?
    let play: (PlaybackTarget) -> Void
    @State private var expanded = false
    @State private var hovering = false
    @FocusState private var editing: Bool
    @Environment(\.readingScale) private var scale

    /// Labels the earlier version wrote automatically read as empty, so the placeholder shows.
    private var label: Binding<String> {
        Binding(get: { ["Marked moment", "Marked during review"].contains(highlight.text) ? "" : highlight.text }, set: { text in
            state.update(meeting.id) { value in
                if let index = value.highlights.firstIndex(where: { $0.id == highlight.id }) { value.highlights[index].text = text }
            }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MarginRow {
                Image(systemName: "bookmark.fill").font(.system(size: 9 * scale)).foregroundStyle(DaybookStyle.bookmark)
                    .neonGlow(DaybookStyle.bookmark, radius: 3)
                    .frame(width: 8)
                    .accessibilityHidden(true)
                MarginTime(time: time, play: playFromHere)
            } content: {
                HStack(alignment: .firstTextBaseline) {
                    TextField(highlight.trackID.flatMap { id in meeting.tracks.first { $0.id == id }?.source == .soundcore ? "Bookmark from Soundcore" : nil } ?? "Bookmark",
                              text: label)
                        .textFieldStyle(.plain)
                        .font(TypeStyle.body(scale))
                        .foregroundStyle(Ink.body)
                        .focused($editing)
                    if context.map({ !$0.speechContext.isEmpty }) == true {
                        Button { withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() } } label: {
                            HStack(spacing: 4) {
                                Text(expanded ? "Hide What Was Said" : "Show What Was Said")
                                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                                    .rotationEffect(.degrees(expanded ? 90 : 0))
                            }
                        }
                        .buttonStyle(.daybookLink)
                        .font(TypeStyle.status)
                        .opacity(hovering || editing || expanded ? 1 : 0)
                        .animation(Motion.hover, value: hovering)
                    }
                }
            }
            if expanded, let context { quote(context) }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Play from Here", action: playFromHere)
            if context.map({ !$0.speechContext.isEmpty }) == true { Button(expanded ? "Hide What Was Said" : "Show What Was Said") { expanded.toggle() } }
            Divider()
            Button("Delete Bookmark", role: .destructive) { state.update(meeting.id) { $0.highlights.removeAll { $0.id == highlight.id } } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bookmark at \(SpokenTime.format(time))")
    }

    private func playFromHere() {
        if let context, !context.isAligned, let track = meeting.tracks.first(where: { $0.id == highlight.trackID }) { play(.source(track, highlight.time)) }
        else { play(.timeline(time)) }
    }

    private func quote(_ context: HighlightContext) -> some View {
        MarginRow {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(context.speechContext) { segment in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(meeting.speakerName(segment.speakerID) ?? "Unknown speaker")
                                .font(TypeStyle.speaker(scale))
                                .foregroundStyle(DaybookStyle.speakerInk(meeting.speakerIndex(segment.speakerID)))
                            Button(TimeLabel.short(segment.start)) {
                                if context.isAligned { play(.segment(segment)) }
                                else if let track = meeting.tracks.first(where: { $0.id == highlight.trackID }) { play(.source(track, segment.start)) }
                            }
                            .buttonStyle(.plain).font(TypeStyle.margin(scale)).foregroundStyle(Ink.meta)
                        }
                        Text(segment.text).font(TypeStyle.body(scale)).foregroundStyle(Ink.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if context.isAligned, let first = context.speechContext.first {
                    HStack {
                        Spacer()
                        Button("Open in Transcript") { state.pageScrollTarget = first.id; state.pageMode = .transcript }
                            .buttonStyle(.daybookLink).font(TypeStyle.status)
                    }
                }
            }
            .padding(12)
            .background(DaybookStyle.bookmark.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .leading) { Capsule().fill(DaybookStyle.bookmark.opacity(0.7)).frame(width: 2).padding(.vertical, 6) }
        }
        .transition(.opacity)
    }
}
