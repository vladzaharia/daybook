import DaybookCaptions
import DaybookKit
import DaybookUI
import SwiftUI

extension EnvironmentValues {
    /// Where saved live captions are read from. Set by `LibraryBrowser`; nil shows none.
    @Entry var liveCaptionStore: LiveCaptionStore? = nil
    /// When saved captions last changed (speakers labelled afterwards), so an open page reads them again.
    @Entry var liveCaptionsSaved: Date? = nil
}

/// Saved live captions on the transcript's page, in its place or after it: DaybookUI's
/// `SavedCaptionsView`, which the Mac shows the same way. Times play the recording; the caption under
/// the playhead is marked; nothing is editable.
typealias CaptionRows = DaybookUI.SavedCaptionsView
