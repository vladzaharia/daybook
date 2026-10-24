import Foundation

/// Why the library couldn't take something. Device imports throw and recognize these, so they
/// live below the library itself; the Mac app calls them `AppError`.
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
