import DaybookDesign
import SwiftUI
import WidgetKit

/// A Home Screen list. The small size opens its one conversation; larger sizes link each row.
struct RecentConversationsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedRecentConversations.widgetKind, provider: RecentConversationsTimeline()) { entry in
            RecentConversationsWidgetView(entry: entry)
                .containerBackground(for: .widget) { DaybookPalette.paper }
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
    /// The snapshot is there but can't be read until the iPhone is unlocked ("Protect while iPhone is locked"): the
    /// widget shows its heading and nothing else.
    var locked = false

    static var preview: Self {
        let now = Date()
        let titles = ["Design review", "Weekly product sync", "Project kickoff", "Planning session", "Team check-in", "Ideas"]
        let conversations = titles.enumerated().map { index, title in
            SharedRecentConversations.Conversation(id: UUID(), title: title, date: now.addingTimeInterval(-Double(index) * 86_400))
        }
        return Self(date: now, snapshot: SharedRecentConversations(conversations))
    }
}

extension RecentConversationsEntry {
    init(date: Date, read: SharedWidgetCache.Read<SharedRecentConversations>) {
        switch read {
        case .value(let snapshot): self.init(date: date, snapshot: snapshot)
        case .missing: self.init(date: date, snapshot: nil)
        case .locked: self.init(date: date, snapshot: nil, locked: true)
        }
    }
}

struct RecentConversationsTimeline: TimelineProvider {
    func placeholder(in context: Context) -> RecentConversationsEntry { .preview }

    func getSnapshot(in context: Context, completion: @escaping (RecentConversationsEntry) -> Void) {
        completion(context.isPreview ? .preview : RecentConversationsEntry(date: .now, read: SharedRecentConversations.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecentConversationsEntry>) -> Void) {
        let entry = RecentConversationsEntry(date: .now, read: SharedRecentConversations.read())
        // The app reloads this timeline when the loaded library's visible metadata changes; one read while the iPhone
        // was locked reads again in a while.
        completion(Timeline(entries: [entry], policy: entry.locked ? .after(.now.addingTimeInterval(SharedWidgetCache.lockedRetry)) : .never))
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
                .foregroundStyle(DaybookPalette.Ink.secondary)
            Spacer(minLength: 4)
            if let conversation {
                Text(conversation.title)
                    .font(DaybookType.title(.headline))
                    .foregroundStyle(DaybookPalette.Ink.title)
                    .lineLimit(3)
                    .privacySensitive()
                Text(conversation.date, style: .date)
                    .font(.caption)
                    .foregroundStyle(DaybookPalette.Ink.meta)
            } else if !entry.locked {
                Text(emptyTitle)
                    .font(.headline)
                    .foregroundStyle(DaybookPalette.Ink.title)
                Text(emptyMessage)
                    .font(.caption)
                    .foregroundStyle(DaybookPalette.Ink.secondary)
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
                .font(DaybookType.title(.headline))
                .foregroundStyle(DaybookPalette.Ink.title)
                .lineLimit(1)
                .padding(.bottom, 4)
            if entry.locked {
                Spacer(minLength: 0)
            } else if conversations.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(emptyTitle).font(.subheadline.weight(.semibold))
                    Text(emptyMessage).font(.caption).foregroundStyle(DaybookPalette.Ink.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                ForEach(conversations) { conversation in
                    Link(destination: WidgetLink.conversation(conversation.id).url) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(conversation.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(DaybookPalette.Ink.title)
                                .lineLimit(1)
                                .privacySensitive()
                            Spacer(minLength: 4)
                            Text(conversation.date, style: .date)
                                .font(.caption)
                                .foregroundStyle(DaybookPalette.Ink.meta)
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
