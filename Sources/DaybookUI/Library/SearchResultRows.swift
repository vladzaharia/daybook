import DaybookCaptions
import DaybookDesign
import DaybookKit
import Foundation
import SwiftUI

/// A library search result, on both apps: the conversation, the matched words in context (a summary's Markdown as
/// plain words, `SearchHit.displaySnippet`), and where they were found. A match in the title is marked in the title.
public struct SearchResultRowView: View {
    private let meeting: Meeting
    private let hit: SearchHit
    @Environment(\.daybookDensity) private var density

    public init(meeting: Meeting, hit: SearchHit) {
        self.meeting = meeting
        self.hit = hit
    }

    public var body: some View {
        let title = ConversationRowView.title(meeting)
        let snippet = hit.displaySnippet
        SearchResultLayout(title: SearchMarks.marked(title, match: hit.titleMatch(in: title), density: density, role: .rowTitle),
                           date: meeting.date,
                           snippet: hit.showsSnippet ? SearchMarks.marked(snippet.text, match: snippet.match, density: density, role: .rowDetail) : nil,
                           location: hit.location, symbol: hit.locationSymbol)
    }
}

/// A match in a conversation's saved live captions, labelled so it never passes for the transcript.
public struct CaptionHitRowView: View {
    private let meeting: Meeting
    private let segment: LiveCaptionSegment
    private let query: String
    @Environment(\.daybookDensity) private var density

    public init(meeting: Meeting, segment: LiveCaptionSegment, query: String) {
        self.meeting = meeting
        self.segment = segment
        self.query = query
    }

    public var body: some View {
        let found = segment.text.range(of: query.trimmingCharacters(in: .whitespacesAndNewlines), options: [.caseInsensitive, .diacriticInsensitive])
        let excerpt = found.map { LibrarySearch.excerpt(segment.text, around: $0) }
        SearchResultLayout(title: AttributedString(ConversationRowView.title(meeting)), date: meeting.date,
                           snippet: SearchMarks.marked(excerpt?.0 ?? segment.text, match: excerpt?.1, density: density, role: .rowDetail),
                           location: LibraryWords.captionLocation(start: segment.start), symbol: "captions.bubble")
    }
}

/// A result's lines: the title with the date beside it, the words found, and where.
struct SearchResultLayout: View {
    let title: AttributedString
    let date: Date
    let snippet: AttributedString?
    let location: String
    let symbol: String
    @Environment(\.daybookDensity) private var density

    private var onPaper: Bool { density != .window }
    private var secondary: AnyShapeStyle { onPaper ? AnyShapeStyle(DaybookPalette.Ink.secondary) : AnyShapeStyle(.secondary) }

    var body: some View {
        VStack(alignment: .leading, spacing: density == .touch ? 4 : 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(DaybookFont.rowTitle.font(density))
                    .foregroundStyle(onPaper ? AnyShapeStyle(DaybookPalette.Ink.title) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(date.formatted(.dateTime.day().month(.abbreviated)))
                    .font(DaybookFont.rowDetail.font(density))
                    .foregroundStyle(secondary)
            }
            if let snippet {
                Text(snippet)
                    .font(DaybookFont.rowDetail.font(density))
                    .foregroundStyle(secondary)
                    .lineLimit(SearchMarks.snippetLines)
            }
            Label { Text(location) } icon: { Image(systemName: symbol) }
                .labelStyle(CompactLabelStyle())
                .font(density == .touch ? .footnote : .system(size: 11))
                .foregroundStyle(secondary)
        }
        .padding(.vertical, density == .touch ? 4 : 6)
        .accessibilityElement(children: .combine)
    }
}

/// How a result marks what was found: the match in link ink and a heavier weight, in the role's own size.
enum SearchMarks {
    /// A snippet's lines on both apps.
    static let snippetLines = 2

    static func marked(_ text: String, match: Range<String.Index>?, density: DaybookDensity, role: DaybookFont) -> AttributedString {
        var marked = AttributedString(text)
        guard let match, let lower = AttributedString.Index(match.lowerBound, within: marked),
              let upper = AttributedString.Index(match.upperBound, within: marked) else { return marked }
        let font: Font
        switch density {
        case .touch: font = .system(role.textStyle, weight: role == .rowTitle ? .bold : .semibold)
        case .window, .panel: font = .system(size: role.size(density), weight: role == .rowTitle ? .bold : .semibold)
        }
        marked[lower..<upper].font = font
        marked[lower..<upper].foregroundColor = DaybookPalette.Ink.link
        return marked
    }
}

/// Icon and title close together, for small metadata lines.
public struct CompactLabelStyle: LabelStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon; configuration.title }
    }
}

/// Search of saved live captions for both apps' results: in the conversations a search could list, the first
/// matching caption of each that the text search didn't already find. Captions show only until a transcript made
/// after they began replaces them, and only with words to read. Read off the main actor from the library's
/// `LiveCaptions` folder, where both apps keep them.
public enum LibraryCaptionSearch {
    public struct Hit: Identifiable, Sendable {
        public var meeting: Meeting
        public var segment: LiveCaptionSegment
        public var id: UUID { meeting.id }
    }

    /// Where a library keeps saved live captions: `<library>/LiveCaptions/<conversation>.json`.
    public static func directory(libraryRoot: URL) -> URL {
        libraryRoot.appendingPathComponent("LiveCaptions", isDirectory: true)
    }

    /// The hits for `query` in `meetings`, leaving out `found` (conversations the text search listed).
    public static func hits(in meetings: [Meeting], query: String, excluding found: Set<UUID>, libraryRoot: URL) async -> [Hit] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = meetings.filter { !found.contains($0.id) }
        guard !text.isEmpty, !candidates.isEmpty else { return [] }
        let folder = directory(libraryRoot: libraryRoot)
        return await Task.detached(priority: .userInitiated) { () -> [Hit] in
            let saved = Set(((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "json" }
                .compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) })
            guard !saved.isEmpty else { return [] }
            let decoder = JSONDecoder()
            return candidates.filter { saved.contains($0.id) }.compactMap { meeting in
                guard let data = try? Data(contentsOf: folder.appendingPathComponent("\(meeting.id.uuidString).json")),
                      let captions = try? decoder.decode(LiveCaptions.self, from: data),
                      let segment = firstMatch(text, in: captions, of: meeting) else { return nil }
                return Hit(meeting: meeting, segment: segment)
            }
        }.value
    }

    /// The first caption with `query`, when the captions still show for the conversation.
    static func firstMatch(_ query: String, in captions: LiveCaptions, of meeting: Meeting) -> LiveCaptionSegment? {
        guard captions.meetingID == meeting.id,
              !meeting.transcripts.contains(where: { $0.createdAt >= captions.createdAt }) else { return nil }
        return captions.segments.first { $0.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}
