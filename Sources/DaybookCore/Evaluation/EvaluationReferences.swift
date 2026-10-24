import Foundation

/// Reference files the evaluation harness reads beside each recording (docs/validation.md,
/// "Evaluating speech models"): plain text, NIST STM (speaker-attributed text), RTTM (speaker
/// turns), and CTM (word times). Lines starting with ";;" or "#" are comments in all of them.
public enum EvaluationReference {
    /// STM: `file channel speaker start end [<label>] transcript`. Segments in file order.
    public struct Segment: Equatable, Sendable {
        public var speaker: String
        public var start: Double
        public var end: Double
        public var text: String
    }

    public static func parseSTM(_ contents: String) -> [Segment] {
        lines(contents).compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 5, let start = Double(fields[3]), let end = Double(fields[4]), end >= start else { return nil }
            var text = fields.count > 5 ? fields[5] : ""
            // An optional "<o,f0,male>" label precedes the words.
            if text.hasPrefix("<"), let close = text.firstIndex(of: ">") { text = String(text[text.index(after: close)...]) }
            let speaker = fields[2]
            // sclite's convention for regions excluded from scoring.
            guard speaker != "inter_segment_gap", !text.contains("ignore_time_segment_in_scoring") else { return nil }
            return Segment(speaker: speaker, start: start, end: end, text: text.trimmingCharacters(in: .whitespaces))
        }
    }

    /// RTTM `SPEAKER file channel start duration <NA> <NA> speaker <NA> <NA>` lines; other types are skipped.
    public static func parseRTTM(_ contents: String) -> [SpeakerSpan] {
        lines(contents).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 8, fields[0] == "SPEAKER", let start = Double(fields[3]), let duration = Double(fields[4]),
                  duration > 0 else { return nil }
            return SpeakerSpan(speaker: fields[7], start: start, end: start + duration)
        }
    }

    /// CTM `file channel start duration word [confidence]` lines.
    public static func parseCTM(_ contents: String) -> [TimedWord] {
        lines(contents).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 5, let start = Double(fields[2]), let duration = Double(fields[3]), duration >= 0 else { return nil }
            return TimedWord(text: fields[4], start: start, end: start + duration)
        }
    }

    /// RTTM text for speaker spans, so a run's diarization can be inspected with other tools.
    public static func rttm(_ spans: [SpeakerSpan], file: String) -> String {
        spans.sorted { $0.start < $1.start }.map {
            "SPEAKER \(file) 1 \(String(format: "%.3f", $0.start)) \(String(format: "%.3f", $0.end - $0.start)) <NA> <NA> \($0.speaker) <NA> <NA>"
        }.joined(separator: "\n") + (spans.isEmpty ? "" : "\n")
    }

    private static func lines(_ contents: String) -> [String] {
        contents.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix(";;") && !$0.hasPrefix("#") }
    }
}
