import SwiftUI
import WidgetKit

/// A glanceable Home Screen list; every action leads to its own conversation.
struct NextStepsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedNextSteps.widgetKind, provider: NextStepsTimeline()) { entry in
            NextStepsWidgetView(entry: entry)
                .containerBackground(for: .widget) { PhoneStyle.paper }
        }
        .configurationDisplayName("Next Steps")
        .description("Open unfinished action items from your conversations.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct NextStepsEntry: TimelineEntry {
    let date: Date
    /// Nil until a loaded library has been published.
    let snapshot: SharedNextSteps?

    static var preview: Self {
        let now = Date(), first = UUID(), second = UUID()
        return Self(date: now, snapshot: SharedNextSteps([
            .init(meetingID: first, title: "Design review", date: now, text: "Share the updated mockups"),
            .init(meetingID: first, title: "Design review", date: now, text: "Schedule a follow-up"),
            .init(meetingID: second, title: "Project kickoff", date: now, text: "Send the project brief")
        ]))
    }
}

struct NextStepsTimeline: TimelineProvider {
    func placeholder(in context: Context) -> NextStepsEntry { .preview }

    func getSnapshot(in context: Context, completion: @escaping (NextStepsEntry) -> Void) {
        completion(context.isPreview ? .preview : NextStepsEntry(date: .now, snapshot: SharedNextSteps.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextStepsEntry>) -> Void) {
        let entry = NextStepsEntry(date: .now, snapshot: SharedNextSteps.load())
        // The app reloads when the bounded projection changes, not when unrelated library content changes.
        completion(Timeline(entries: [entry], policy: .never))
    }
}

private struct NextStepsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NextStepsEntry

    var body: some View {
        if family == .systemSmall { small } else { list }
    }

    private var emptyTitle: String {
        entry.snapshot == nil ? "Open Daybook" : "No next steps"
    }

    private var emptyMessage: String {
        entry.snapshot == nil ? "Load your library to see next steps." : "Unfinished actions appear here."
    }

    private var small: some View {
        let item = entry.snapshot?.items.first
        return VStack(alignment: .leading, spacing: 6) {
            Label("Next Steps", systemImage: "checklist")
                .font(.caption.weight(.semibold))
                .foregroundStyle(PhoneStyle.Ink.secondary)
            Spacer(minLength: 4)
            if let item {
                Text(item.text)
                    .font(PhoneStyle.Typeface.title(.headline))
                    .foregroundStyle(PhoneStyle.Ink.title)
                    .lineLimit(3)
                    .privacySensitive()
                Text(item.title)
                    .font(.caption)
                    .foregroundStyle(PhoneStyle.Ink.secondary)
                    .lineLimit(2)
                    .privacySensitive()
            } else {
                Text(emptyTitle).font(.headline).foregroundStyle(PhoneStyle.Ink.title)
                Text(emptyMessage).font(.caption).foregroundStyle(PhoneStyle.Ink.secondary).lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(item.map { WidgetLink.conversation($0.meetingID).url } ?? WidgetLink.library.url)
    }

    private var list: some View {
        let items = Array((entry.snapshot?.items ?? []).prefix(family == .systemMedium ? 3 : 6))
        return VStack(alignment: .leading, spacing: 0) {
            Label("Next Steps", systemImage: "checklist")
                .font(PhoneStyle.Typeface.title(.headline))
                .foregroundStyle(PhoneStyle.Ink.title)
                .lineLimit(1)
                .padding(.bottom, 4)
            if items.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(emptyTitle).font(.subheadline.weight(.semibold))
                    Text(emptyMessage).font(.caption).foregroundStyle(PhoneStyle.Ink.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                ForEach(items.indices, id: \.self) { index in
                    let item = items[index]
                    // Large groups consecutive actions under one conversation; medium names every row.
                    let showTitle = family == .systemMedium || index == 0 || items[index - 1].meetingID != item.meetingID
                    Link(destination: WidgetLink.conversation(item.meetingID).url) {
                        VStack(alignment: .leading, spacing: 2) {
                            if showTitle {
                                Text(item.title)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(PhoneStyle.Ink.secondary)
                                    .lineLimit(1)
                                    .privacySensitive()
                            }
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: "circle").font(.caption2)
                                Text(item.text)
                                    .font(.caption)
                                    .foregroundStyle(PhoneStyle.Ink.title)
                                    .lineLimit(1)
                                    .privacySensitive()
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < items.count - 1 && (family == .systemMedium || items[index + 1].meetingID != item.meetingID) {
                        Divider()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(WidgetLink.library.url)
    }
}

#if DEBUG
#Preview("Next Steps, small", as: .systemSmall) {
    NextStepsWidget()
} timeline: {
    NextStepsEntry.preview
}

#Preview("Next Steps, medium", as: .systemMedium) {
    NextStepsWidget()
} timeline: {
    NextStepsEntry.preview
}

#Preview("Next Steps, large", as: .systemLarge) {
    NextStepsWidget()
} timeline: {
    NextStepsEntry.preview
}

#Preview("No next steps", as: .systemMedium) {
    NextStepsWidget()
} timeline: {
    NextStepsEntry(date: .now, snapshot: SharedNextSteps())
}
#endif
