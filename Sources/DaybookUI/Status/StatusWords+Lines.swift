import DaybookDesign
import DaybookKit
import Foundation

// The shared words (DaybookKit's `StatusLineWords`: `RecorderStatusWords`, `PeerStatusWords`, `QueueStatusWords`) as
// the line both apps draw (DaybookDesign's `StatusLineItem`), so a status line reads and looks the same wherever it
// shows: the iPhone's status sheet and the Duo's panel, Floating Notes' home, and Settings.

extension StatusTone {
    /// The words' tone as an ink.
    public init(_ tone: StatusLineWords.Tone) {
        switch tone {
        case .calm: self = .calm
        case .working: self = .working
        case .linked: self = .linked
        case .recording: self = .recording
        case .attention: self = .attention
        }
    }
}

extension StatusLineItem {
    /// The line for a status's words, its countdown included.
    public init(_ words: StatusLineWords) {
        self.init(id: words.id, symbol: words.symbol, title: words.title, text: words.text, tone: StatusTone(words.tone),
                  progress: words.progress, shortText: words.shortText, countdownUntil: words.countdownUntil)
    }
}
