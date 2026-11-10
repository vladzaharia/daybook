import DaybookCaptions
import DaybookLink
import Foundation

/// What one device's captions of a shared recording send to another device recording it too
/// (`LinkCaptions`): the lines that changed since it last sent, and the IDs of those it no longer has (a
/// recognizer took back words it was still revising), so an hour's captions cost the link a few lines a
/// second and a retracted line leaves the other device too. A recorder's lines say which recorder heard
/// them. An iPhone sends its own and its recorders' lines to a Mac; a Mac sends its call's to an iPhone.
public struct CaptionShare: Sendable {
    private var sent: [UUID: LinkCaptions.Line] = [:]

    public init() {}

    /// `lines`: every line there is to send now (`LiveCaptionSession.forwardable`); `names`: other devices'
    /// names by source (raw value).
    public mutating func changes(_ lines: [LiveCaptionSegment], names: [String: String]) -> (lines: [LinkCaptions.Line], removed: [UUID]) {
        var changed: [LinkCaptions.Line] = []
        var current = Set<UUID>()
        for segment in lines {
            current.insert(segment.id)
            let device = segment.source.flatMap { $0.isDevice ? names[$0.rawValue] ?? "Recorder" : nil }
            let line = LinkCaptions.Line(id: segment.id, start: segment.start, end: segment.end, text: segment.text,
                                         isTentative: segment.isTentative, speakerSlot: segment.speaker?.slot,
                                         speakerName: segment.speaker?.name, device: device)
            guard sent[segment.id] != line else { continue }
            sent[segment.id] = line
            changed.append(line)
        }
        let removed = sent.keys.filter { !current.contains($0) }.sorted { $0.uuidString < $1.uuidString }
        for id in removed { sent[id] = nil }
        return (changed, removed)
    }
}
