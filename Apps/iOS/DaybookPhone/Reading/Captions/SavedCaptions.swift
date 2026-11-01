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

/// The transcript's page while only live captions exist: DaybookUI's `SavedCaptionsView`, which the
/// Mac shows in the transcript's place too. Times play the recording; the caption under the playhead is
/// marked; nothing is editable.
typealias CaptionRows = DaybookUI.SavedCaptionsView
