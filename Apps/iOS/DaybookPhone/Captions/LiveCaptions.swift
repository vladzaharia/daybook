import DaybookCaptions
import DaybookKit
import DaybookUI
import Foundation

// The caption models (`LiveCaptionSegment`, `LiveCaptions`), the engine, the store, and what both apps
// do with a recording's captions (`LiveCaptionSession`) live in the shared DaybookCaptions library;
// reading them (`SavedCaptions`, `SavedCaptionsView`) in DaybookUI. These names reach the files that
// don't import those libraries.

/// Where this iPhone keeps the live captions it made: DaybookCaptions' store, the Mac's too.
typealias LiveCaptionStore = DaybookCaptions.LiveCaptionStore
/// Saved captions as reading shows them, the same on the Mac.
typealias SavedCaptions = DaybookUI.SavedCaptions

extension Meeting {
    /// Whether saved live captions may stand in for this conversation's transcript: it has none to read
    /// yet. A cheap check before reading them; `SavedCaptions.shown` decides, by the one rule both apps
    /// share (a transcript made after the captions began replaces them).
    var showsLiveCaptions: Bool { SavedCaptions.mayStandIn(for: self) }
}
