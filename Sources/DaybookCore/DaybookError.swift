import Foundation

/// Why the library couldn't take something: the library's main error, beside `LibraryError`. Device
/// imports throw and recognize these too (DaybookDevices names this type for its own code); the Mac
/// app calls them `AppError`.
public enum DaybookError: LocalizedError {
    case libraryUnavailable, invalidAudio(String), noSpeech, saveFailed(String)
    public var errorDescription: String? {
        switch self {
        case .saveFailed(let message): return "Couldn’t save changes: " + message
        case .libraryUnavailable: return "Your library is not available yet."
        case .invalidAudio(let name): return "\(name) contains no readable audio."
        case .noSpeech: return "No speech was recognized."
        }
    }
}

extension DaybookError: ProcessingFailureClassifying {
    /// What a failed request records (`ProcessingRequest.FailureKind`): no speech is its own kind, so rewording its
    /// sentence never turns a silent recording into one that offers Try Again. A library that isn't there yet and
    /// audio that can't be read say what happened in a plain sentence, shown as it is; a failed save carries the
    /// system's words, which stay behind Details.
    public var failureKind: ProcessingRequest.FailureKind {
        switch self {
        case .noSpeech: return .noSpeech
        case .libraryUnavailable, .invalidAudio: return .plainReason
        case .saveFailed: return .other
        }
    }
}
