import AppIntents
import SwiftUI
import WidgetKit

/// A small Home Screen and Lock Screen widget: Record when idle (with the last conversation),
/// the clock and Bookmark while recording.
struct RecorderWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedRecordingState.widgetKind, provider: RecorderTimeline()) { entry in
            RecorderWidgetView(entry: entry)
                .containerBackground(for: .widget) { PhoneStyle.paper }
        }
        .configurationDisplayName("Recorder")
        .description("Start a recording, or bookmark the one in progress.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct RecorderEntry: TimelineEntry {
    var date: Date
    var state: SharedRecordingState
}

struct RecorderTimeline: TimelineProvider {
    func placeholder(in context: Context) -> RecorderEntry {
        RecorderEntry(date: .now, state: SharedRecordingState())
    }

    func getSnapshot(in context: Context, completion: @escaping (RecorderEntry) -> Void) {
        completion(RecorderEntry(date: .now, state: context.isPreview ? SharedRecordingState() : SharedRecordingState.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecorderEntry>) -> Void) {
        // The app reloads this whenever recording starts, stops, or bookmarks change; clocks count
        // themselves, so one entry is enough.
        completion(Timeline(entries: [RecorderEntry(date: .now, state: SharedRecordingState.load())], policy: .never))
    }
}

struct RecorderWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RecorderEntry

    var body: some View {
        let state = entry.state
        switch family {
        case .accessoryCircular:
            if state.isActive, let start = state.startedAt {
                Button(intent: AddBookmarkIntent()) {
                    VStack(spacing: 0) {
                        Image(systemName: "bookmark.fill")
                        Text(start, style: .timer).font(.caption2.monospacedDigit()).multilineTextAlignment(.center)
                    }
                }
                .buttonStyle(.plain)
            } else {
                Button(intent: StartRecordingIntent()) {
                    ZStack {
                        AccessoryWidgetBackground()
                        Image(systemName: "record.circle").font(.title2)
                    }
                }
                .buttonStyle(.plain)
                .widgetAccentable()
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                if state.isActive, let start = state.startedAt {
                    Label(state.phase == .paused ? "Paused" : "Recording", systemImage: "waveform").font(.headline)
                    Text(start, style: .timer).monospacedDigit()
                    if let multipoint = state.multipoint {
                        Text(multipoint).font(.caption).lineLimit(1)
                    } else if state.bookmarkCount > 0 {
                        Text("\(state.bookmarkCount) bookmarks").font(.caption)
                    }
                } else {
                    Label("Daybook", systemImage: "waveform").font(.headline)
                    Text(lastLine(state) ?? "Tap to record").font(.caption).lineLimit(2)
                }
            }
            .widgetURL(nil)
        case .accessoryInline:
            if state.isActive, let start = state.startedAt {
                Text("Recording \(start, style: .timer)")
            } else {
                Text("Daybook ready")
            }
        default:
            SmallRecorder(state: state)
        }
    }

    private func lastLine(_ state: SharedRecordingState) -> String? {
        guard let title = state.lastRecordingTitle else { return nil }
        return title
    }
}

private struct SmallRecorder: View {
    let state: SharedRecordingState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if state.isActive, let start = state.startedAt {
                HStack(spacing: 6) {
                    Circle().fill(state.phase == .recording ? PhoneStyle.Ink.record : Color.gray).frame(width: 8, height: 8)
                    Text(state.phase == .paused ? "Paused" : "Recording").font(.caption.weight(.semibold))
                }
                Text(start, style: .timer)
                    .font(.title.weight(.semibold).monospacedDigit())
                    .foregroundStyle(state.phase == .recording ? PhoneStyle.Ink.record : PhoneStyle.Ink.title)
                Spacer(minLength: 0)
                Button(intent: AddBookmarkIntent()) {
                    Label(state.bookmarkCount > 0 ? "\(state.bookmarkCount)" : "Bookmark", systemImage: "bookmark.fill")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .tint(PhoneStyle.bookmark)
                .foregroundStyle(PhoneStyle.bookmark)
            } else {
                Text("Daybook").font(PhoneStyle.Typeface.title(17)).foregroundStyle(PhoneStyle.Ink.title)
                if let title = state.lastRecordingTitle {
                    Text(title).font(.caption).foregroundStyle(PhoneStyle.Ink.secondary).lineLimit(2)
                    if let date = state.lastRecordingDate {
                        Text(date, style: .relative).font(.caption2).foregroundStyle(PhoneStyle.Ink.meta)
                    }
                } else {
                    Text("No recordings yet").font(.caption).foregroundStyle(PhoneStyle.Ink.secondary)
                }
                Spacer(minLength: 0)
                Button(intent: StartRecordingIntent()) {
                    HStack(spacing: 6) {
                        Circle().fill(PhoneStyle.Ink.record).frame(width: 8, height: 8)
                        Text("Record").font(.caption.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                }
                .tint(PhoneStyle.Ink.title)
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
    }
}
