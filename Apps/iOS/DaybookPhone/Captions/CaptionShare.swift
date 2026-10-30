import DaybookCaptions
import DaybookLink
import Foundation

/// What this iPhone's captions of a shared recording send to one Mac recording it too: the lines that
/// changed since it last sent (`LinkCaptions`), so an hour's captions cost the link a few lines a
/// second. A recorder's lines say which recorder heard them.
struct CaptionShare {
    private var sent: [UUID: LinkCaptions.Line] = [:]

    mutating func changes(_ segments: [LiveCaptionSegment], names: [String: String]) -> [LinkCaptions.Line] {
        var changed: [LinkCaptions.Line] = []
        for segment in segments {
            let device = segment.source.flatMap { $0.isDevice ? names[$0.rawValue] ?? "Recorder" : nil }
            let line = LinkCaptions.Line(id: segment.id, start: segment.start, end: segment.end, text: segment.text,
                                         isTentative: segment.isTentative, speakerSlot: segment.speaker?.slot,
                                         speakerName: segment.speaker?.name, device: device)
            guard sent[segment.id] != line else { continue }
            sent[segment.id] = line
            changed.append(line)
        }
        return changed
    }
}
