import DaybookCore
import Foundation

enum TranscriptBuilder {
    static func segments(result: RecognitionResult, speakers: SpeakerAnalysis?, track: RecordingTrack, runID: UUID? = nil) -> [TranscriptSegment] {
        func speaker(_ start: Double, _ end: Double) -> String? {
            guard let turns = speakers?.turns else { return nil }
            let scored = turns.map { ($0, max(0, min(end, $0.end) - max(start, $0.start))) }
            guard let match = scored.max(by: { $0.1 < $1.1 }), match.1 > 0 else { return nil }
            return "\(runID?.uuidString ?? track.id.uuidString):\(match.0.speakerID)"
        }
        var output: [TranscriptSegment] = []
        for segment in result.segments {
            guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if speakers != nil, !segment.words.isEmpty {
                var group: TranscriptSegment?
                for word in segment.words {
                    let id = speaker(word.start, word.end)
                    if var existing = group, existing.speakerID == id, word.start - existing.end < 2 {
                        existing.text += word.text
                        existing.end = max(existing.end, word.end)
                        group = existing
                    } else {
                        if let group { output.append(group) }
                        group = TranscriptSegment(trackID: track.id, start: word.start, end: word.end, text: word.text, speakerID: id, confidence: word.confidence)
                    }
                }
                if let group { output.append(group) }
            } else {
                output.append(TranscriptSegment(trackID: track.id, start: segment.start, end: segment.end,
                    text: segment.text, speakerID: speaker(segment.start, segment.end), confidence: segment.confidence))
            }
        }
        return output.map { var value = $0; value.text = value.text.trimmingCharacters(in: .whitespacesAndNewlines); return value }.filter { !$0.text.isEmpty }
    }
}
