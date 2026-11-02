import DaybookDesign
import DaybookKit
import SwiftUI

/// A place in the library with nothing in it, in its words (`LibraryWords.emptyPlace`): "No Conversations" with
/// the place's glyph, a folder with how to fill it, and an empty library with Daybook's mark.
public struct LibraryEmptyPlaceView: View {
    private let words: LibraryWords.EmptyPlace

    public init(_ words: LibraryWords.EmptyPlace) { self.words = words }

    public var body: some View {
        DaybookEmptyState(title: words.title, image: words.showsMark ? .mark : .symbol(words.symbol), message: words.description)
            .accessibilityElement(children: .combine)
    }
}

/// An empty library while this install's first sync pass is still bringing it in: a spinner and "Getting your
/// conversations…", in place of "No Conversations Yet".
public struct GettingConversationsView: View {
    @Environment(\.daybookDensity) private var density

    public init() {}

    public var body: some View {
        VStack(spacing: DaybookSpacing.s3) {
            ProgressView()
                #if os(macOS)
                .controlSize(.small)
                #endif
            Text(LibraryWords.gettingConversations)
                .font(DaybookFont.status.font(density))
                .foregroundStyle(DaybookPalette.Ink.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(DaybookSpacing.s5)
        .accessibilityElement(children: .combine)
    }
}

/// One quiet line while sync needs the person (`LibraryWords.syncAttention`): the glyph in warning ink, the sentence
/// Settings says it with, and Open Sync Settings… as a text link under it. It takes its column's width and the
/// height its words need, and nothing more, so it can sit in a list's top inset.
public struct LibrarySyncLine: View {
    private let text: String
    private let openSettings: () -> Void
    @Environment(\.daybookDensity) private var density

    /// The link's title, as Floating Notes' iCloud chip offers it.
    public static let actionTitle = "Open Sync Settings…"

    public init(_ text: String, openSettings: @escaping () -> Void) {
        self.text = text
        self.openSettings = openSettings
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DaybookSpacing.s2) {
            Image(systemName: "exclamationmark.icloud")
                .foregroundStyle(DaybookPalette.Ink.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DaybookSpacing.s1) {
                sentence
                link
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(DaybookFont.status.font(density))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(LibraryWords.notSyncing). \(text)")
        .accessibilityAction(named: Self.actionTitle, openSettings)
    }

    private var sentence: some View {
        Text(text)
            .foregroundStyle(density == .window ? AnyShapeStyle(.primary) : AnyShapeStyle(DaybookPalette.Ink.body))
            // Wraps in the width it's given; a fixed vertical size here made a window's split view taller than the
            // window once the sentence took two lines in a list's top inset.
            .lineLimit(3)
            .help(LibraryWords.notSyncing)
    }

    private var link: some View {
        Button(Self.actionTitle, action: openSettings)
            .buttonStyle(.daybookLink)
            .fixedSize()
    }
}
