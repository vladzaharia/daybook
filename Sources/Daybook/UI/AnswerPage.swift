import DaybookCore
import DaybookDesign
import DaybookIntelligence
import DaybookKit
import DaybookUI
import SwiftUI

/// The answer to a question across conversations, as the detail column's page (docs/interface.md, "Asking a
/// question"): the question as its title, how it was read when it named dates or people, the sentences with numbered
/// sources, the sources, and what is left unanswered. It shows what `AskController` holds and is gone when the question
/// closes. Each source opens its conversation at the passage, and plays it without leaving the page.
struct AnswerPage: View {
    @Bindable var state: AppState
    let ask: AskController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    var body: some View {
        ReadingPage {
            VStack(alignment: .leading, spacing: DaybookSpacing.s4) {
                header
                content
            }
            .animation(DaybookMotion.resolved(DaybookMotion.state, reduceMotion: reduceMotion), value: ask.stage)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DaybookPalette.paper)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onExitCommand { ask.close() }
        .bottomBar { player }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Answer")
    }

    // MARK: Header

    private var header: some View {
        MarginRow {
            VStack(alignment: .leading, spacing: 6) {
                Text(ask.question ?? "")
                    .daybookFont(.docTitle)
                    .foregroundStyle(DaybookPalette.Ink.title)
                    .lineLimit(1...4)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
                if let reading = AskPageWords.reading(scope: ask.scopeName, query: ask.reply?.answer.query) {
                    Text(reading)
                        .daybookFont(.byline)
                        .foregroundStyle(DaybookPalette.Ink.secondary)
                }
            }
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch ask.stage {
        case .searching: working(AskPageWords.searching)
        case .waiting(let job): working(AskPageWords.waiting(for: job))
        case .loading(let fraction): working(AskPageWords.loading(fraction))
        case .answering: working(AskPageWords.answering)
        case .answered: answered
        case .needsModel:
            status(AskPageWords.downloadModel) {
                Button(AskPageWords.download) { ModelManager(state: state).download(state.summaryModel) }
                    .buttonStyle(.daybookTinted)
            }
        case .busy:
            status(AskPageWords.modelBusy) {
                Button(AskPageWords.askAgain) { ask.askAgain() }.buttonStyle(.daybookTinted)
            }
        case .failed:
            status(AskPageWords.couldNotAnswer) {
                Button(AskPageWords.askAgain) { ask.askAgain() }.buttonStyle(.daybookTinted)
            }
        case .hidden:
            status(PersonalLockWords.hiddenTitle) {
                Button(AskPageWords.askAgain) { ask.askAgain() }.buttonStyle(.daybookTinted)
            }
        }
    }

    /// The bare line where the first sentence will be, and the sentences that have been checked so far, with Cancel.
    private func working(_ line: String) -> some View {
        VStack(alignment: .leading, spacing: DaybookSpacing.s4) {
            if !ask.sentences.isEmpty { sentencesAndSources }
            MarginRow {
                HStack(spacing: DaybookSpacing.s3) {
                    Text(line)
                    Button(AskPageWords.cancel) { ask.close() }
                        .buttonStyle(.plain)
                        .foregroundStyle(DaybookPalette.Ink.link)
                        .keyboardShortcut(.cancelAction)
                }
                .daybookFont(.status)
                .foregroundStyle(DaybookPalette.Ink.secondary)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func status(_ line: String, @ViewBuilder action: () -> some View) -> some View {
        MarginRow {
            VStack(alignment: .leading, spacing: DaybookSpacing.s3) {
                Text(line).daybookFont(.lede).foregroundStyle(DaybookPalette.Ink.secondary)
                action()
            }
        }
    }

    @ViewBuilder private var answered: some View {
        if let answer = ask.reply?.answer, answer.isNotFound || ask.sentences.isEmpty {
            notFound(answer)
        } else {
            sentencesAndSources
            if ask.reply?.answer.status == .partial {
                MarginRow {
                    Text(AskWords.partial).daybookFont(.body).foregroundStyle(DaybookPalette.Ink.secondary)
                }
            }
            colophon
        }
    }

    // MARK: Sentences

    /// The distinct sources of the answer so far, in the order they are first cited.
    private var sources: [AskCitation] {
        var seen: [AskCitation] = []
        for citation in ask.sentences.flatMap(\.citations) where !seen.contains(where: { Self.same($0, citation) }) { seen.append(citation) }
        return seen
    }

    private static func same(_ lhs: AskCitation, _ rhs: AskCitation) -> Bool {
        lhs.meetingID == rhs.meetingID && lhs.segmentID == rhs.segmentID && lhs.highlightID == rhs.highlightID
            && lhs.paragraph == rhs.paragraph && lhs.text == rhs.text
    }

    private var sentencesAndSources: some View {
        let sources = sources
        return VStack(alignment: .leading, spacing: DaybookSpacing.s4) {
            ForEach(Array(ask.sentences.enumerated()), id: \.offset) { _, sentence in
                sentenceRow(sentence, sources: sources)
            }
            if !sources.isEmpty { sourceList(sources) }
        }
    }

    /// A sentence with its source marks inline after the full stop, as a footnote reference sits: the words flow, and the
    /// last word travels with the marks so a mark never starts a line alone. VoiceOver reads the sentence, then each source.
    private func sentenceRow(_ sentence: AskSentence, sources: [AskCitation]) -> some View {
        let text = ModelText.inlineMarkdown(sentence.text)
        let words = text.characters.split(whereSeparator: \.isWhitespace).map { AttributedString(text[$0.startIndex..<$0.endIndex]) }
        let marks = sentence.citations.compactMap { citation in
            sources.firstIndex(where: { Self.same($0, citation) }).map { (number: $0 + 1, citation: citation) }
        }
        return MarginRow {
            FlowLayout(spacing: 4, lineSpacing: 2) {
                ForEach(Array(words.dropLast().enumerated()), id: \.offset) { _, word in wordText(word) }
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    if let last = words.last { wordText(last) }
                    ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                        CitationMark(number: mark.number, label: spoken(mark.number, mark.citation)) { state.openCitation(mark.citation) }
                    }
                }
                .fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(sentence.text)
        }
    }

    private func wordText(_ word: AttributedString) -> some View {
        Text(word)
            .daybookFont(.body)
            .foregroundStyle(DaybookPalette.Ink.body)
            .fixedSize()
            .accessibilityHidden(true)
    }

    private func spoken(_ number: Int, _ citation: AskCitation) -> String {
        AskPageWords.spokenSource(number: number, citation: citation, untitled: "Untitled conversation")
    }

    // MARK: Sources

    private func sourceList(_ sources: [AskCitation]) -> some View {
        VStack(alignment: .leading, spacing: DaybookSpacing.s3) {
            MarginRow {
                Text(AskPageWords.sources).daybookFont(.heading).foregroundStyle(DaybookPalette.Ink.title)
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(Array(sources.enumerated()), id: \.offset) { index, citation in
                sourceRow(number: index + 1, citation)
            }
        }
        .padding(.top, DaybookSpacing.s2)
    }

    private func sourceRow(number: Int, _ citation: AskCitation) -> some View {
        MarginRow(alignment: .top) {
            Text("\(number)").daybookFont(.marginTime).foregroundStyle(DaybookPalette.Ink.meta).monospacedDigit()
        } content: {
            HStack(alignment: .top, spacing: DaybookSpacing.s3) {
                Button { state.openCitation(citation) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.sourceLine(citation))
                            .daybookFont(.rowDetail)
                            .foregroundStyle(DaybookPalette.Ink.secondary)
                            .lineLimit(2)
                        Text("“\(citation.text)”")
                            .daybookFont(.rowDetail)
                            .foregroundStyle(DaybookPalette.Ink.body)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(spoken(number, citation))
                .accessibilityHint(AskPageWords.open)
                if citation.kind == .passage, citation.time != nil {
                    Button { state.playCitation(citation) } label: {
                        Image(systemName: "play.fill").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DaybookPalette.accent)
                    .daybookHitTarget()
                    .disabled(state.isRecording)
                    .help(AskPageWords.play)
                    .accessibilityLabel("\(AskPageWords.play), \(spoken(number, citation))")
                }
            }
        }
    }

    /// "Weekly product sync · 14 Oct · Sam 14:22".
    static func sourceLine(_ citation: AskCitation) -> String {
        let title = citation.conversationTitle ?? "Untitled conversation"
        let date = citation.date.formatted(.dateTime.day().month(.abbreviated))
        return [title, date, AskPageWords.sourceMeta(citation)].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: Not found

    @ViewBuilder private func notFound(_ answer: AskAnswer) -> some View {
        let narrow = ask.scope.map { $0.search != .all } ?? false
        status(narrow ? AskWords.notFound(in: ask.scopeName) : AskWords.notFound) {
            if narrow {
                Button(AskPageWords.searchAll) {
                    state.window.searchScope = .all
                    ask.askAgain()
                }
                .buttonStyle(.daybookTinted)
            }
        }
        let closest = answer.closest.compactMap { id in state.meetings.first { $0.id == id } }.prefix(5)
        if !closest.isEmpty {
            VStack(alignment: .leading, spacing: DaybookSpacing.s2) {
                MarginRow {
                    Text(AskPageWords.closest).daybookFont(.heading).foregroundStyle(DaybookPalette.Ink.title)
                        .accessibilityAddTraits(.isHeader)
                }
                ForEach(Array(closest), id: \.id) { meeting in
                    MarginRow {
                        Button {
                            state.window.selection = []
                            state.window.openID = meeting.id
                            ask.leavePage()
                        } label: {
                            HStack(spacing: DaybookSpacing.s2) {
                                Text(ConversationRowView.title(meeting)).foregroundStyle(DaybookPalette.Ink.link)
                                Text(meeting.date.formatted(.dateTime.day().month(.abbreviated)))
                                    .foregroundStyle(DaybookPalette.Ink.meta)
                            }
                            .daybookFont(.rowDetail)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.top, DaybookSpacing.s2)
        }
    }

    // MARK: Colophon and player

    @ViewBuilder private var colophon: some View {
        if let reply = ask.reply, reply.provenance != nil {
            MarginRow {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "laptopcomputer").accessibilityHidden(true)
                    Text(AskPageWords.colophon(model: ask.modelName))
                }
                .daybookFont(.colophon)
                .foregroundStyle(DaybookPalette.Ink.meta)
            }
            .padding(.top, DaybookSpacing.s5)
        }
    }

    /// The player for a source playing from here: the page has no conversation of its own.
    @ViewBuilder private var player: some View {
        if let id = state.playback.meetingID, let meeting = state.meetings.first(where: { $0.id == id }), !state.personalLock.hides(meeting) {
            PlayerBar(player: state.playback, meeting: meeting, isRecording: state.isRecording) { trackID, seconds in
                state.addPlaybackHighlight(meeting.id, trackID: trackID, seconds: seconds)
            }
        }
    }
}

/// A small numbered mark after a sentence, set like a footnote reference in the link ink: the source it rests on. A
/// button, so the keyboard reaches it.
private struct CitationMark: View {
    let number: Int
    let label: String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            Text("\(number)")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(DaybookPalette.Ink.link)
                .baselineOffset(5)
                .padding(.horizontal, 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint(AskPageWords.open)
    }
}
