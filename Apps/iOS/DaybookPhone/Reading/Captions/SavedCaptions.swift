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
