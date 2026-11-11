import DaybookDesign
import SwiftUI
import WidgetKit

/// A timeless shortcut: a tap opens the app's existing New Note destination.
struct NewNoteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "local.daybook.phone.new-note", provider: NewNoteTimeline()) { _ in
            NewNoteWidgetView()
                .containerBackground(for: .widget) { DaybookPalette.paper }
        }
        .configurationDisplayName("New Note")
        .description("Start a note in Daybook.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryInline])
    }
}

struct NewNoteEntry: TimelineEntry {
    let date: Date
}

struct NewNoteTimeline: TimelineProvider {
    func placeholder(in context: Context) -> NewNoteEntry { NewNoteEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (NewNoteEntry) -> Void) {
        completion(NewNoteEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NewNoteEntry>) -> Void) {
        completion(Timeline(entries: [NewNoteEntry(date: .now)], policy: .never))
    }
}

private struct NewNoteWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "square.and.pencil").font(.title2)
                }
                .widgetAccentable()
                .accessibilityLabel("New Note")
            case .accessoryInline:
                Label("New Note", systemImage: "square.and.pencil")
            default:
                VStack(alignment: .leading, spacing: 8) {
                    Text("Daybook")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DaybookPalette.Ink.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: "square.and.pencil")
                        .font(.title2)
                        .foregroundStyle(DaybookPalette.Ink.title)
                    Text("New Note")
                        .font(DaybookType.title(.headline))
                        .foregroundStyle(DaybookPalette.Ink.title)
                    Text("Open a blank note")
                        .font(.caption)
                        .foregroundStyle(DaybookPalette.Ink.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .widgetURL(WidgetLink.newNote.url)
    }
}

#if DEBUG
#Preview("New Note, small", as: .systemSmall) {
    NewNoteWidget()
} timeline: {
    NewNoteEntry(date: .now)
}

#Preview("New Note, circular", as: .accessoryCircular) {
    NewNoteWidget()
} timeline: {
    NewNoteEntry(date: .now)
}

#Preview("New Note, inline", as: .accessoryInline) {
    NewNoteWidget()
} timeline: {
    NewNoteEntry(date: .now)
}
#endif
