import DaybookCore
import Foundation

/// Something the person asked for that couldn't be done, in the words both apps show it with (the Mac's window alert,
/// the iPhone's alerts and notices): a title that names it ("Couldn’t Import Audio"), one plain sentence with what to
/// do, and the system's own words only behind Details (docs/interface.md, principle 7).
public struct ProblemWords: Equatable, Sendable {
    public var title: String
    public var message: String
    /// Behind Details; never empty, and never the message again.
    public var details: String?

    public init(title: String, message: String, details: String? = nil) {
        self.title = title
        self.message = message
        self.details = details.flatMap { $0.isEmpty || $0 == message ? nil : $0 }
    }

    /// Daybook's own errors (`PlainSentenceError`) already say what happened and what to do, so they're the message; the
    /// system's aren't, so they get `fallback` and keep their words for Details. `title` is the alert's, where there's
    /// one.
    public init(title: String = "", fallback: String, error: Error?) {
        guard let error else {
            self.init(title: title, message: fallback)
            return
        }
        let own = error as? any PlainSentenceError
        if let own, own.isPlainSentence {
            self.init(title: title, message: error.localizedDescription, details: own.plainDetails)
        } else {
            self.init(title: title, message: fallback, details: own?.plainDetails ?? error.localizedDescription)
        }
    }
}
