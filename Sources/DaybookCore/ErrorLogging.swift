import Foundation

extension Error {
    /// The error's domain and code ("NSCocoaErrorDomain 513"), for a log to show in public. Its description stays
    /// private: a Cocoa error names the file, and a library error can hold a path, so a conversation's name or a
    /// person's words would otherwise reach a sysdiagnose.
    public var logCode: String {
        let error = self as NSError
        return "\(error.domain) \(error.code)"
    }
}
