import DaybookCore
import DaybookDesign
import SwiftUI

/// The words read from one page, a row to a passage, where a passage's words can be corrected. The page itself is
/// never changed: a correction stands while the passage's strokes do (`PassageCorrection`).
public struct PageWordsList: View {
    private let page: NotebookPage
    private let correct: (_ passage: UUID, _ text: String) -> Void
    private let play: ((NotebookPassage) -> Void)?

    /// - Parameter play: Plays the conversation from when a passage was written; nil where nothing plays.
    public init(page: NotebookPage, correct: @escaping (UUID, String) -> Void, play: ((NotebookPassage) -> Void)? = nil) {
        self.page = page; self.correct = correct; self.play = play
    }

    public var body: some View {
        List {
            if page.passages.isEmpty {
                Text(page.needsReading ? "Reading" : "No words")
                    .foregroundStyle(DaybookPalette.Ink.secondary)
                    .listRowBackground(Color.clear)
            }
            ForEach(page.passages) { passage in
                PageWordsRow(passage: passage, words: page.words(of: passage), play: play.map { play in { play(passage) } }) {
                    correct(passage.id, $0)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    /// The time a passage was written, in the recording ("2:05"), nil without one.
    static func time(_ passage: NotebookPassage) -> String? {
        guard let seconds = passage.time else { return nil }
        let total = Int(seconds.rounded())
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
                             : String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct PageWordsRow: View {
    let passage: NotebookPassage
    let words: String?
    let play: (() -> Void)?
    let commit: (String) -> Void
    @State private var draft: String
    @FocusState private var focused: Bool

    init(passage: NotebookPassage, words: String?, play: (() -> Void)?, commit: @escaping (String) -> Void) {
        self.passage = passage; self.words = words; self.play = play; self.commit = commit
        _draft = State(initialValue: words ?? "")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DaybookSpacing.s3) {
            timeLabel
            TextField(passage.kind == .sketch ? "Sketch" : "No words", text: $draft, axis: .vertical)
                .focused($focused)
                .onSubmit(save)
                .onChange(of: focused) { _, isFocused in if !isFocused { save() } }
                .onChange(of: words) { _, new in if !focused { draft = new ?? "" } }
                .font(.body)
                .foregroundStyle(DaybookPalette.Ink.title)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: DaybookSpacing.s2, leading: DaybookSpacing.s4, bottom: DaybookSpacing.s2, trailing: DaybookSpacing.s4))
    }

    @ViewBuilder private var timeLabel: some View {
        if let time = PageWordsList.time(passage) {
            if let play {
                Button(action: play) {
                    Label(time, systemImage: "play.fill").labelStyle(.titleAndIcon).font(.footnote.monospacedDigit())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Play from \(time)")
            } else {
                Text(time).font(.footnote.monospacedDigit()).foregroundStyle(DaybookPalette.Ink.secondary)
            }
        }
    }

    private func save() {
        if draft != (words ?? "") { commit(draft) }
    }
}
