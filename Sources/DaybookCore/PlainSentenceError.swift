import Foundation

/// An error whose description is a sentence of Daybook's own, written for people: what happened, often with what to
/// do, shown as it is (docs/interface.md, principle 7). The system's errors aren't, so where one is shown it gets a
/// sentence of its own and its words go behind Details (DaybookKit's `ProblemWords`, both apps' alerts and notices).
///
/// A kind that sometimes carries the system's words says which (`isPlainSentence`); one with more to say than its
/// sentence (the step that failed, the reason a save gave) puts it in `plainDetails`.
public protocol PlainSentenceError: Error {
    /// Whether `localizedDescription` is such a sentence. Most of Daybook's errors always are.
    var isPlainSentence: Bool { get }
    /// What goes behind Details: the step that failed, or the system's words this error carries.
    var plainDetails: String? { get }
}

extension PlainSentenceError {
    public var isPlainSentence: Bool { true }
    public var plainDetails: String? { nil }
}

extension LibraryError: PlainSentenceError {}
extension PhotoStoreError: PlainSentenceError {}
extension LibrarySyncError: PlainSentenceError {}
extension AudioFetchError: PlainSentenceError {}

extension DaybookError: PlainSentenceError {
    /// A failed save carries the system's words, which go behind Details; the others are sentences of Daybook's own.
    public var isPlainSentence: Bool {
        if case .saveFailed = self { return false }
        return true
    }

    public var plainDetails: String? {
        if case .saveFailed(let reason) = self { return reason }
        return nil
    }
}
