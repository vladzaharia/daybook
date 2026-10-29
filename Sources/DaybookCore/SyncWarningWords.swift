import Foundation

/// How a sync pass words a problem it carried on past: one plain sentence for the person, and the
/// system's own words after it for Details. Daybook's own sync errors already say what happened in
/// plain words, so they're the whole warning.
public enum SyncWarningWords {
    public static let unreadHistory = "Part of the library’s history couldn’t be read yet"
    public static let unsavedChange = "A change couldn’t be saved to iCloud yet"
    public static let unappliedConversation = "A conversation couldn’t be brought up to date yet"
    public static let undownloadedHistory = "Part of the library couldn’t be downloaded yet"
    /// An entry that won't read however often it's tried (damaged, or not what its name says); a relaunch tries again.
    public static let damagedHistory = "Part of the library’s history in iCloud is damaged and was skipped"
    /// A recording here that differed from the copy sync installed: both are kept, where behind Details.
    public static let keptBothRecordings = "A recording here differed from its copy in iCloud, so both are kept"

    static let heads = [unreadHistory, unsavedChange, unappliedConversation, undownloadedHistory, damagedHistory, keptBothRecordings]

    /// "<head>: <the system's words>", or the error alone when it's one of Daybook's plain sentences.
    public static func compose(_ head: String, _ error: Error) -> String {
        if let error = error as? LibrarySyncError, error.isPlainSentence { return error.localizedDescription }
        // Waiting for a download or for the library's key: Daybook's own words, nothing behind them.
        if error is SyncPendingDownload || error is SyncKeyPending { return error.localizedDescription }
        return compose(head, details: error.localizedDescription)
    }

    /// "<head>: <details>".
    public static func compose(_ head: String, details: String) -> String { "\(head): \(details)" }

    /// The sentence to show and the words for Details. Only warnings `compose` made are split, so a
    /// conversation title with a colon in another warning is never cut.
    public static func split(_ warning: String) -> (text: String, details: String?) {
        for head in heads where warning.hasPrefix(head + ": ") {
            let details = String(warning.dropFirst(head.count + 2))
            return (head + ".", details.isEmpty ? nil : details)
        }
        return (warning, nil)
    }
}
