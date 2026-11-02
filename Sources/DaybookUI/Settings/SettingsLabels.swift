import DaybookKit
import Foundation

extension String {
    /// A Settings label as each platform writes it: the sentence case `SettingsWords` keeps on the Mac, title case
    /// on the iPhone (`SettingsWords.titleCased`).
    var asSettingsLabel: String {
        #if os(iOS)
        SettingsWords.titleCased(self)
        #else
        self
        #endif
    }
}
