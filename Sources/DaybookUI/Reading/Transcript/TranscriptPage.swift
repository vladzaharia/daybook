import DaybookDesign
import DaybookKit
import SwiftUI

/// The evidence behind the page, the same on the Mac and the iPhone: who said what, in speaker ink, with your notes,
/// photos, and bookmarks at their times (docs/interface.md, "Geometry"). Its rows lay out by the page's width: times
/// hang in the margin on a regular page and sit beside a turn's speaker on a narrow one. A click or tap plays from a
/// passage; a double-click, Return, ⌘E, or Correct Passage… corrects it, in place on a regular page and in a sheet on
/// a narrow one. Playback follows along until the person scrolls away, when Back to Playing appears.
///
/// The page doesn't read the player in its body, whose position moves ten times a second: it follows it apart
/// (`ObservationWatch`) and redraws when the passage under the playhead changes. Rows, bookmark marks, and the playhead
/// index are worked out once per version of the conversation (`TranscriptLayout`).
public struct TranscriptPage<Header: View, Placeholder: View>: View {
    private let meeting: Meeting
    private let host: TranscriptHost
    private let findQuery: String
    private let find: ConversationFind?
    private let scrollRequest: TranscriptScrollRequest?
    private let scrolled: (() -> Void)?
    private let anchor: Binding<String?>?
    private let playerInset: CGFloat
    private let header: Header
    private let placeholder: Placeholder

    @State private var playing: UUID?
    @State private var isPlaying = false
    @State private var playerShown = false
    @State private var correcting: CorrectionRequest?
    @State private var lastUserScroll = Date.distantPast
    @State private var followSuspended = false
    @State private var consumedToken: Int?
    @State private var flashed: String?
    @State private var flashToken = 0
    @State private var editing: UUID?
    @State private var draft = ""
    @State private var renaming: RenameRequest?
    @State private var heardIn: UUID?
    @FocusState private var focusedRow: String?
    @Namespace private var rotorSpace
    /// The page's own width, which sets its rows' layout (`ReadingPage` tells the rows; the page reads it here).
    @State private var width: CGFloat = 1000
    private var readingWidth: ReadingWidth { ReadingWidth(width: width) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.undoManager) private var undoManager

    /// - Parameters:
    ///   - findQuery: The library search's text, marked wherever it matches.
    ///   - find: Find in Conversation's bar and keys, when the app offers it.
    ///   - scrollRequest: Where to go: each new token moves the page once.
    ///   - scrolled: Called once the page went where `scrollRequest` asked, for an app that clears its request.
    ///   - anchor: The top row's ID, kept by the app so the page reopens where it was left.
    ///   - playerInset: Room under the last row while the player floats over the page.
    ///   - header: The title, byline, and status above the rows.
    ///   - placeholder: What shows in the transcript's place before there is one.
    public init(meeting: Meeting, host: TranscriptHost, findQuery: String = "", find: ConversationFind? = nil,
                scrollRequest: TranscriptScrollRequest? = nil, scrolled: (() -> Void)? = nil, anchor: Binding<String?>? = nil,
                playerInset: CGFloat = 0, @ViewBuilder header: () -> Header, @ViewBuilder placeholder: () -> Placeholder) {
        self.meeting = meeting
        self.host = host
        self.findQuery = findQuery
        self.find = find
        self.scrollRequest = scrollRequest
        self.scrolled = scrolled
        self.anchor = anchor
        self.playerInset = playerInset
        self.header = header()
        self.placeholder = placeholder()
    }

    public var body: some View {
        let page = TranscriptPageLayout.cached(for: meeting)
        let layout = page.layout
        let rows = page.rows
        let corrected = page.corrected
        let turnStarts = page.turnStarts
        let highlight = find.map { $0.highlight.isEmpty ? findQuery : $0.highlight } ?? findQuery
        let current = find?.isShown == true ? find?.matches.currentID : nil
        ScrollViewReader { proxy in
            TranscriptColumn(bottomInset: playerShown ? playerInset : 0) {
                header
                TranscriptNotices(meeting: meeting, host: host)
                if meeting.unifiedTranscript.isEmpty { placeholder }
                ForEach(rows) { row in
                    rowView(row, layout: layout, turnStarts: turnStarts, corrected: corrected, highlight: highlight, current: current)
                        .id(row.id)
                        .accessibilityRotorEntry(id: row.id, in: rotorSpace)
                }
            }
            .modifier(AnchorPosition(anchor: anchor))
            .onScrollPhaseChange { _, phase in
                guard phase == .interacting || phase == .decelerating else { return }
                lastUserScroll = Date()
                host.didScroll()
                if isPlaying { followSuspended = true }
            }
            .overlay(alignment: readingWidth == .regular ? .topTrailing : .top) {
                if followSuspended && isPlaying, let playing {
                    BackToPlaying {
                        lastUserScroll = .distantPast
                        followSuspended = false
                        scroll(proxy, to: playing.uuidString)
                    }
                    .padding(.top, DaybookSpacing.s3)
                    .padding(.trailing, readingWidth == .regular ? DaybookSpacing.s4 : 0)
                    .daybookTransition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .daybookMotion(DaybookMotion.state, value: followSuspended)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .modifier(TranscriptRotors(rotors: page.rotors, namespace: rotorSpace))
            .conversationFindBar(find)
            .conversationFindKeys(find)
            .onAppear { follow(scrollRequest, proxy) }
            .onChange(of: scrollRequest) { _, request in
                // A request the app cleared can be made again for the same row.
                if request == nil { consumedToken = nil }
                follow(request, proxy)
            }
            .onChange(of: find?.stepToken) { _, _ in
                if let id = find?.matches.currentID { scroll(proxy, to: id, anchor: UnitPoint(x: 0.5, y: 0.3)) }
            }
            .onChange(of: playing) { _, id in
                // Follow playback only while the person isn't reading elsewhere.
                guard let id, isPlaying else { return }
                if Date().timeIntervalSince(lastUserScroll) > 5 { followSuspended = false }
                guard !followSuspended else { return }
                scroll(proxy, to: id.uuidString)
            }
        }
        // Again for each version of the conversation, which the playhead's passages come from.
        .task(id: meeting) {
            followPlayhead()
            let host = self.host
            let watch = ObservationWatch({ _ = host.playhead() }) { followPlayhead() }
            await watch.followWhileRunning()
        }
        .onChange(of: meeting.id, initial: true) { _, id in find?.use(rows, in: id) }
        .onChange(of: rows) { _, rows in find?.use(rows, in: meeting.id) }
        #if DEBUG
        .task(id: meeting.id) { await applyLaunchArguments() }
        #endif
        // Correct Passage on a narrow page, where the app shows no sheet of its own for it.
        .sheet(item: $correcting) { request in
            CorrectPassageSheet(library: host.library, meetingID: meeting.id, segmentID: request.id)
        }
        // A jump's wash fades on its own; a newer jump or leaving the page cancels the wait.
        .task(id: flashToken) {
            guard flashed != nil, (try? await Task.sleep(for: .seconds(1.8))) != nil else { return }
            withAnimation(DaybookMotion.resolved(DaybookMotion.fade, reduceMotion: reduceMotion)) { flashed = nil }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func rowView(_ row: TranscriptRow, layout: TranscriptLayout, turnStarts: Set<UUID>, corrected: Set<UUID>,
                         highlight: String, current: String?) -> some View {
        switch row {
        case .turn(let speakerID, let first):
            TurnHeaderRow(meeting: meeting, rowID: row.id, speakerID: speakerID, first: first, actions: actions)
                .padding(.top, DaybookSpacing.s5)
                .padding(.bottom, 2)
                .modifier(RenamePopover(row: row.id, request: $renaming, meeting: meeting, save: rename))
        case .passage(let segment):
            if editing == segment.id {
                InlinePassageEditor(text: $draft) { saveCorrection(segment.id) } cancel: { editing = nil; focusedRow = segment.id.uuidString }
            } else {
                PassageRow(meeting: meeting, segment: segment, opensTurn: turnStarts.contains(segment.id), isPlaying: playing == segment.id,
                           emphasized: flashed == row.id || current == row.id,
                           bookmarks: layout.marks.bookmarksBySegment[segment.id] ?? [],
                           label: layout.marks.labelSegments[segment.id], corrected: corrected.contains(segment.id),
                           highlight: highlight, actions: actions, focus: $focusedRow)
                    .modifier(RenamePopover(row: row.id, request: $renaming, meeting: meeting, save: rename))
                    .popover(isPresented: Binding(get: { heardIn == segment.id }, set: { if !$0 { heardIn = nil } }),
                             arrowEdge: .bottom) {
                        HeardInRecordings(meeting: meeting, segment: segment, recordingName: { host.recordingName($0, meeting) },
                                          play: host.play)
                    }
            }
        case .note(let note):
            NoteRow(note: note, highlight: highlight, emphasized: flashed == row.id || current == row.id, actions: actions,
                    focus: $focusedRow)
                .padding(.top, DaybookSpacing.s3)
        case .photo(let photo, let time):
            TranscriptPhotoRow(meeting: meeting, photo: photo, time: time, services: host.photos, highlight: highlight)
                .background(DaybookPalette.accent.opacity(flashed == row.id || current == row.id ? 0.14 : 0),
                            in: DaybookRadius.shape(DaybookRadius.row))
                .padding(.top, DaybookSpacing.s3)
        }
    }

    private var actions: TranscriptRowActions {
        TranscriptRowActions(
            play: host.play,
            canPlay: host.canPlay(),
            correct: correct,
            rename: { speakerID, anchor in renaming = RenameRequest(speakerID: speakerID, anchor: anchor) },
            bookmark: { TranscriptEdits.bookmark($0, in: meeting.id, library: host.library) },
            showHeardIn: { heardIn = $0.id },
            showNotes: host.showNotes,
            move: moveFocus)
    }

    // MARK: Editing

    private func correct(_ segment: TranscriptSegment) {
        if readingWidth == .regular {
            draft = segment.text
            editing = segment.id
        } else {
            if !host.present(.correct(segmentID: segment.id)) { correcting = CorrectionRequest(id: segment.id) }
        }
    }

    private func saveCorrection(_ id: UUID) {
        TranscriptEdits.correct(id, text: draft, in: meeting.id, library: host.library, undoManager: undoManager)
        editing = nil
        focusedRow = id.uuidString
    }

    private func rename(_ speakerID: String, _ name: String) {
        TranscriptEdits.rename(speakerID, to: name, in: meeting.id, library: host.library, undoManager: undoManager)
    }

    /// ↑ and ↓ move between passages.
    private func moveFocus(from id: String, by delta: Int) {
        let passages = TranscriptPageLayout.cached(for: meeting).passageIDs
        guard let index = passages.firstIndex(of: id), passages.indices.contains(index + delta) else { return }
        focusedRow = passages[index + delta]
    }

    // MARK: Scrolling

    private func follow(_ request: TranscriptScrollRequest?, _ proxy: ScrollViewProxy) {
        guard let request, request.token != consumedToken else { return }
        consumedToken = request.token
        // The rows exist on the next turn of the main queue, once the page has laid out.
        Task { @MainActor in
            scroll(proxy, to: request.target, anchor: UnitPoint(x: 0.5, y: 0.3))
            if request.flash {
                flashed = request.target
                flashToken += 1
            }
            scrolled?()
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to id: String, anchor: UnitPoint = UnitPoint(x: 0.5, y: 0.33)) {
        // Under Reduce Motion the page jumps.
        withAnimation(DaybookMotion.scrollAnimation(reduceMotion: reduceMotion)) { proxy.scrollTo(id, anchor: anchor) }
    }

    #if DEBUG
    /// Debug builds, for screenshots: `--find "<words>"` opens Find in Conversation with them, and `--correct "<words>"`
    /// corrects the first passage holding them (in place on a regular page, a sheet on a narrow one). Once per launch.
    private func applyLaunchArguments() async {
        guard !TranscriptLaunch.applied else { return }
        TranscriptLaunch.applied = true
        let arguments = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        guard value("--find") != nil || value("--correct") != nil else { return }
        try? await Task.sleep(for: .milliseconds(400))
        if let query = value("--find"), let find {
            find.query = query
            find.show()
        }
        if let words = value("--correct"), let segment = meeting.unifiedTranscript.first(where: { $0.text.localizedCaseInsensitiveContains(words) }) {
            correct(segment)
        }
    }
    #endif

    /// The passage under the playhead, in the recording that is playing; state changes only when it does.
    private func followPlayhead() {
        let playhead = host.playhead()
        let id = playhead.flatMap { TranscriptLayout.cached(for: meeting).playhead.segmentID(at: $0.position, trackID: $0.trackID) }
        if id != playing { playing = id }
        let now = playhead?.isPlaying ?? false
        if now != isPlaying { isPlaying = now }
        if (playhead != nil) != playerShown { playerShown = playhead != nil }
    }
}

extension TranscriptPage where Placeholder == EmptyView {
    public init(meeting: Meeting, host: TranscriptHost, findQuery: String = "", find: ConversationFind? = nil,
                scrollRequest: TranscriptScrollRequest? = nil, scrolled: (() -> Void)? = nil, anchor: Binding<String?>? = nil,
                playerInset: CGFloat = 0, @ViewBuilder header: () -> Header) {
        self.init(meeting: meeting, host: host, findQuery: findQuery, find: find, scrollRequest: scrollRequest, scrolled: scrolled,
                  anchor: anchor, playerInset: playerInset, header: header) { EmptyView() }
    }
}

/// The transcript's scrolling column: `ReadingPage`'s geometry (the measure, the hanging margin from 600 pt, the lane
/// and the crease's clearance below it), with every row one lazy scroll target, so the app can keep the row at the
/// top (`scrollPosition`) and a long transcript makes its rows only as they scroll in. The column is laid out at its
/// real width from the first pass: a title field measured at a guessed width keeps that height.
private struct TranscriptColumn<Content: View>: View {
    let bottomInset: CGFloat
    @ViewBuilder var content: Content
    @Environment(\.daybookDensity) private var density
    @Environment(\.creaseEdge) private var creaseEdge

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let frame = ReadingGeometry.frame(width: width, density: density, creaseEdge: creaseEdge)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) { content }
                    .scrollTargetLayout()
                    .frame(maxWidth: frame.margin + frame.measure, alignment: .leading)
                    .padding(.leading, frame.leading)
                    .padding(.top, density == .touch ? DaybookSpacing.s4 : DaybookSpacing.s6)
                    .padding(.bottom, DaybookSpacing.s8 + bottomInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .environment(\.readingWidth, ReadingWidth(width: width))
        }
    }
}

/// Keeps the app's record of the top row, when it keeps one.
private struct AnchorPosition: ViewModifier {
    let anchor: Binding<String?>?

    func body(content: Content) -> some View {
        if let anchor { content.scrollPosition(id: anchor, anchor: .top) } else { content }
    }
}

#if DEBUG
@MainActor
private enum TranscriptLaunch {
    static var applied = false
}
#endif

/// Correct Passage in a sheet the page shows itself.
private struct CorrectionRequest: Identifiable {
    var id: UUID
}

/// A rename asked for at a row: the popover shows there.
private struct RenameRequest: Equatable {
    var speakerID: String
    var anchor: String
}

/// Rename Speaker as a popover at the row it was asked from (a sheet where a popover has no room).
private struct RenamePopover: ViewModifier {
    let row: String
    @Binding var request: RenameRequest?
    let meeting: Meeting
    let save: (String, String) -> Void

    func body(content: Content) -> some View {
        content.popover(isPresented: Binding(get: { request?.anchor == row }, set: { if !$0 { request = nil } }), arrowEdge: .bottom) {
            if let request {
                RenameSpeakerForm(name: meeting.speakerName(request.speakerID) ?? "") { save(request.speakerID, $0) }
            }
        }
    }
}

/// Back to Playing: over the page while the person reads elsewhere during playback. It floats over content, so it's
/// glass where the system has it, as the player is.
private struct BackToPlaying: View {
    let action: () -> Void
    @Environment(\.daybookDensity) private var density

    var body: some View {
        Button(action: action) {
            Label("Back to Playing", systemImage: "arrow.down.to.line")
                .font(density == .touch ? .footnote.weight(.semibold) : .system(size: 12, weight: .medium))
                .foregroundStyle(DaybookPalette.Ink.link)
                .padding(.horizontal, density == .touch ? 12 : 10)
                .padding(.vertical, density == .touch ? 7 : 5)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(FloatingCapsule())
    }
}

/// Liquid Glass on macOS 26 and iOS; on macOS 15 a material capsule with a hairline and a shadow.
private struct FloatingCapsule: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        if #available(macOS 26, *) {
            content.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        }
        #else
        content.glassEffect(.regular.interactive(), in: Capsule())
        #endif
    }
}

/// What the page draws from a version of the conversation, worked out once per version (as `TranscriptLayout` is)
/// rather than at every redraw while audio plays: the rows, which passages open a turn or were corrected, the passages
/// ↑ and ↓ move through, and the rotors' entries.
@MainActor
struct TranscriptPageLayout {
    let layout: TranscriptLayout
    let rows: [TranscriptRow]
    let turnStarts: Set<UUID>
    let corrected: Set<UUID>
    let passageIDs: [String]
    let rotors: TranscriptRotorEntries

    init(_ meeting: Meeting) {
        layout = TranscriptLayout.cached(for: meeting)
        rows = TranscriptRow.rows(from: layout.blocks)
        corrected = TranscriptCorrections.segmentIDs(in: meeting)
        var starts = Set<UUID>(), passages: [String] = []
        for row in rows {
            switch row {
            case .turn(_, let first): starts.insert(first.id)
            case .passage: passages.append(row.id)
            default: break
            }
        }
        turnStarts = starts
        passageIDs = passages
        rotors = TranscriptRotorEntries(rows: rows, marks: layout.marks, meeting: meeting)
    }

    static func cached(for meeting: Meeting) -> TranscriptPageLayout {
        if let hit = cache[meeting.id], hit.meeting == meeting { return hit.page }
        if cache.count >= 8 { cache.removeAll() }
        let page = TranscriptPageLayout(meeting)
        cache[meeting.id] = (meeting, page)
        return page
    }

    private static var cache: [UUID: (meeting: Meeting, page: TranscriptPageLayout)] = [:]
}

/// VoiceOver rotors for a long transcript: the bookmarked passages, your notes, and each speaker's turns.
private struct TranscriptRotors: ViewModifier {
    let rotors: TranscriptRotorEntries
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        var view = AnyView(content
            .accessibilityRotor("Bookmarks") {
                ForEach(rotors.bookmarks, id: \.id) { entry in AccessibilityRotorEntry(Text(entry.label), id: entry.id, in: namespace) }
            }
            .accessibilityRotor("Your Notes") {
                ForEach(rotors.notes, id: \.id) { entry in AccessibilityRotorEntry(Text(entry.label), id: entry.id, in: namespace) }
            })
        for speaker in rotors.speakers {
            view = AnyView(view.accessibilityRotor(speaker.name) {
                ForEach(speaker.turns, id: \.id) { entry in AccessibilityRotorEntry(Text(entry.label), id: entry.id, in: namespace) }
            })
        }
        return view
    }
}

/// What each rotor lists, as plain values: a row's ID and what VoiceOver reads for it.
public struct TranscriptRotorEntries: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var id: String
        public var label: String
    }

    public struct Speaker: Equatable, Sendable {
        public var name: String
        public var turns: [Entry]
    }

    public var bookmarks: [Entry] = []
    public var notes: [Entry] = []
    public var speakers: [Speaker] = []

    public init(rows: [TranscriptRow], marks: BookmarkMarks, meeting: Meeting) {
        var byName: [String: Int] = [:]
        for row in rows {
            switch row {
            case .passage(let segment) where marks.holders.contains(segment.id):
                let label = marks.labelSegments[segment.id] ?? String(segment.text.prefix(80))
                bookmarks.append(Entry(id: row.id, label: "\(TimeLabel.short(segment.start)), \(label)"))
            case .note(let note):
                notes.append(Entry(id: row.id, label: "\(TimeLabel.short(note.time ?? 0)), \(note.text)"))
            case .turn(let speakerID, let first):
                let name = meeting.speakerName(speakerID) ?? "Unknown speaker"
                let entry = Entry(id: row.id, label: "\(TimeLabel.short(first.start)), \(String(first.text.prefix(80)))")
                if let index = byName[name] { speakers[index].turns.append(entry) } else {
                    byName[name] = speakers.count
                    speakers.append(Speaker(name: name, turns: [entry]))
                }
            default: break
            }
        }
    }
}
