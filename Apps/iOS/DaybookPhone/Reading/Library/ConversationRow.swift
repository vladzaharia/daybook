import DaybookCaptions
import DaybookKit
import SwiftUI

/// One conversation in the list, as Notes lists notes: the title, then the time and the gist. A
/// glyph and a line of words appear only when the conversation isn't ready (not transcribed yet,
/// waiting for the Mac, being processed, couldn't finish), and mint marks the one playing now.
struct ConversationRow: View {
    let meeting: Meeting
    let status: RowStatus?
    let timeLabel: String
    var isPlaying = false
    var query = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicType

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(meeting.title.isEmpty ? "Untitled Conversation" : meeting.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                glyph.font(.footnote.weight(.semibold))
            }
            // At the largest text sizes the preview gets its own lines under the time.
            let layout = dynamicType.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 6))
            layout {
                Text(timeLabel).foregroundStyle(.primary).monospacedDigit()
                if let status, status.countdownUntil != nil {
                    // A summary's countdown, a second at a time.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(status.text(at: context.date)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    }
                } else {
                    Text(status?.text ?? RowPreview.text(for: meeting))
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicType.isAccessibilitySize ? 3 : 2)
                        .contentTransition(.opacity)
                }
            }
            .font(.subheadline)
            if let tags = meeting.tags, !tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(tags.prefix(3), id: \.self) { TagChip(tag: $0) }
                }
                .padding(.top, 3)
                .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 5)
        .animation(.easeOut(duration: 0.2), value: status)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder private var glyph: some View {
        if isPlaying {
            Image(systemName: "waveform")
                .foregroundStyle(PhoneStyle.neonMint)
                .symbolEffect(.variableColor.iterative, options: reduceMotion ? .nonRepeating : .repeating)
                .neonGlow(PhoneStyle.neonMint, radius: 3)
        } else {
            switch status?.kind {
            case .processing?:
                // One moving neon line says "working" without more words.
                ProgressView(value: status?.fraction ?? 0).progressViewStyle(.brand(width: 40, height: 3))
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            case .waiting?: Image(systemName: "clock").foregroundStyle(.secondary)
            case .failed?: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(PhoneStyle.Ink.warning)
            case .notTranscribed?:
                Circle().fill(PhoneStyle.accent).frame(width: 8, height: 8)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            case nil:
                if !meeting.highlights.isEmpty {
                    HStack(spacing: 2) {
                        Image(systemName: "bookmark.fill").imageScale(.small)
                        Text("\(meeting.highlights.count)").monospacedDigit()
                    }
                    .foregroundStyle(PhoneStyle.bookmark)
                }
            }
        }
    }

    private var accessibilityText: String {
        var parts = [meeting.title.isEmpty ? "Untitled Conversation" : meeting.title, timeLabel]
        if let duration = meeting.duration { parts.append(SpokenTime.format(duration)) }
        if isPlaying { parts.append("Playing") }
        parts.append(status?.text ?? RowPreview.text(for: meeting))
        if !meeting.highlights.isEmpty { parts.append(meeting.highlights.count == 1 ? "1 bookmark" : "\(meeting.highlights.count) bookmarks") }
        if let tags = meeting.tags, !tags.isEmpty { parts.append("Tags: " + tags.joined(separator: ", ")) }
        return parts.joined(separator: ", ")
    }
}

/// A search result: the conversation, the matched words in context, and where they were found.
struct SearchResultRow: View {
    let meeting: Meeting
    let hit: SearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(meeting.title.isEmpty ? "Untitled Conversation" : meeting.title).font(.headline).lineLimit(1)
                Spacer(minLength: 6)
                Text(meeting.date.formatted(.dateTime.day().month(.abbreviated))).font(.subheadline).foregroundStyle(.secondary)
            }
            if hit.field != .title || hit.match == nil {
                Text(snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
            }
            Label { Text(location) } icon: { Image(systemName: symbol) }
                .labelStyle(CompactLabelStyle())
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch hit.field {
        case .title: return "textformat"
        case .summary: return "text.alignleft"
        case .notes: return "note.text"
        case .transcript: return "quote.bubble"
        }
    }

    private var snippet: AttributedString {
        // A summary is Markdown: shown as words, without "- " list markers or "**" around them.
        let source = hit.field == .summary ? SearchSnippet.plain(hit.snippet) : hit.snippet
        let matched = hit.match.map { String(hit.snippet[$0]) }
        var text = AttributedString(source)
        if let matched, let match = source.range(of: matched, options: [.caseInsensitive, .diacriticInsensitive]),
           let lower = AttributedString.Index(match.lowerBound, within: text),
           let upper = AttributedString.Index(match.upperBound, within: text) {
            text[lower..<upper].font = .subheadline.weight(.semibold)
            text[lower..<upper].foregroundColor = PhoneStyle.Ink.link
        }
        return text
    }

    private var location: String {
        switch hit.field {
        case .title: return hit.match == nil ? "Conversation" : "Title"
        case .summary: return "Summary"
        case .notes: return "Your notes"
        case .transcript:
            if hit.matchCount > 1 { return "Transcript · \(hit.matchCount) matches" }
            return (["Transcript", hit.speaker, hit.time.map(TimeLabel.short)].compactMap { $0 }).joined(separator: " · ")
        }
    }
}

/// Search snippets as plain words.
enum SearchSnippet {
    /// Markdown from a summary, as it reads: emphasis marks and list markers (at the start, or where
    /// the lines were joined after a sentence) removed. The words themselves are untouched.
    static func plain(_ markdown: String) -> String {
        var text = markdown.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        let marker = try? NSRegularExpression(pattern: "(^|^…|(?<=[.!?:;…])\\s)[-*•]\\s+")
        text = marker?.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1") ?? text
        return text
    }
}

/// Icon and title close together, for small metadata lines.
struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon; configuration.title }
    }
}

/// A match in a conversation's saved live captions, labelled so it never passes for the transcript.
struct CaptionSearchRow: View {
    let meeting: Meeting
    let segment: LiveCaptionSegment
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(meeting.title.isEmpty ? "Untitled Conversation" : meeting.title).font(.headline).lineLimit(1)
                Spacer(minLength: 6)
                Text(meeting.date.formatted(.dateTime.day().month(.abbreviated))).font(.subheadline).foregroundStyle(.secondary)
            }
            Text(snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
            Label { Text("Live captions · tentative · \(TimeLabel.short(segment.start))") } icon: { Image(systemName: "captions.bubble") }
                .labelStyle(CompactLabelStyle())
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var snippet: AttributedString {
        guard let range = segment.text.range(of: query.trimmingCharacters(in: .whitespacesAndNewlines), options: [.caseInsensitive, .diacriticInsensitive]) else {
            return AttributedString(segment.text)
        }
        let (text, match) = LibrarySearch.excerpt(segment.text, around: range)
        var attributed = AttributedString(text)
        if let match, let lower = AttributedString.Index(match.lowerBound, within: attributed),
           let upper = AttributedString.Index(match.upperBound, within: attributed) {
            attributed[lower..<upper].font = .subheadline.weight(.semibold)
            attributed[lower..<upper].foregroundColor = PhoneStyle.Ink.link
        }
        return attributed
    }
}
