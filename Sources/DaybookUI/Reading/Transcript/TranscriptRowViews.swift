import DaybookDesign
import DaybookKit
import SwiftUI

// The transcript's rows, laid out by the page's width (`ReadingWidth`): on a regular page times hang in the margin and
// the text keeps one edge; on a narrow page a turn's time sits beside its speaker's name, your note's beside "Your
// note", and the text runs edge to edge. The playhead, a bookmark, and your note mark the text with a rule centred in
// the 8 pt gutter beside it (x = −4), where a corrected passage's dot sits too.

/// A block of the transcript: something in the margin and content in the measure on a regular page; on a narrow page
/// the content alone, edge to edge (the row puts its time inline).
struct TranscriptMarginRow<Margin: View, Content: View>: View {
    var alignment: VerticalAlignment = .firstTextBaseline
    @ViewBuilder var margin: Margin
    @ViewBuilder var content: Content
    @Environment(\.readingWidth) private var readingWidth

    var body: some View {
        if readingWidth == .regular {
            MarginRow(alignment: alignment) { margin } content: { content }
        } else {
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A time that plays from there: meta ink, link ink on hover, monospaced digits. `tabStop` false keeps it out of
/// keyboard navigation, for a time shown only while its row is hovered or focused: focus moving to it would take it away.
public struct TranscriptTime: View {
    private let time: TimeInterval
    private let tabStop: Bool
    private let play: () -> Void
    @Environment(\.daybookDensity) private var density
    @Environment(\.readingScale) private var scale
    @Environment(\.readingWidth) private var readingWidth
    @State private var hovering = false

    public init(time: TimeInterval, tabStop: Bool = true, play: @escaping () -> Void) {
        self.time = time
        self.tabStop = tabStop
        self.play = play
    }

    public var body: some View {
        if tabStop { button } else { button.focusable(false) }
    }

    private var button: some View {
        Button(action: play) {
            Text(TimeLabel.short(time))
                .font((readingWidth == .regular ? DaybookFont.marginTime : DaybookFont.time).font(density, scale: scale))
                .foregroundStyle(hovering ? DaybookPalette.Ink.link : DaybookPalette.Ink.meta)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .daybookMotion(DaybookMotion.hover, value: hovering)
        .accessibilityLabel("Play from \(SpokenTime.format(time))")
        .macHelp("Play from here")
    }
}

/// What a row asks of the page: playing, correcting, renaming, bookmarking, and what heard a passage.
struct TranscriptRowActions {
    var play: (PlaybackTarget) -> Void
    var canPlay: Bool
    var correct: (TranscriptSegment) -> Void
    var rename: (_ speakerID: String, _ anchor: String) -> Void
    var bookmark: (TranscriptSegment) -> Void
    var showHeardIn: (TranscriptSegment) -> Void
    var showNotes: () -> Void
    var move: (_ from: String, _ by: Int) -> Void
    /// Keeps words marked unsure as they are.
    var keepUnsure: (TranscriptFlagMark) -> Void
    /// Puts the earlier reading in place of words marked unsure.
    var useEarlierReading: (TranscriptFlagMark) -> Void
}

/// A turn's header: its speaker in their ink (renamed from here), and its first time.
struct TurnHeaderRow: View {
    let meeting: Meeting
    let rowID: String
    let speakerID: String?
    let first: TranscriptSegment
    let actions: TranscriptRowActions
    /// Wraps the speaker's name, which Rename Speaker's popover points at.
    var nameAttachment: (AnyView) -> AnyView = { $0 }
    @Environment(\.daybookDensity) private var density
    @Environment(\.readingScale) private var scale
    @Environment(\.readingWidth) private var readingWidth

    private var name: String { meeting.speakerName(speakerID) ?? "Unknown speaker" }

    var body: some View {
        TranscriptMarginRow {
            TranscriptTime(time: first.start) { actions.play(.segment(first)) }
        } content: {
            HStack(alignment: .firstTextBaseline, spacing: DaybookSpacing.s2) {
                nameAttachment(AnyView(
                    Button(name) { if let speakerID { actions.rename(speakerID, rowID) } }
                        .buttonStyle(.plain)
                        .font(DaybookFont.speaker.font(density, scale: scale))
                        .foregroundStyle(DaybookPalette.speakerInk(meeting.speakerIndex(speakerID)))
                        .disabled(speakerID == nil)
                        .accessibilityHint(speakerID == nil ? "" : "Renames this speaker")
                        .macHelp(speakerID == nil ? "" : "Rename this speaker")
                ))
                if readingWidth == .narrow {
                    TranscriptTime(time: first.start) { actions.play(.segment(first)) }
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One passage: its words as heard (corrected where the person corrected them), words that may be heard wrong under a
/// dotted line, bookmarks marked, the playhead's rule while it plays. A click or tap plays from it; a double-click,
/// Return, ⌘E, or the menu corrects it; the menu keeps unsure words or takes the earlier reading.
struct PassageRow: View {
    let meeting: Meeting
    let segment: TranscriptSegment
    /// The turn's first passage: its time is in the turn's header already.
    let opensTurn: Bool
    let isPlaying: Bool
    /// Washed briefly after a jump to it, or the current Find match.
    let emphasized: Bool
    let bookmarks: [Highlight]
    let label: String?
    let corrected: Bool
    /// Unsure words in it, in reading order (`TranscriptLayout.unsure`).
    let unsure: [TranscriptFlagMark]
    let highlight: String
    let actions: TranscriptRowActions
    var focus: FocusState<String?>.Binding
    @Environment(\.daybookDensity) private var density
    @Environment(\.readingScale) private var scale
    @Environment(\.readingWidth) private var readingWidth
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false

    private var rowID: String { segment.id.uuidString }
    private var isFocused: Bool { focus.wrappedValue == rowID }
    private var holder: Bool { !bookmarks.isEmpty }

    var body: some View {
        TranscriptMarginRow {
            if holder {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 9 * scale))
                    .foregroundStyle(DaybookPalette.bookmark)
                    .daybookGlow(DaybookPalette.bookmark, radius: 3)
                    .frame(width: 8)
                    .accessibilityHidden(true)
                    .macHelp(bookmarks.map { $0.text.isEmpty ? BookmarkLabel.untitled : $0.text }.joined(separator: "\n"))
            }
            // A turn's first passage has its time above it; a bookmark there shows the glyph alone. Others show their
            // time while hovered, focused, or bookmarked; until then there's no button to Tab to. A time shown only
            // while its passage is focused isn't a Tab stop either: Tab to it would unfocus the passage and hide it
            // with focus on it. Space on the passage plays.
            if !opensTurn {
                if hovering || isFocused || holder {
                    TranscriptTime(time: segment.start, tabStop: holder) { actions.play(.segment(segment)) }
                } else {
                    Text(TimeLabel.short(segment.start)).font(DaybookFont.marginTime.font(density, scale: scale)).hidden()
                        .accessibilityHidden(true)
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                if let label { labelLine(label) }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(FindHighlight.mark(UnsureWords.marked(segment.text, unsure), query: highlight))
                        .font(DaybookFont.body.font(density, scale: scale))
                        .foregroundStyle(DaybookPalette.Ink.body)
                        .lineSpacing(DaybookFont.bodyLineSpacing(density, scale: scale))
                        #if os(macOS)
                        .textSelection(.enabled)
                        #endif
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if segment.provenance.count > 1 { heardInButton }
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(wash, in: DaybookRadius.shape(DaybookRadius.row))
            .overlay(alignment: .leading) { rule }
            .padding(.horizontal, -6)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        #if os(macOS)
        .onTapGesture(count: 2) { actions.correct(segment) }
        #endif
        .onTapGesture { if actions.canPlay { actions.play(.segment(segment)) } }
        .daybookMotion(DaybookMotion.fade, value: isPlaying)
        .focusable(interactions: .activate)
        .focused(focus, equals: rowID)
        .onKeyPress(.return) { actions.correct(segment); return .handled }
        .onKeyPress(.space) { if actions.canPlay { actions.play(.segment(segment)) }; return .handled }
        .onKeyPress(.upArrow) { actions.move(rowID, -1); return .handled }
        .onKeyPress(.downArrow) { actions.move(rowID, 1); return .handled }
        .onKeyPress(keys: ["e", "c"], phases: .down) { press in
            guard press.modifiers == .command else { return .ignored }
            if press.key == "e" { actions.correct(segment) } else { LocalCopy.copy(segment.text) }
            return .handled
        }
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Plays from here")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if actions.canPlay { actions.play(.segment(segment)) } }
        .accessibilityAction(named: "Correct Passage") { actions.correct(segment) }
        .accessibilityAction(named: "Play from Here") { actions.play(.segment(segment)) }
        .accessibilityAction(named: "Add Bookmark Here") { actions.bookmark(segment) }
        .accessibilityActions {
            if let speakerID = segment.speakerID { Button("Rename Speaker") { actions.rename(speakerID, rowID) } }
            if segment.provenance.count > 1 { Button("Heard in \(segment.provenance.count) Recordings") { actions.showHeardIn(segment) } }
            unsureButtons
        }
    }

    /// For each unsure word or phrase: the earlier reading when there's one to take, and Keep.
    @ViewBuilder private var unsureButtons: some View {
        ForEach(unsure, id: \.flag.id) { mark in
            let words = mark.words(in: segment.text) ?? mark.flag.text
            if let title = UnsureWords.earlierReadingTitle(mark, in: segment.text) {
                Button(title, systemImage: "arrow.uturn.backward") { actions.useEarlierReading(mark) }
            }
            Button(UnsureWords.keepTitle(words), systemImage: "checkmark") { actions.keepUnsure(mark) }
        }
    }

    @ViewBuilder private func labelLine(_ label: String) -> some View {
        if readingWidth == .narrow {
            // No margin for the glyph: it leads the label.
            Label(label, systemImage: "bookmark.fill")
                .labelStyle(BookmarkLabelStyle())
                .font(DaybookFont.speaker.font(density, scale: scale))
                .foregroundStyle(DaybookPalette.bookmark)
        } else {
            Text(label).font(DaybookFont.speaker.font(density, scale: scale)).foregroundStyle(DaybookPalette.bookmark)
        }
    }

    private var heardInButton: some View {
        // A stack, not two squares, which reads as Copy.
        Button { actions.showHeardIn(segment) } label: {
            Image(systemName: "rectangle.stack")
                .font(density == .touch ? .caption : .system(size: 11 * scale))
                .foregroundStyle(DaybookPalette.Ink.meta)
                .frame(minWidth: density == .touch ? 24 : 18, minHeight: density == .touch ? 24 : 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Heard in \(segment.provenance.count) recordings")
        .macHelp("Heard in \(segment.provenance.count) recordings")
    }

    @ViewBuilder private var menu: some View {
        Button("Play from Here", systemImage: "play") { actions.play(.segment(segment)) }
            .disabled(!actions.canPlay)
        Button("Copy", systemImage: "doc.on.doc") { LocalCopy.copy(segment.text) }
        Divider()
        Button("Correct Passage…", systemImage: "pencil") { actions.correct(segment) }
        if let speakerID = segment.speakerID {
            Button("Rename Speaker…", systemImage: "person.text.rectangle") { actions.rename(speakerID, rowID) }
        }
        if !unsure.isEmpty {
            Divider()
            unsureButtons
        }
        Divider()
        Button("Add Bookmark Here", systemImage: "bookmark") { actions.bookmark(segment) }
        if segment.provenance.count > 1 {
            Button("Heard in \(segment.provenance.count) Recordings…", systemImage: "rectangle.stack") { actions.showHeardIn(segment) }
        }
    }

    private var wash: Color {
        if isPlaying && contrast != .increased { return DaybookPalette.neonMint.opacity(0.10) }
        if emphasized { return DaybookPalette.accent.opacity(0.14) }
        return .clear
    }

    /// The playhead's mint rule, else a bookmark's amber one, else a corrected passage's dot.
    @ViewBuilder private var rule: some View {
        if isPlaying {
            Capsule().fill(DaybookPalette.neonMint).frame(width: 3)
                .daybookGlow(DaybookPalette.neonMint, radius: 4)
                .offset(x: 0.5)
                .transition(.opacity)
        } else if holder {
            Capsule().fill(DaybookPalette.bookmark).frame(width: 2).offset(x: 1)
        } else if corrected {
            Circle().fill(DaybookPalette.accent).frame(width: 4, height: 4).accessibilityHidden(true)
        }
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if isPlaying { parts.append("Playing") }
        if holder { parts.append(label.map { "Bookmark: \($0)" } ?? "Bookmarked") }
        parts.append(segment.text)
        if corrected { parts.append("Corrected") }
        if !unsure.isEmpty { parts.append(UnsureWords.spoken(unsure.map { $0.words(in: segment.text) ?? $0.flag.text })) }
        return parts.joined(separator: ". ")
    }
}

/// Unsure words as a passage shows them, the same on both apps: a dotted line under them in the meta ink (quiet, and a
/// pattern, so the mark never rests on colour), and the words of what can be done with them.
enum UnsureWords {
    /// The passage's text with each unsure word or phrase underlined with dots.
    static func marked(_ text: String, _ unsure: [TranscriptFlagMark]) -> AttributedString {
        var attributed = AttributedString(text)
        for mark in unsure {
            guard let range = Range(NSRange(location: mark.range.lowerBound, length: mark.range.count), in: text),
                  let marked = Range(range, in: attributed) else { continue }
            // By the attribute's type: a key path through the attribute scope isn't Sendable, which complete checking flags.
            attributed[marked][AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self] =
                Text.LineStyle(pattern: .dot, color: DaybookPalette.Ink.meta)
        }
        return attributed
    }

    /// The action taking the earlier reading: "Use “Thursday”", or "Remove “really”" where it heard nothing. Nil when
    /// there's no earlier reading, or taking it would leave nothing of the passage.
    static func earlierReadingTitle(_ mark: TranscriptFlagMark, in text: String) -> String? {
        guard let alternative = mark.alternativeWords, mark.replacing(in: text) != nil else { return nil }
        return alternative.isEmpty ? "Remove “\(mark.words(in: text) ?? mark.flag.text)”" : "Use “\(alternative)”"
    }

    static func keepTitle(_ words: String) -> String { "Keep “\(words)”" }

    /// What VoiceOver reads after the passage: "Unsure: “Friday”, “Maria”".
    static func spoken(_ words: [String]) -> String {
        "Unsure: " + words.map { "“\($0)”" }.joined(separator: ", ")
    }
}

/// The bookmark glyph close to its label, as a passage's label line reads on a narrow page.
private struct BookmarkLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// Your note at its time, in your words on the teal rule. A click or tap plays from its time; Show in Your Notes
/// turns to it on the summary.
struct NoteRow: View {
    let note: TimedNote
    let highlight: String
    let emphasized: Bool
    let actions: TranscriptRowActions
    var focus: FocusState<String?>.Binding
    @Environment(\.daybookDensity) private var density
    @Environment(\.readingScale) private var scale
    @Environment(\.readingWidth) private var readingWidth
    @State private var hovering = false

    private var time: TimeInterval { note.time ?? 0 }
    private var rowID: String { "note:\(note.id.uuidString)" }

    var body: some View {
        TranscriptMarginRow {
            TranscriptTime(time: time) { actions.play(.timeline(time)) }
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                if readingWidth == .narrow {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Your note").font(DaybookFont.speaker.font(density, scale: scale)).foregroundStyle(DaybookPalette.Ink.link)
                        TranscriptTime(time: time) { actions.play(.timeline(time)) }
                    }
                }
                Text(FindHighlight.mark(AttributedString(note.text), query: highlight))
                    .font(DaybookFont.body.font(density, scale: scale))
                    .foregroundStyle(DaybookPalette.Ink.body)
                    .lineSpacing(DaybookFont.bodyLineSpacing(density, scale: scale))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(DaybookPalette.accent.opacity(emphasized ? 0.14 : hovering ? 0.06 : 0), in: DaybookRadius.shape(DaybookRadius.row))
            .overlay(alignment: .leading) { Capsule().fill(DaybookPalette.accent).frame(width: 2).offset(x: 1) }
            .padding(.horizontal, -6)
            .contentShape(Rectangle())
        }
        .onHover { hovering = $0 }
        .daybookMotion(DaybookMotion.hover, value: hovering)
        .onTapGesture { if actions.canPlay { actions.play(.timeline(time)) } }
        .focusable(interactions: .activate)
        .focused(focus, equals: rowID)
        .onKeyPress(.space) { if actions.canPlay { actions.play(.timeline(time)) }; return .handled }
        .contextMenu {
            Button("Play from Here", systemImage: "play") { actions.play(.timeline(time)) }.disabled(!actions.canPlay)
            Button("Show in Your Notes", systemImage: "note.text", action: actions.showNotes)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Your note at \(SpokenTime.format(time)): \(note.text)")
        .accessibilityHint("Plays from here")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if actions.canPlay { actions.play(.timeline(time)) } }
        .accessibilityAction(named: "Show in Your Notes", actions.showNotes)
    }
}

/// What the transcript needs from the person, in the page's boxes, each with the action that fixes it: a recording
/// that couldn't be lined up (Adjust Timing…), and corrections made before the audio was transcribed again (Review…).
struct TranscriptNotices: View {
    let meeting: Meeting
    let host: TranscriptHost

    var body: some View {
        if let report = meeting.alignmentReports.first(where: { $0.method == .unaligned }) {
            let name = meeting.tracks.first { $0.id == report.trackID }.map { host.recordingName($0, meeting) }
            notice(.problem, symbol: "exclamationmark.triangle.fill", title: TranscriptNoticeWords.unaligned(name),
                   action: TranscriptNoticeWords.adjustTiming) { _ = host.present(.adjustTiming(trackID: report.trackID)) }
        }
        if let issues = meeting.correctionTransferIssues, !issues.isEmpty {
            notice(.info, symbol: "pencil.circle.fill", title: TranscriptNoticeWords.corrections(issues.count),
                   action: TranscriptNoticeWords.review) { _ = host.present(.reviewCorrections) }
        }
    }

    private func notice(_ kind: AttentionKind, symbol: String, title: String, action: String,
                        perform: @escaping () -> Void) -> some View {
        PageBlock {
            AttentionBox(kind: kind, title: title, symbol: symbol, message: nil) {
                Button(action, action: perform).buttonStyle(.daybookLink).daybookHitTarget()
            }
        }
        .padding(.top, DaybookSpacing.s5)
    }
}
