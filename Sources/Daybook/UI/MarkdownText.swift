import SwiftUI

// A summary's Markdown is drawn by DaybookUI's `SummaryBody`, the same as on the iPhone: its blocks are read once per
// source (`SummaryMarkdown.blocks`), and its inline Markdown has its links dropped (`ModelText.inlineMarkdown`).

/// The library search's text, so the page can mark its matches.
struct FindQueryKey: EnvironmentKey { static let defaultValue = "" }
extension EnvironmentValues {
    var findQuery: String {
        get { self[FindQueryKey.self] }
        set { self[FindQueryKey.self] = newValue }
    }
}
