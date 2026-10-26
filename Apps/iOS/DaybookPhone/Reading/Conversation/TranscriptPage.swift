import DaybookCaptions
import Combine
import DaybookKit
import SwiftUI

/// The evidence behind the page: who said what, in speaker ink, with times, your notes at their
/// times, and your bookmarks marked. Tap a passage or a time to play from there; playback follows
/// along (until you scroll away, when "Back to Playing" appears). Hold a passage to correct it,
/// rename its speaker, bookmark it, or see which recordings heard it.
struct TranscriptPage: View {
    @ObservedObject var library: LibraryController
    /// Not observed: the page redraws when the passage under the playhead changes, not on every tick.
    let player: PlaybackController
    let meeting: Meeting
    /// One column shows the title and byline here too, so switching feels like turning the page.
    var showsHeader = true
    @Environment(ReadingSession.self) private var session
    @Environment(\.audioProvider) private var provider
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.liveCaptionStore) private var captionStore
    @State private var lastUserScroll = Date.distantPast
    @State private var followSuspended = false
    @State private var consumedToken = 0
    @State private var renaming: Speaker?
    @State private var renameDraft = ""
    @State private var playing: UUID?
    @State private var isPlaying = false
    /// Saved live captions, shown in the transcript's place until the Mac's transcript arrives.
    @State private var captions: LiveCaptions?
    @State private var playingCaption: UUID?

    var body: some View {
        @Bindable var session = session
        let marks = BookmarkMarks(meeting: meeting)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if showsHeader {
                        PageHeader(library: library, meeting: meeting, play: play).padding(.bottom, PhoneStyle.Space.s2).id("header")
                    }
                    notices
                    if meeting.unifiedTranscript.isEmpty {
                        if let shown = SavedCaptions.shown(captions, for: meeting) {
                            CaptionRows(meeting: meeting, captions: shown, playing: playingCaption, play: play)
                        } else {
                            EmptyTranscript(library: library, meeting: meeting, play: play).id("empty")
                        }
                    }
                    ForEach(TranscriptRow.rows(in: meeting)) { row in
                        rowView(row, playing: playing, marks: marks)
                    }
                }
                .scrollTargetLayout()
                .pageColumn()
                .padding(.top, PhoneStyle.Space.s3)
                .padding(.bottom, PhoneStyle.Space.s8)
            }
            .scrollPosition(id: $session.transcriptAnchor, anchor: .top)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .onScrollPhaseChange { _, phase in
                guard phase == .interacting || phase == .decelerating else { return }
                lastUserScroll = Date()
                session.pageMode = .transcript
                if isPlaying { followSuspended = true }
            }
            .overlay(alignment: .top) {
                if followSuspended && isPlaying, let playing {
                    Button {
                        lastUserScroll = .distantPast
                        followSuspended = false
                        withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(playing.uuidString, anchor: UnitPoint(x: 0.5, y: 0.33)) }
                    } label: {
                        Label("Back to Playing", systemImage: "arrow.down.to.line")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(PhoneStyle.Ink.link)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .padding(.top, PhoneStyle.Space.s2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .motion(PhoneStyle.Motion.state, value: followSuspended)
            .onAppear { handleRequest(proxy) }
            .onChange(of: session.transcriptRequest) { _, _ in handleRequest(proxy) }
            .onChange(of: playingCaption) { _, id in
                guard let id, isPlaying, !followSuspended else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { proxy.scrollTo("caption:\(id.uuidString)", anchor: UnitPoint(x: 0.5, y: 0.33)) }
            }
            .onChange(of: playing) { _, id in
                // Follow playback only while the person isn't reading elsewhere.
                guard let id, isPlaying else { return }
                if Date().timeIntervalSince(lastUserScroll) > 5 { followSuspended = false }
                guard !followSuspended else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { proxy.scrollTo(id.uuidString, anchor: UnitPoint(x: 0.5, y: 0.33)) }
            }
        }
        .paperBackground()
        .modifier(PageTitle(title: showsHeader ? nil : SavedCaptions.shown(captions, for: meeting) == nil ? "Transcript" : "Live Captions"))
        .onReceive(player.objectWillChange.receive(on: RunLoop.main)) { _ in followPlayhead() }
        .onAppear { followPlayhead() }
        .task(id: "\(meeting.id)-\(meeting.showsLiveCaptions)") {
            // reading: captions come from the store `LibraryBrowser` provides; the Mac's transcript replaces them.
            captions = meeting.showsLiveCaptions ? captionStore?.captions(for: meeting.id) : nil
        }
        .alert("Rename Speaker", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameDraft).textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if let speaker = renaming, !name.isEmpty, name != speaker.name { library.renameSpeaker(speaker.id, to: name, in: meeting.id) }
                renaming = nil
            }
        } message: {
            Text("Changes every passage by \(renaming?.name ?? "this speaker") in this conversation.")
        }
    }

    @ViewBuilder
    private func rowView(_ row: TranscriptRow, playing: UUID?, marks: BookmarkMarks) -> some View {
        switch row {
        case .turn(let speakerID, let first):
            TurnHeader(meeting: meeting, speakerID: speakerID, first: first, play: play) {
                guard let speaker = meeting.speakers.first(where: { $0.id == speakerID }) else { return }
                renameDraft = speaker.name
                renaming = speaker
            }
            .padding(.top, PhoneStyle.Space.s5)
            .padding(.bottom, 2)
            .id(row.id)
        case .passage(let segment):
            PassageRow(library: library, meeting: meeting, segment: segment,
                       isPlaying: playing == segment.id,
                       flashed: session.flashedSegment == segment.id,
                       holder: marks.holders.contains(segment.id),
                       label: marks.labelSegments[segment.id],
                       play: play,
                       rename: segment.speakerID.flatMap { id in meeting.speakers.first { $0.id == id } }.map { speaker in
                           { renameDraft = speaker.name; renaming = speaker }
                       })
                .id(row.id)
        case .note(let note):
            NoteRow(note: note, play: { play(.timeline(note.time ?? 0)) })
                .padding(.top, PhoneStyle.Space.s3)
                .id(row.id)
        case .photo(let photo, _):
            PhotoTile(meeting: meeting, photo: photo)
                .padding(.top, PhoneStyle.Space.s3)
                .id(row.id)
        }
    }

    @ViewBuilder private var notices: some View {
        if let report = meeting.alignmentReports.first(where: { $0.method == .unaligned }) {
            let name = meeting.tracks.first { $0.id == report.trackID }.map { SourceDescription.name($0, in: meeting) } ?? "added"
            notice("exclamationmark.triangle.fill", PhoneStyle.Ink.warning,
                   "Couldn’t line up the \(name) recording with the others.")
        }
        if let issues = meeting.correctionTransferIssues, !issues.isEmpty {
            notice("pencil.line", PhoneStyle.Ink.secondary,
                   issues.count == 1 ? "An earlier correction needs a look. Review it on your Mac."
                                     : "\(issues.count) earlier corrections need a look. Review them on your Mac.")
        }
    }

    private func notice(_ symbol: String, _ tint: Color, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            Text(text).foregroundStyle(PhoneStyle.Ink.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .font(PhoneStyle.Typeface.status)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PhoneStyle.quietFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.top, PhoneStyle.Space.s4)
    }

    private func handleRequest(_ proxy: ScrollViewProxy) {
        guard let request = session.transcriptRequest, request.token != consumedToken else { return }
        consumedToken = request.token
        DispatchQueue.main.async {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) { proxy.scrollTo(request.target, anchor: UnitPoint(x: 0.5, y: 0.3)) }
        }
        if request.flash {
            let target = request.target
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                if session.flashedSegment?.uuidString == target { withAnimation(.easeOut(duration: 0.4)) { session.flashedSegment = nil } }
            }
        }
    }

    /// The passage under the playhead, in the recording that is playing; state changes only when it does.
    private func followPlayhead() {
        let here = player.meetingID == meeting.id && player.phase == .ready
        let id = here ? player.trackID.flatMap { TranscriptFollow.segmentID(at: player.position, trackID: $0, in: meeting) } : nil
        if id != playing { playing = id }
        let caption = here ? SavedCaptions.shown(captions, for: meeting).flatMap {
            SavedCaptions.playing(at: player.position, trackID: player.trackID, captions: $0, in: meeting)
        } : nil
        if caption != playingCaption { playingCaption = caption }
        let now = here && player.isPlaying
        if now != isPlaying { isPlaying = now }
    }

    private func play(_ target: PlaybackTarget) {
        player.play(target, in: meeting, provider: provider)
    }
}

/// The transcript flattened into rows, so each passage is its own scroll target.
enum TranscriptRow: Identifiable, Equatable {
    case turn(speakerID: String?, first: TranscriptSegment)
    case passage(TranscriptSegment)
    case note(TimedNote)
    case photo(MeetingPhoto, Double)

    var id: String {
        switch self {
        case .turn(_, let first): return "turn:\(first.id.uuidString)"
        case .passage(let segment): return segment.id.uuidString
        case .note(let note): return "note:\(note.id.uuidString)"
        case .photo(let photo, _): return photo.id.uuidString
        }
    }

    static func rows(in meeting: Meeting) -> [TranscriptRow] {
        TranscriptBlock.blocks(in: meeting).flatMap { block -> [TranscriptRow] in
            switch block {
            case .turn(_, let speakerID, let segments):
                guard let first = segments.first else { return [] }
                return [.turn(speakerID: speakerID, first: first)] + segments.map(TranscriptRow.passage)
            case .note(let note):
                return [.note(note)]
            case .photo(let photo, let time):
                return [.photo(photo, time)]
            }
        }
    }
}

private struct TurnHeader: View {
    let meeting: Meeting
    let speakerID: String?
    let first: TranscriptSegment
    let play: (PlaybackTarget) -> Void
    let rename: () -> Void

    private var name: String { meeting.speakerName(speakerID) ?? "Unknown speaker" }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(action: rename) {
                Text(name).font(PhoneStyle.Typeface.speaker).foregroundStyle(PhoneStyle.speakerInk(meeting.speakerIndex(speakerID)))
            }
            .buttonStyle(.plain)
            .disabled(speakerID == nil)
            .accessibilityHint(speakerID == nil ? "" : "Renames this speaker")
            TimeButton(time: first.start) { play(.segment(first)) }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct PassageRow: View {
    @ObservedObject var library: LibraryController
    let meeting: Meeting
    let segment: TranscriptSegment
    let isPlaying: Bool
    let flashed: Bool
    let holder: Bool
    let label: String?
    let play: (PlaybackTarget) -> Void
    let rename: (() -> Void)?
    @Environment(ReadingSession.self) private var session
    @Environment(\.findQuery) private var query
    @Environment(\.colorSchemeContrast) private var contrast

    private var corrected: Bool { meeting.revisions.contains { $0.field == "segment:\(segment.id.uuidString)" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let label {
                Label(label, systemImage: "bookmark.fill")
                    .labelStyle(CompactLabelStyle())
                    .font(PhoneStyle.Typeface.speaker)
                    .foregroundStyle(PhoneStyle.bookmark)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(FindHighlight.mark(AttributedString(segment.text), query: query))
                    .font(PhoneStyle.Typeface.body)
                    .foregroundStyle(PhoneStyle.Ink.body)
                    .lineSpacing(PhoneStyle.Typeface.bodyLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if segment.provenance.count > 1 {
                    Button { session.sheet = .heardIn(meetingID: meeting.id, segmentID: segment.id) } label: {
                        Image(systemName: "square.on.square").font(.caption).foregroundStyle(PhoneStyle.Ink.meta)
                            .frame(minWidth: 24, minHeight: 24)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Heard in \(segment.provenance.count) recordings")
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .leading) {
            // The playhead and a bookmark share one rule in the gutter beside the text.
            if isPlaying {
                Capsule().fill(PhoneStyle.neonMint).frame(width: 3).neonGlow(PhoneStyle.neonMint, radius: 4).offset(x: -3)
                    .transition(.opacity)
            } else if holder {
                Capsule().fill(PhoneStyle.bookmark).frame(width: 2).offset(x: -2)
            } else if corrected {
                Circle().fill(PhoneStyle.accent).frame(width: 5, height: 5).offset(x: -4).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, -8)
        .contentShape(Rectangle())
        .onTapGesture { play(.segment(segment)) }
        .animation(.easeOut(duration: 0.2), value: isPlaying)
        .contextMenu {
            Button { play(.segment(segment)) } label: { Label("Play from Here", systemImage: "play") }
            Button { LocalPasteboard.copy(segment.text) } label: { Label("Copy", systemImage: "doc.on.doc") }
            Divider()
            Button { session.sheet = .correct(meetingID: meeting.id, segmentID: segment.id) } label: { Label("Correct Passage…", systemImage: "pencil") }
            if let rename { Button(action: rename) { Label("Rename Speaker…", systemImage: "person.text.rectangle") } }
            Button {
                let start = segment.provenance.first { $0.trackID == segment.trackID }?.start ?? segment.start
                library.addBookmark(in: meeting.id, trackID: segment.trackID, at: start)
            } label: { Label("Add Bookmark Here", systemImage: "bookmark") }
            if segment.provenance.count > 1 {
                Button { session.sheet = .heardIn(meetingID: meeting.id, segmentID: segment.id) } label: {
                    Label("Heard in \(segment.provenance.count) Recordings…", systemImage: "square.on.square")
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Plays from here")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Correct Passage") { session.sheet = .correct(meetingID: meeting.id, segmentID: segment.id) }
        .accessibilityAction(named: "Add Bookmark Here") { library.addBookmark(in: meeting.id, trackID: segment.trackID, at: segment.provenance.first?.start ?? segment.start) }
    }

    private var background: Color {
        if isPlaying && contrast != .increased { return PhoneStyle.neonMint.opacity(0.10) }
        if flashed { return PhoneStyle.accent.opacity(0.14) }
        return .clear
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if isPlaying { parts.append("Playing") }
        if holder { parts.append(label.map { "Bookmark: \($0)" } ?? "Bookmarked") }
        parts.append(segment.text)
        if corrected { parts.append("Corrected") }
        return parts.joined(separator: ". ")
    }
}

/// Your note in the transcript, at its time, on the teal rule.
private struct NoteRow: View {
    let note: TimedNote
    let play: () -> Void
    @Environment(ReadingSession.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("Your note").font(.caption.weight(.semibold)).foregroundStyle(PhoneStyle.Ink.link)
                TimeButton(time: note.time ?? 0, play: play)
            }
            Text(note.text)
                .font(PhoneStyle.Typeface.body)
                .foregroundStyle(PhoneStyle.Ink.body)
                .lineSpacing(PhoneStyle.Typeface.bodyLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PhoneStyle.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .leading) { Capsule().fill(PhoneStyle.accent).frame(width: 2).offset(x: -2) }
        .padding(.horizontal, -8)
        .contextMenu {
            Button(action: play) { Label("Play from Here", systemImage: "play") }
            Button { session.showOnSummary(SummaryBlockID.notes) } label: { Label("Show in Your Notes", systemImage: "note.text") }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Your note at \(SpokenTime.format((note.time ?? 0).rounded(.down))): \(note.text)")
    }
}

/// The right page before there's a transcript: a calm, complete state, not an error.
private struct EmptyTranscript: View {
    @ObservedObject var library: LibraryController
    let meeting: Meeting
    let play: (PlaybackTarget) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PhoneStyle.Space.s3) {
            Image(systemName: meeting.tracks.isEmpty ? "note.text" : "waveform")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(PhoneStyle.accent)
                .accessibilityHidden(true)
            Text(title).font(PhoneStyle.Typeface.rowTitle).foregroundStyle(PhoneStyle.Ink.title)
            if let message {
                Text(message).font(PhoneStyle.Typeface.status).foregroundStyle(PhoneStyle.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !meeting.tracks.isEmpty {
                Button { play(.timeline(0)) } label: {
                    Label("Play Recording", systemImage: "play.fill").font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                }
                .buttonStyle(.glass)
                .tint(PhoneStyle.accent)
                .padding(.top, PhoneStyle.Space.s1)
            }
        }
        .padding(.top, PhoneStyle.Space.s7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        if meeting.tracks.isEmpty { return "No recording yet" }
        if case .failed = ProcessingStatus(meeting) { return "No transcript" }
        return "Not transcribed yet"
    }

    private var message: String? {
        if meeting.tracks.isEmpty { return "Record into it on your Mac to add a transcript." }
        if case .failed(let failure) = ProcessingStatus(meeting) {
            return FriendlyError.isNoSpeech(failure.reason) ? "No speech was found in this recording. The audio is saved." : "Your Mac couldn’t finish transcribing it. The audio is saved."
        }
        return nil
    }
}

/// The page's own title on two pages (one column shows the page switch instead).
private struct PageTitle: ViewModifier {
    let title: String?
    func body(content: Content) -> some View {
        if let title { content.navigationTitle(title) } else { content }
    }
}
