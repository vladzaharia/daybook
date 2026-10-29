import DaybookCaptions
import DaybookCore
import DaybookKit
import SwiftUI

extension LiveCaptionSource {
    /// "You" or "Call", as the recording surfaces and the input levels name them.
    var label: String {
        switch self {
        case .microphone: return "You"
        case .call: return "Call"
        default: return "Captions"
        }
    }
}

/// A run of consecutive captions from one source and voice, read like a turn in the transcript.
struct LiveCaptionTurn: Identifiable, Equatable {
    var source: LiveCaptionSource?
    /// The voice live speakers heard ("S2"), and its name when it matched someone's voice profile.
    var speaker: LiveCaptionSpeaker?
    var segments: [LiveCaptionSegment]
    var id: UUID { segments[0].id }
    var start: TimeInterval { segments[0].start }
    /// The person when live speakers named them, else the source ("You", "Call").
    var label: String { speaker?.name ?? source?.label ?? "Captions" }

    static func turns(_ segments: [LiveCaptionSegment]) -> [LiveCaptionTurn] {
        var turns: [LiveCaptionTurn] = []
        for segment in segments where !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let last = turns.last, last.source == segment.source, last.speaker?.slot == segment.speaker?.slot,
               last.speaker?.name == segment.speaker?.name { turns[turns.count - 1].segments.append(segment) }
            else { turns.append(LiveCaptionTurn(source: segment.source, speaker: segment.speaker, segments: [segment])) }
        }
        return turns
    }
}

/// Live captions in sentences a recording surface can show while there are none to read yet.
enum LiveCaptionStatus {
    static func line(_ state: LiveCaptionState, locale: Locale) -> String? {
        switch state {
        case .preparing: return "Getting captions ready…"
        case .downloading(let fraction):
            let percent = fraction.map { " · \(Int($0 * 100))%" } ?? ""
            return "Downloading captions for \(LiveCaptionAvailability.name(locale))\(percent)"
        case .listening: return "Listening…"
        case .failed: return "Captions stopped"
        case .unavailable(let reason): return reason
        case .off, .finished: return nil
        }
    }
}

// MARK: - The conversation page

/// Live captions on the conversation page, after your notes: while this Mac records the
/// conversation, the newest lines as they're heard; afterwards, until the transcript exists,
/// everything captioned. "Live captions · tentative", You and Call labelled, in a lighter ink than
/// a transcript and never editable. Once the transcript lands they're gone.
///
/// It observes the captions itself, so a revised word redraws only this section.
struct LiveCaptionsSection: View {
    @ObservedObject var captions: LiveCaptionsController
    let meeting: Meeting
    let isRecording: Bool
    @State private var saved: LiveCaptions?
    @Environment(\.readingScale) private var scale

    /// While recording, the page keeps the newest lines; the whole set reads after Stop.
    static let liveLines = 8

    private var isLive: Bool { isRecording && captions.isShowing(for: meeting.id) }

    var body: some View {
        Group {
            if isLive {
                section(segments: captions.recent(Self.liveLines), live: true)
            } else if let shown = LiveCaptionStore.shown(saved, for: meeting) {
                section(segments: shown.segments, live: false)
            }
        }
        .task(id: "\(meeting.id)|\(isRecording)|\(captions.lastSave?.timeIntervalSince1970 ?? 0)|\(meeting.transcripts.count)") {
            saved = isRecording ? nil : captions.store.captions(for: meeting.id)
        }
    }

    private func section(segments: [LiveCaptionSegment], live: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // The glyph hangs in the margin, so the heading starts on the text's edge.
            MarginRow {
                Image(systemName: "captions.bubble").font(.system(size: 11 * scale)).foregroundStyle(Ink.meta)
                    .accessibilityHidden(true)
            } content: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Live captions").font(TypeStyle.heading(scale)).foregroundStyle(Ink.secondary)
                    Text("· tentative").font(TypeStyle.body(scale)).foregroundStyle(Ink.meta)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            .padding(.top, Space.s6)
            if live, segments.isEmpty, let status = LiveCaptionStatus.line(captions.state, locale: captions.locale) {
                MarginRow { Text(status).font(TypeStyle.body(scale)).foregroundStyle(Ink.meta) }
                    .padding(.top, Space.s3)
            }
            ForEach(LiveCaptionTurn.turns(segments)) { turn in
                CaptionTurnView(turn: turn, showsTime: !live)
                    .padding(.top, Space.s3)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: segments.map(\.id))
    }
}

/// One source's run of captions: its label (and, once saved, its time in the margin), then each line.
private struct CaptionTurnView: View {
    let turn: LiveCaptionTurn
    let showsTime: Bool
    @Environment(\.readingScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            MarginRow {
                if showsTime {
                    Text(TimeLabel.short(turn.start)).font(TypeStyle.margin(scale)).foregroundStyle(Ink.meta)
                }
            } content: {
                Text(turn.label).font(TypeStyle.speaker(scale)).foregroundStyle(Ink.secondary)
            }
            ForEach(turn.segments) { segment in
                MarginRow {
                    Text(segment.text)
                        .font(TypeStyle.body(scale))
                        .italic(segment.isTentative)
                        .foregroundStyle(segment.isTentative ? Ink.meta : Ink.secondary)
                        .lineSpacing(TypeStyle.bodyLineSpacing(scale))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(turn.label)\(showsTime ? " at \(SpokenTime.format(turn.start))" : ""), tentative: \(turn.segments.map(\.text).joined(separator: " "))")
    }
}

// MARK: - Listen Live

/// Listen Live's captions on a recorder's page: a quiet label, then the newest lines as they arrive,
/// the latest in Body and earlier ones in Secondary, words still being heard in Meta. When captions
/// are off, or can't run on this Mac, it shows nothing.
struct LiveCaptionFeed: View {
    let segments: [LiveCaptionSegment]
    let state: LiveCaptionState
    let locale: Locale
    var lineCount = 6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let content = content {
            VStack(alignment: .leading, spacing: Space.s2) {
                Label("Live captions · tentative", systemImage: "captions.bubble")
                    .font(TypeStyle.statusLead).foregroundStyle(Ink.meta)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Live captions, tentative")
            .accessibilityValue(segments.last?.text ?? "")
        }
    }

    private var content: AnyView? {
        if state == .listening, !segments.isEmpty { return AnyView(lines) }
        guard let line = LiveCaptionStatus.line(state, locale: locale) else { return nil }
        return AnyView(Text(line).font(TypeStyle.status).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true))
    }

    private var lines: some View {
        let recent = Array(segments.suffix(lineCount))
        return VStack(alignment: .leading, spacing: Space.s1) {
            ForEach(Array(recent.enumerated()), id: \.element.id) { index, segment in
                let newest = index == recent.count - 1
                Text(segment.text)
                    .font(TypeStyle.body())
                    .lineSpacing(TypeStyle.bodyLineSpacing())
                    .foregroundStyle(segment.isTentative ? Ink.meta : newest ? Ink.body : Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: recent.map(\.id))
    }
}

// MARK: - Settings

/// Settings › General › Live Captions: on or off and the language, with a plain word on whether
/// they can run here. Asking never downloads anything.
struct LiveCaptionSettingsSection: View {
    @ObservedObject var settings: LiveCaptionSettings
    @State private var availability: LiveCaptionAvailability?
    @State private var locales: [Locale] = []

    /// The Speech framework (macOS 26), or downloaded live models (any macOS).
    private var supported: Bool { MacCaptioners.systemSupportsCaptions || settings.hasLiveModels }

    var body: some View {
        Section {
            Toggle("Show while recording", isOn: $settings.isEnabled)
            .controlSize(.regular)
            .disabled(!supported)
            if supported && settings.isEnabled {
                Picker("Language", selection: $settings.localeIdentifier) {
                    Text("Same as This Mac").tag(String?.none)
                    if !locales.isEmpty { Divider() }
                    ForEach(locales, id: \.identifier) { locale in
                        Text(LiveCaptionAvailability.name(locale)).tag(Optional(locale.identifier))
                    }
                }
            }
        } header: {
            Text("Live Captions")
        } footer: {
            if let footer { SettingsFooter(footer) }
        }
        .task(id: settings.localeIdentifier) {
            guard MacCaptioners.systemSupportsCaptions else { return }
            if locales.isEmpty { locales = await LiveCaptionAvailability.supportedLocales() }
            availability = await LiveCaptionAvailability.check(locale: settings.locale)
        }
    }

    private var footer: String? {
        guard supported else { return "Live captions need macOS 26 or later." }
        guard settings.isEnabled, !settings.hasLiveModels else { return nil }
        switch availability {
        case .needsDownload(let locale)?:
            return "Captions for \(LiveCaptionAvailability.name(locale)) download the first time you record with them on."
        case .unavailable(let reason)?: return reason
        case .ready?, nil: return nil
        }
    }
}
