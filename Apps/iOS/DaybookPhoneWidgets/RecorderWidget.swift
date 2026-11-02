import AppIntents
import DaybookDesign
import SwiftUI
import WidgetKit

/// The extension links DaybookDesign and not DaybookKit, so the shared files it compiles read times from
/// `DaybookTime`, which has DaybookKit's `TimeLabel` rule (tests hold the two equal).
typealias TimeLabel = DaybookTime

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
    var display: SharedRecordingState.Display { state.display(at: date) }
}

struct RecorderTimeline: TimelineProvider {
    func placeholder(in context: Context) -> RecorderEntry {
        RecorderEntry(date: .now, state: SharedRecordingState())
    }

    func getSnapshot(in context: Context, completion: @escaping (RecorderEntry) -> Void) {
        completion(RecorderEntry(date: .now, state: context.isPreview ? SharedRecordingState() : SharedRecordingState.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecorderEntry>) -> Void) {
        // The app reloads this whenever recording starts, stops, or bookmarks change, and once a
        // minute while it records; clocks count themselves. A second entry turns a recording the app
        // stopped confirming into "Open Daybook to check" on its own.
        let state = SharedRecordingState.load()
        let entries = state.timelineDates(from: .now).map { RecorderEntry(date: $0, state: state) }
        completion(Timeline(entries: entries, policy: .never))
    }
}

/// The recording's clock: counting while recording, frozen while paused.
private struct WidgetClock: View {
    let display: SharedRecordingState.Display

    var body: some View {
        switch display {
        case .recording(let since): Text(since, style: .timer)
        case .paused(let elapsed): Text(DaybookTime.short(elapsed))
        case .idle, .unconfirmed: Text("–")
        }
    }
}

struct RecorderWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RecorderEntry

    var body: some View {
        let state = entry.state
        let display = entry.display
        let active = display != .idle && display != .unconfirmed
        switch family {
        case .accessoryCircular:
            if active {
                // Recording: Bookmark. Paused: Resume once it can, Stop during the call.
                CircularAction(action: WidgetAction(display: display, state: state)) {
                    WidgetClock(display: display).font(.caption2.monospacedDigit()).multilineTextAlignment(.center)
                }
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
                if active {
                    Label(SharedRecordingState.headline(display), systemImage: "waveform").font(.headline)
                    WidgetClock(display: display).monospacedDigit()
                    if let multipoint = state.multipoint {
                        Text(multipoint).font(.caption).lineLimit(1)
                    } else if state.bookmarkCount > 0 {
                        Text(SharedRecordingState.bookmarks(state.bookmarkCount)).font(.caption)
                    }
                } else if display == .unconfirmed {
                    Label(SharedRecordingState.headline(display), systemImage: "waveform").font(.headline)
                } else {
                    Label("Daybook", systemImage: "waveform").font(.headline)
                    if let title = state.lastRecordingTitle {
                        // A conversation's title is private: hidden while the iPhone is locked.
                        Text(title).font(.caption).lineLimit(2).privacySensitive()
                    } else {
                        // As the small widget says it; a tap here opens Daybook rather than recording.
                        Text("No recordings yet").font(.caption).lineLimit(2)
                    }
                }
            }
            .widgetURL(nil)
        case .accessoryInline:
            if case .recording(let since) = display {
                Text("Recording \(since, style: .timer)")
            } else {
                Text(SharedRecordingState.inlineLine(display))
            }
        default:
            SmallRecorder(state: state, display: display)
        }
    }
}

private struct SmallRecorder: View {
    let state: SharedRecordingState
    let display: SharedRecordingState.Display

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch display {
            case .recording, .paused:
                let recording = { if case .recording = display { return true } else { return false } }()
                HStack(spacing: 6) {
                    Circle().fill(recording ? PhoneStyle.Ink.record : Color.gray).frame(width: 8, height: 8)
                    Text(SharedRecordingState.headline(display)).font(.caption.weight(.semibold))
                }
                WidgetClock(display: display)
                    .font(.title.weight(.semibold).monospacedDigit())
                    .foregroundStyle(recording ? PhoneStyle.Ink.record : PhoneStyle.Ink.title)
                Spacer(minLength: 0)
                SmallAction(action: WidgetAction(display: display, state: state), bookmarkCount: state.bookmarkCount)
            case .unconfirmed, .idle:
                if display == .unconfirmed {
                    HStack(spacing: 6) {
                        Circle().fill(Color.gray).frame(width: 8, height: 8)
                        Text(SharedRecordingState.headline(display)).font(.caption.weight(.semibold))
                    }
                } else {
                    Text("Daybook").font(PhoneStyle.Typeface.title(.headline)).foregroundStyle(PhoneStyle.Ink.title)
                }
                if let title = state.lastRecordingTitle {
                    // A conversation's title is private: hidden while the iPhone is locked.
                    Text(title).font(.caption).foregroundStyle(PhoneStyle.Ink.secondary).lineLimit(2).privacySensitive()
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

/// The one thing a widget offers while a recording runs: Bookmark while recording; while paused, Resume
/// once recording can continue, and Stop during the call, when Resume couldn't work.
enum WidgetAction: Equatable {
    case bookmark, resume, stop

    init(display: SharedRecordingState.Display, state: SharedRecordingState) {
        if case .paused = display { self = state.offersResume ? .resume : .stop } else { self = .bookmark }
    }

    var title: String {
        switch self {
        case .bookmark: return "Bookmark"
        case .resume: return "Resume"
        case .stop: return "Stop"
        }
    }

    var systemImage: String {
        switch self {
        case .bookmark: return "bookmark.fill"
        case .resume: return "record.circle"
        case .stop: return "stop.fill"
        }
    }

    var ink: Color {
        switch self {
        case .bookmark: return PhoneStyle.bookmark
        case .resume: return PhoneStyle.Ink.record
        case .stop: return PhoneStyle.Ink.title
        }
    }
}

/// The small widget's button for `action`; its intent runs in the app.
private struct SmallAction: View {
    let action: WidgetAction
    let bookmarkCount: Int

    var body: some View {
        switch action {
        case .bookmark:
            Button(intent: AddBookmarkIntent()) { label(bookmarkCount > 0 ? "\(bookmarkCount)" : action.title) }
                .tint(action.ink)
                .accessibilityLabel(bookmarkCount > 0 ? "Bookmark, \(SharedRecordingState.bookmarks(bookmarkCount))" : "Bookmark")
        case .resume:
            Button(intent: ResumeRecordingIntent()) { label(action.title) }.tint(action.ink)
        case .stop:
            Button(intent: StopRecordingIntent()) { label(action.title) }.tint(action.ink)
        }
    }

    private func label(_ title: String) -> some View {
        Label(title, systemImage: action.systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(action.ink)
            .frame(maxWidth: .infinity)
    }
}

/// The circular Lock Screen widget's button for `action`, its glyph above the clock.
private struct CircularAction<Clock: View>: View {
    let action: WidgetAction
    @ViewBuilder let clock: Clock

    var body: some View {
        switch action {
        case .bookmark: Button(intent: AddBookmarkIntent()) { content }.buttonStyle(.plain)
        case .resume: Button(intent: ResumeRecordingIntent()) { content }.buttonStyle(.plain)
        case .stop: Button(intent: StopRecordingIntent()) { content }.buttonStyle(.plain)
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            Image(systemName: action.systemImage)
            clock
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(action.title)
    }
}
