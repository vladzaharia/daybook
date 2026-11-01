import DaybookCaptions
import DaybookDesign
import Foundation
import SwiftUI

// Live captions as both apps draw them while they're heard: one renderer, DaybookDesign's
// `LiveCaptionStrip`, fed the same way everywhere (Floating Notes, the iPhone's recording screen, a
// recorder's Listen Live on the Mac's device page and the iPhone's status sheet).

extension CaptionLine {
    /// A caption as a strip draws it: You or Call in the source lane; before the words, the person live
    /// speakers recognized, else, for another device's line, the device that heard it.
    public init(_ segment: LiveCaptionSegment, names: [String: String]) {
        self.init(id: segment.id, text: segment.text, isTentative: segment.isTentative,
                  source: LiveCaptionLabels.lane(segment), speaker: LiveCaptionLabels.speaker(segment, names: names))
    }
}

extension LiveCaptionLabels {
    /// A line as a caption strip draws it (`CaptionLine.init(_:names:)`).
    public static func line(_ segment: LiveCaptionSegment, names: [String: String]) -> CaptionLine {
        CaptionLine(segment, names: names)
    }
}

extension LiveCaptionStrip {
    /// Captions as a captioner stands: its newest lines while it listens, else what it's doing, in a
    /// sentence ("Getting captions ready…", "Listening…"). `names`: other devices' names by source.
    public init(segments: [LiveCaptionSegment], state: LiveCaptionState, locale: Locale, names: [String: String] = [:],
                style: CaptionStripStyle) {
        let lines = state == .listening ? segments.suffix(style.lines).map { CaptionLine($0, names: names) } : []
        self.init(lines: lines, status: LiveCaptionStatus.line(state, locale: locale), style: style)
    }

    /// Whether a captioner in `state` has anything to show: lines while it listens, or what it's doing.
    /// Off and finished show nothing at all, not even the label.
    public static func shows(segments: [LiveCaptionSegment], state: LiveCaptionState, locale: Locale) -> Bool {
        (state == .listening && !segments.isEmpty) || LiveCaptionStatus.line(state, locale: locale) != nil
    }
}
