import DaybookCaptions
import DaybookKit
import SwiftUI

/// The conversation as a page: the title, one byline, the processing status when there's
/// something to say, then what happened (the lede), the next steps, the template's sections, your
/// notes with their recording times, your bookmarks, and how the page was made.
///
/// A conversation that isn't transcribed yet is a complete page too: title, byline, a calm status
/// line, your notes, and your bookmarks; everything but the summary works.
struct SummaryPage: View {
    @ObservedObject var library: LibraryController
    let meeting: Meeting
    /// The page shows its own title and byline (one column, and the notebook's left page).
    var showsHeader = true
    /// The scroll edge effect under what sits at the page's foot: hard under the notebook's status
    /// panel, so the page doesn't read through its glass; nil is the system's.
    var bottomEdgeEffect: ScrollEdgeEffectStyle? = nil
    @Environment(ReadingSession.self) private var session
    @Environment(\.audioProvider) private var provider
    @Environment(\.macSighting) private var sightingOverride
    @Environment(\.summaryPlacement) private var placement
    @Environment(\.isTwoPage) private var twoPage
    @State private var consumedToken = 0
    /// The status line's symbol column (`StatusView`).
    @ScaledMetric(relativeTo: .subheadline) private var statusGlyph: CGFloat = 20
    @Environment(\.liveCaptionStore) private var captionStore
    /// Saved live captions take the transcript's page, which then doesn't say "Not transcribed yet".
    @State private var hasCaptions = false

    var body: some View {
        @Bindable var session = session
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if showsHeader {
                        PageHeader(library: library, meeting: meeting, play: play).id(SummaryBlockID.header)
                    }
                    if let status, status.countdownUntil != nil {
                        // A summary's countdown: its seconds move.
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            StatusView(presentation: self.status(at: context.date) ?? status, perform: perform)
                        }
                        .padding(.top, PhoneStyle.Space.s4).id("status")
                    } else if let status, !(twoPage && isRecordedOnly && !hasCaptions) {
                        StatusView(presentation: status, perform: perform).padding(.top, PhoneStyle.Space.s4).id("status")
                    } else if meeting.tracks.isEmpty && !twoPage {
                        // Only notes so far. Two pages show this on the transcript's page. Record sits at
                        // the line's end, or under it when the words need the room.
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .center, spacing: PhoneStyle.Space.s2) {
                                noRecordingLine.fixedSize()
                                Spacer(minLength: PhoneStyle.Space.s3)
                                RecordIntoButton(meeting: meeting).fixedSize()
                            }
                            VStack(alignment: .leading, spacing: PhoneStyle.Space.s2) {
                                noRecordingLine
                                RecordIntoButton(meeting: meeting)
                                    .padding(.leading, min(statusGlyph, 32) + PhoneStyle.Space.s2)
                            }
                        }
                        .padding(.top, PhoneStyle.Space.s4)
                        .id("status")
                    }
                    if let summary = meeting.summary {
                        SummaryBody(library: library, meeting: meeting, summary: summary, play: play)
                            .opacity(isResummarizing ? 0.5 : 1)
                    }
                    YourNotes(library: library, meeting: meeting, play: play)
                        .padding(.top, meeting.summary == nil ? PhoneStyle.Space.s5 : 0)
                        .id(meeting.summary == nil ? SummaryBlockID.notes : "notes-body")
                    PhotoStrip(meeting: meeting)
                    if meeting.summary != nil {
                        Colophon(library: library, meeting: meeting).id(SummaryBlockID.colophon)
                    }
                }
                .scrollTargetLayout()
                .pageColumn()
                .padding(.top, PhoneStyle.Space.s3)
                .padding(.bottom, PhoneStyle.Space.s8)
            }
            .scrollPosition(id: $session.summaryAnchor, anchor: .top)
            .scrollDismissesKeyboard(.interactively)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectStyle(bottomEdgeEffect, for: .bottom)
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { session.pageMode = .summary }
            }
            .onAppear { handleRequest(proxy) }
            .onChange(of: session.summaryRequest) { _, _ in handleRequest(proxy) }
        }
        .paperBackground()
        .task(id: "\(meeting.id)-\(meeting.showsLiveCaptions)") {
            hasCaptions = SavedCaptions.shown(captionStore?.captions(for: meeting.id), for: meeting) != nil
        }
        .motion(PhoneStyle.Motion.page, value: meeting.summary?.createdAt)
        .motion(PhoneStyle.Motion.state, value: status)
    }

    /// "No recording yet" in the status line's symbol column, so it reads as one of them.
    private var noRecordingLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: PhoneStyle.Space.s2) {
            Image(systemName: "note.text").foregroundStyle(PhoneStyle.Ink.secondary)
                .frame(width: min(statusGlyph, 32)).accessibilityHidden(true)
            Text("No recording yet").font(PhoneStyle.Typeface.status).foregroundStyle(PhoneStyle.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func handleRequest(_ proxy: ScrollViewProxy) {
        guard let request = session.summaryRequest, request.token != consumedToken else { return }
        consumedToken = request.token
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(request.target, anchor: .top) }
        }
    }

    private var status: StatusPresentation? { status(at: Date()) }

    /// Where its summary runs first, when that's what there is to say (`PhoneSummaryPlacement`), then the processing status.
    private func status(at now: Date) -> StatusPresentation? {
        let sighting = sightingOverride ?? MacSighting.latest(in: library.meetings, excluding: library.thisDevice.id)
        let processing = ProcessingStatus.phone(meeting, now: now)
        if let placement, let placing = StatusPresentation.placement(placement.planners[meeting.id], run: placement.runs[meeting.id],
                                                                      live: placement.live(meeting.id), status: processing,
                                                                      cloudOffered: placement.cloudOffer != nil, sighting: sighting, now: now) {
            return placing
        }
        return StatusPresentation.page(processing, meeting: meeting, sighting: sighting, pause: PhoneProcessor.current?.pause)
    }

    /// Recorded and nothing asked yet: two pages say so on the transcript's page, with Transcribe.
    private var isRecordedOnly: Bool {
        if case .recorded = ProcessingStatus.phone(meeting) { return true }
        return false
    }

    /// Summarize Again: the old summary steps back while the new one is written.
    private var isResummarizing: Bool {
        if case .processing(let progress) = ProcessingStatus.phone(meeting), progress.stage == .summarizing { return true }
        return false
    }

    private func play(_ target: PlaybackTarget) {
        session.player.play(target, in: meeting, provider: provider)
    }

    private func perform(_ action: StatusPresentation.Action) {
        switch action {
        case .request(.summaryOnly): library.summarize(meeting.id, placement: placement)
        case .request(let mode): library.requestProcessing(meeting.id, mode: mode)
        case .details(let text): session.sheet = .details(text)
        case .dismiss: library.update(meeting.id) { $0.errorMessage = nil }
        case .placement(let choice): placement?.perform(choice, for: meeting.id)
        case .stopSummary: placement?.stop(meeting.id)
        }
    }
}

// MARK: - Header

/// Title and one byline: the same on both pages, so switching feels like turning the page.
struct PageHeader: View {
    @ObservedObject var library: LibraryController
    let meeting: Meeting
    let play: (PlaybackTarget) -> Void
    @Environment(ReadingSession.self) private var session
    @State private var draft = ""
    @FocusState private var editingTitle: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Untitled Conversation", text: titleBinding, axis: .vertical)
                .font(PhoneStyle.Typeface.docTitle)
                .foregroundStyle(PhoneStyle.Ink.title)
                // A long title shows whole; it never stops mid-phrase inside the field.
                .lineLimit(1...12)
                .focused($editingTitle)
                .submitLabel(.done)
                .accessibilityLabel("Title")
                .onChange(of: editingTitle) { _, editing in if !editing { commitTitle() } }
                .onAppear { draft = meeting.title }
                .onChange(of: meeting.title) { _, title in if !editingTitle { draft = title } }
            byline
        }
    }

    /// Return ends the title instead of starting a second line.
    private var titleBinding: Binding<String> {
        Binding(get: { draft }, set: { value in
            if value.contains("\n") {
                draft = value.replacingOccurrences(of: "\n", with: "")
                editingTitle = false
            } else {
                draft = value
            }
        })
    }

    private func commitTitle() {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { draft = meeting.title; return }
        if title != meeting.title { library.rename(meeting.id, to: title) }
    }

    /// The length (a play pill) and the date, then the people on their own line. A conversation
    /// without a recording says so once, in its status line, not here too.
    private var byline: some View {
        VStack(alignment: .leading, spacing: 4) {
            FlowLayout(spacing: 8, lineSpacing: 4) {
                if let duration = meeting.duration {
                    PlayPill(player: session.player, meeting: meeting, duration: duration) { play(.timeline(0)) }
                }
                Text(meeting.date.formatted(.dateTime.weekday(.abbreviated).day().month(.wide).hour().minute()))
                    .foregroundStyle(PhoneStyle.Ink.secondary)
            }
            if let people = meeting.peopleLine {
                Button { session.sheet = .info(meeting.id) } label: {
                    Text(people).foregroundStyle(PhoneStyle.Ink.secondary).multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the people in this conversation")
            }
        }
        .font(PhoneStyle.Typeface.byline)
    }
}

// MARK: - Summary

/// Lede, next steps, and the template's sections, ending at "Your notes".
private struct SummaryBody: View {
    @ObservedObject var library: LibraryController
    let meeting: Meeting
    let summary: MeetingSummary
    let play: (PlaybackTarget) -> Void
    @Environment(\.findQuery) private var query

    private var sections: [SummarySection] {
        summary.sections.filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        let evidence = EvidenceIndex.cached(for: meeting)
        VStack(alignment: .leading, spacing: 0) {
            EvidenceLink(text: summary.overview, evidence: evidence.segment(for: summary.overview)) {
                Text(FindHighlight.mark(SummaryLine.inline(summary.overview), query: query))
                    .font(PhoneStyle.Typeface.lede)
                    .foregroundStyle(PhoneStyle.Ink.body)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, PhoneStyle.Space.s5)
            .id(SummaryBlockID.lede)
            if !summary.actionItems.isEmpty {
                VStack(alignment: .leading, spacing: PhoneStyle.Space.s3) {
                    PageHeading(text: "Next steps")
                    ForEach(summary.actionItems) { item in
                        NextStepRow(library: library, meeting: meeting, item: item,
                                    evidence: evidence.segment(for: item.text, owner: item.owner))
                    }
                }
                .padding(.top, PhoneStyle.Space.s6)
                .id(SummaryBlockID.nextSteps)
            }
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: PhoneStyle.Space.s2) {
                    PageHeading(text: section.heading)
                    SectionBody(source: section.body, evidence: evidence)
                    ForEach(meeting.photos(in: section)) { PhotoTile(meeting: meeting, photo: $0, large: true) }
                }
                .padding(.top, PhoneStyle.Space.s6)
                .id(SummaryBlockID.section(section.id))
            }
            PageHeading(text: "Your notes").padding(.top, PhoneStyle.Space.s6).id(SummaryBlockID.notes)
        }
    }
}

/// A summary block that leads to its evidence in the transcript. On two pages a tap scrolls the
/// right page there; in one column the link is in the block's menu, so reading never jumps away.
struct EvidenceLink<Content: View>: View {
    let text: String
    let evidence: UUID?
    @ViewBuilder var content: Content
    @Environment(ReadingSession.self) private var session
    @Environment(\.isTwoPage) private var twoPage

    var body: some View {
        if let evidence {
            content
                .contentShape(Rectangle())
                .onTapGesture { if twoPage { session.showInTranscript(evidence, switchPage: false) } }
                .contextMenu {
                    Button { session.showInTranscript(evidence, switchPage: !twoPage) } label: {
                        Label("Show in Transcript", systemImage: "text.quote")
                    }
                    Button { LocalPasteboard.copy(text) } label: { Label("Copy", systemImage: "doc.on.doc") }
                }
                .accessibilityAction(named: "Show in Transcript") { session.showInTranscript(evidence, switchPage: !twoPage) }
        } else {
            content
        }
    }
}

private struct NextStepRow: View {
    @ObservedObject var library: LibraryController
    let meeting: Meeting
    let item: ActionItem
    let evidence: UUID?
    @Environment(ReadingSession.self) private var session
    @Environment(\.isTwoPage) private var twoPage
    @Environment(\.findQuery) private var query

    /// An owner who spoke takes their speaker ink, tying them to the transcript.
    private var ownerInk: Color? {
        guard let owner = item.owner else { return nil }
        return meeting.speakers.firstIndex { $0.name.caseInsensitiveCompare(owner) == .orderedSame }.map(PhoneStyle.speakerInk)
    }

    private var stepText: some View {
        Text(FindHighlight.mark(SummaryLine.inline(item.text), query: query))
            .font(PhoneStyle.Typeface.body)
            .strikethrough(item.completed, color: PhoneStyle.Ink.meta)
            .foregroundStyle(item.completed ? PhoneStyle.Ink.secondary : PhoneStyle.Ink.body)
    }

    @ViewBuilder private var owner: some View {
        if let owner = item.owner, !owner.isEmpty {
            OwnerChip(name: owner, ink: ownerInk, filled: !item.completed).opacity(item.completed ? 0.6 : 1)
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                library.setNextStep(item.id, completed: !item.completed, in: meeting.id)
            } label: {
                Image(systemName: item.completed ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.completed ? PhoneStyle.accent : PhoneStyle.Ink.meta)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(minWidth: 28, minHeight: 28)
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.selection, trigger: item.completed)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
            EvidenceLink(text: item.text, evidence: evidence) {
                // The owner sits beside a short step, and under a long one.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        stepText.fixedSize()
                        owner
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        stepText.fixedSize(horizontal: false, vertical: true)
                        owner
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let evidence, let segment = meeting.unifiedTranscript.first(where: { $0.id == evidence }) {
                Button { session.showInTranscript(evidence, switchPage: !twoPage) } label: {
                    Text(TimeLabel.short(segment.start))
                        .font(PhoneStyle.Typeface.time)
                        .foregroundStyle(PhoneStyle.Ink.meta)
                        .padding(.vertical, 4).padding(.leading, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Said at \(SpokenTime.format(segment.start))")
                .accessibilityHint("Shows it in the transcript")
            }
        }
        .motion(.easeOut(duration: 0.2), value: item.completed)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(item.completed ? "Done" : "Not done")
        .accessibilityAction { library.setNextStep(item.id, completed: !item.completed, in: meeting.id) }
    }
}

/// A section's Markdown: paragraphs, bullets (teal dots), numbered items, and subheadings.
private struct SectionBody: View {
    let source: String
    let evidence: EvidenceIndex
    @Environment(\.findQuery) private var query

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(SummaryLine.lines(source).enumerated()), id: \.offset) { _, line in
                EvidenceLink(text: line.text, evidence: evidence.segment(for: line.text)) {
                    switch line {
                    case .paragraph(let text):
                        Text(FindHighlight.mark(SummaryLine.inline(text), query: query))
                            .lineSpacing(PhoneStyle.Typeface.bodyLineSpacing)
                    case .heading(let text):
                        Text(SummaryLine.inline(text)).font(PhoneStyle.Typeface.heading)
                    case .item(let marker, let text):
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Group {
                                if marker == "•" {
                                    Circle().fill(PhoneStyle.accent.opacity(0.75)).frame(width: 6, height: 6)
                                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                                } else {
                                    Text(marker).monospacedDigit().foregroundStyle(PhoneStyle.Ink.secondary)
                                }
                            }
                            .frame(width: 20, alignment: .leading)
                            .accessibilityHidden(true)
                            Text(FindHighlight.mark(SummaryLine.inline(text), query: query))
                                .lineSpacing(PhoneStyle.Typeface.bodyLineSpacing)
                        }
                    }
                }
                .font(PhoneStyle.Typeface.body)
                .foregroundStyle(PhoneStyle.Ink.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Colophon

/// How the page was made, at its foot: a fact that doubles as the privacy line, the template, and
/// Summarize Again (a request your Mac carries out).
private struct Colophon: View {
    @ObservedObject var library: LibraryController
    let meeting: Meeting
    @Environment(\.summaryPlacement) private var placement

    var body: some View {
        VStack(alignment: .leading, spacing: PhoneStyle.Space.s2) {
            Rectangle().fill(PhoneStyle.Ink.faint).frame(width: 24, height: 1).padding(.bottom, PhoneStyle.Space.s1)
                .accessibilityHidden(true)
            if let summary = meeting.summary {
                Label {
                    // Where it ran: "Summarized on your Mac", "Summarized on this iPhone", "Summarized with Claude Sonnet 5.5".
                    Text("\(summary.origin.colophon(thisDeviceID: library.thisDevice.id, thisDevice: PhoneSummaryPlacement.thisDeviceWords, unknown: "your Mac")) · \(summary.createdAt.formatted(.dateTime.day().month(.abbreviated).hour().minute()))")
                } icon: {
                    Image(systemName: summary.origin.cloudModel != nil ? "cloud" : summary.origin.deviceID == library.thisDevice.id ? "iphone" : "laptopcomputer")
                        .symbolEffect(.bounce, value: summary.createdAt)
                }
                .labelStyle(CompactLabelStyle())
            }
            HStack(spacing: 4) {
                Text("Template:")
                TemplateMenu(library: library, meeting: meeting) {
                    HStack(spacing: 3) {
                        Text(templateTitle).fontWeight(.medium)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(PhoneStyle.Ink.link)
                }
                // Only while it can be asked for: a pending request already shows on the page.
                if !meeting.unifiedTranscript.isEmpty && !isPending {
                    Text("·").accessibilityHidden(true)
                    Button("Summarize Again") { library.summarize(meeting.id, placement: placement) }
                        .buttonStyle(.daybookLink)
                        .fontWeight(.medium)
                }
            }
        }
        .font(PhoneStyle.Typeface.colophon)
        .foregroundStyle(PhoneStyle.Ink.meta)
        .padding(.top, PhoneStyle.Space.s7)
    }

    private var isPending: Bool { ProcessingStatus.phone(meeting).isPending }

    private var templateTitle: String {
        if let template = library.resolvedTemplate(for: meeting) { return template.name }
        if let kind = meeting.summary?.kind, kind != .auto { return "Automatic (\(kind.title))" }
        return "Automatic"
    }
}

/// The template picker: Automatic (with its guess), then the built-in and your own templates.
/// Choosing another one asks your Mac to summarize again; the old summary stays in Version History.
struct TemplateMenu<Label: View>: View {
    @ObservedObject var library: LibraryController
    let meeting: Meeting
    @ViewBuilder var label: Label
    @Environment(\.summaryPlacement) private var placement

    var body: some View {
        Menu {
            Picker("Template", selection: Binding(get: { library.templateSelection(for: meeting.id) }, set: choose)) {
                Text(automaticTitle).tag("auto")
                Divider()
                ForEach(library.templates.filter(\.isBuiltIn)) { Text($0.name).tag($0.id) }
                let custom = library.templates.filter { !$0.isBuiltIn }
                if !custom.isEmpty {
                    Divider()
                    ForEach(custom) { Text($0.name).tag($0.id) }
                }
            }
        } label: { label }
        .accessibilityLabel("Template")
    }

    private var automaticTitle: String {
        guard let kind = meeting.summary?.kind, kind != .auto else { return "Automatic" }
        return "Automatic (\(kind.title))"
    }

    private func choose(_ id: String) {
        guard library.chooseTemplate(id, for: meeting.id), !meeting.unifiedTranscript.isEmpty else { return }
        library.summarize(meeting.id, templateID: id == "auto" ? nil : id, placement: placement)
    }
}
