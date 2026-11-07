import SwiftUI
import WidgetKit

/// A Home Screen list. The small size opens its one conversation; larger sizes link each row.
struct RecentConversationsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedRecentConversations.widgetKind, provider: RecentConversationsTimeline()) { entry in
            RecentConversationsWidgetView(entry: entry)
                .containerBackground(for: .widget) { PhoneStyle.paper }
        }
        .configurationDisplayName("Recent Conversations")
        .description("Open a recent conversation from your library.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct RecentConversationsEntry: TimelineEntry {
    let date: Date
    /// Nil until the app has published a loaded library.
    let snapshot: SharedRecentConversations?

    static var preview: Self {
        let now = Date()
        let titles = ["Design review", "Weekly product sync", "Project kickoff", "Planning session", "Team check-in", "Ideas"]
        let conversations = titles.enumerated().map { index, title in
            SharedRecentConversations.Conversation(id: UUID(), title: title, date: now.addingTimeInterval(-Double(index) * 86_400))
        }
        return Self(date: now, snapshot: SharedRecentConversations(conversations))
    }
}

struct RecentConversationsTimeline: TimelineProvider {
    func placeholder(in context: Context) -> RecentConversationsEntry { .preview }

    func getSnapshot(in context: Context, completion: @escaping (RecentConversationsEntry) -> Void) {
        completion(context.isPreview ? .preview : RecentConversationsEntry(date: .now, snapshot: SharedRecentConversations.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecentConversationsEntry>) -> Void) {
        let entry = RecentConversationsEntry(date: .now, snapshot: SharedRecentConversations.load())
        // The app reloads this timeline when the loaded library's visible metadata changes.
        completion(Timeline(entries: [entry], policy: .never))
    }
}

private struct RecentConversationsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RecentConversationsEntry

    var body: some View {
        if family == .systemSmall {
            small
        } else {
            list
        }
    }

    private var emptyTitle: String {
        entry.snapshot == nil ? "Open Daybook" : "No recent conversations"
    }

    private var emptyMessage: String {
        entry.snapshot == nil ? "Load your library to see recent conversations." : "Personal conversations aren't shown."
    }

    private var small: some View {
        let conversation = entry.snapshot?.conversations.first
        return VStack(alignment: .leading, spacing: 6) {
            Label("Recent", systemImage: "text.book.closed")
                .font(.caption.weight(.semibold))
                .foregroundStyle(PhoneStyle.Ink.secondary)
            Spacer(minLength: 4)
            if let conversation {
                Text(conversation.title)
                    .font(PhoneStyle.Typeface.title(.headline))
                    .foregroundStyle(PhoneStyle.Ink.title)
                    .lineLimit(3)
                    .privacySensitive()
                Text(conversation.date, style: .date)
                    .font(.caption)
                    .foregroundStyle(PhoneStyle.Ink.meta)
            } else {
                Text(emptyTitle)
                    .font(.headline)
                    .foregroundStyle(PhoneStyle.Ink.title)
                Text(emptyMessage)
                    .font(.caption)
                    .foregroundStyle(PhoneStyle.Ink.secondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(conversation.map { WidgetLink.conversation($0.id).url } ?? WidgetLink.library.url)
    }

    private var list: some View {
        let conversations = Array((entry.snapshot?.conversations ?? []).prefix(family == .systemMedium ? 3 : 6))
        return VStack(alignment: .leading, spacing: 0) {
            Label("Recent conversations", systemImage: "text.book.closed")
                .font(PhoneStyle.Typeface.title(.headline))
                .foregroundStyle(PhoneStyle.Ink.title)
                .lineLimit(1)
                .padding(.bottom, 4)
            if conversations.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(emptyTitle).font(.subheadline.weight(.semibold))
                    Text(emptyMessage).font(.caption).foregroundStyle(PhoneStyle.Ink.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                ForEach(conversations) { conversation in
                    Link(destination: WidgetLink.conversation(conversation.id).url) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(conversation.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(PhoneStyle.Ink.title)
                                .lineLimit(1)
                                .privacySensitive()
                            Spacer(minLength: 4)
                            Text(conversation.date, style: .date)
                                .font(.caption)
                                .foregroundStyle(PhoneStyle.Ink.meta)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if conversation.id != conversations.last?.id { Divider() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(WidgetLink.library.url)
    }
}

#if DEBUG
#Preview("Recent, small", as: .systemSmall) {
    RecentConversationsWidget()
} timeline: {
    RecentConversationsEntry.preview
}

#Preview("Recent, medium", as: .systemMedium) {
    RecentConversationsWidget()
} timeline: {
    RecentConversationsEntry.preview
}

#Preview("Recent, large", as: .systemLarge) {
    RecentConversationsWidget()
} timeline: {
    RecentConversationsEntry.preview
}

#Preview("Empty library", as: .systemMedium) {
    RecentConversationsWidget()
} timeline: {
    RecentConversationsEntry(date: .now, snapshot: SharedRecentConversations())
}
#endif
