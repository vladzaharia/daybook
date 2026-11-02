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
/// Saved captions as reading shows them, by the Mac's rule too.
typealias SavedCaptions = DaybookUI.SavedCaptions
