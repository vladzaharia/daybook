import Foundation

// What live captions say on both apps: who a line is from, how a run of lines reads as a turn, what a
// captioner is doing before there's anything to read, and what Settings says about the language.

extension LiveCaptionSource {
    /// "You" or "Call", as the recording surfaces and the input levels name this device's own sources.
    public var label: String {
        switch self {
        case .microphone: return "You"
        case .call: return "Call"
        default: return "Captions"
        }
    }
}

/// How a caption's source is named: You and Call for this device's own, the device for another's.
public enum LiveCaptionLabels {
    /// "You", "Call", or the device that heard it (`names`: other devices' names by source, raw value).
    public static func label(for source: LiveCaptionSource?, names: [String: String]) -> String {
        guard let source else { return "Captions" }
        return names[source.rawValue] ?? source.label
    }

    /// What a strip shows in its source lane: You or Call for this device's own sources; nothing for a
    /// single source or another device's line.
    public static func lane(_ segment: LiveCaptionSegment) -> String? {
        guard let source = segment.source, !source.isDevice else { return nil }
        return source.label
    }

    /// What goes before a line's words: the person live speakers recognized, else, for another device's
    /// line, the device ("Soundcore", "iPhone").
    public static func speaker(_ segment: LiveCaptionSegment, names: [String: String]) -> String? {
        if let name = segment.speaker?.name { return name }
        guard segment.source?.isDevice == true else { return nil }
        return label(for: segment.source, names: names)
    }
}

/// A run of consecutive captions from one source and voice, read like a turn in the transcript.
public struct LiveCaptionTurn: Identifiable, Equatable, Sendable {
    public var source: LiveCaptionSource?
    /// The voice live speakers heard ("S2"), and its name when it matched someone's voice profile.
    public var speaker: LiveCaptionSpeaker?
    public var segments: [LiveCaptionSegment]
    /// The source's name: "You", "Call", or the device that heard it.
    public var sourceLabel: String
    public var id: UUID { segments[0].id }
    public var start: TimeInterval { segments[0].start }
    /// The person when live speakers named them, else the source ("You", "Call", "Soundcore").
    public var label: String { speaker?.name ?? sourceLabel }

    public static func turns(_ segments: [LiveCaptionSegment], names: [String: String] = [:]) -> [LiveCaptionTurn] {
        var turns: [LiveCaptionTurn] = []
        for segment in segments where !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let last = turns.last, last.source == segment.source, last.speaker?.slot == segment.speaker?.slot,
               last.speaker?.name == segment.speaker?.name {
                turns[turns.count - 1].segments.append(segment)
            } else {
                turns.append(LiveCaptionTurn(source: segment.source, speaker: segment.speaker, segments: [segment],
                                             sourceLabel: LiveCaptionLabels.label(for: segment.source, names: names)))
            }
        }
        return turns
    }
}

/// What a captioner is doing, in the sentence a recording surface shows while there's nothing to read yet.
public enum LiveCaptionStatus {
    public static func line(_ state: LiveCaptionState, locale: Locale) -> String? {
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

/// The languages live captions can be asked for on a device, and what Settings says about the choice.
/// The Speech framework captions where it exists (macOS 26, every iPhone Daybook runs on); a downloaded
/// live recognizer captions the languages it covers, on any system, and goes first where it covers the
/// language.
public enum LiveCaptionLanguages {
    /// Captions can run here: the Speech framework, or a downloaded live recognizer.
    public static func supported(systemCaptions: Bool, liveLanguages: [String]) -> Bool { systemCaptions || !liveLanguages.isEmpty }

    /// The Speech framework's languages with those the downloaded live recognizers cover that it doesn't,
    /// by name after its own. A language chosen earlier that's no longer offered (its model was removed)
    /// stays listed, so the choice still reads and the footer can say why it's quiet.
    public static func options(speech: [Locale], live: [String], selected: String?) -> [Locale] {
        let covered = Set(speech.compactMap { $0.language.languageCode?.identifier.lowercased() })
        let added = live.filter { !covered.contains($0.lowercased()) }.map { Locale(identifier: $0) }
            .sorted { LiveCaptionAvailability.name($0) < LiveCaptionAvailability.name($1) }
        var options = speech + added
        if let selected, !options.contains(where: { $0.identifier == selected }) { options.append(Locale(identifier: selected)) }
        return options
    }

    /// The footer, only while captions are on: why they can't run here, why they won't in the chosen
    /// language, or what the Speech framework still has to download. Nil when a downloaded recognizer
    /// covers the language, or there's nothing to say.
    public static func footer(systemCaptions: Bool, liveLanguages: [String], liveCovers: Bool, enabled: Bool, locale: Locale,
                              availability: LiveCaptionAvailability?) -> String? {
        guard supported(systemCaptions: systemCaptions, liveLanguages: liveLanguages) else {
            return "Live captions need macOS 26, or Live transcription from Settings › Models."
        }
        guard enabled, !liveCovers else { return nil }
        guard systemCaptions else { return "Live transcription doesn’t cover \(LiveCaptionAvailability.name(locale))." }
        switch availability {
        case .needsDownload(let locale)?:
            return "Captions for \(LiveCaptionAvailability.name(locale)) download the first time you record with them on."
        case .unavailable(let reason)?: return reason
        case .ready?, nil: return nil
        }
    }
}

extension LiveCaptionAvailability {
    /// Whether this system has the Speech framework's live recognizer (`SpeechAnalyzer`: macOS 26, iOS 26).
    public static var systemSupportsCaptions: Bool {
        if #available(macOS 26, iOS 26, *) { return true } else { return false }
    }
}
