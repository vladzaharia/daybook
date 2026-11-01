import DaybookCore
import Foundation

/// A processing failure in plain words, the same on both apps: a title, and one sentence with what happened and
/// where, from its kind (`ProcessingRequest.FailureKind`), never from the device's own words, which stay behind
/// Details. Daybook's own sentences and the cloud's (`CloudError`) already say what happened and what to do, so they
/// pass through. Whatever happened, the recording is saved, and the sentence says so once.
public struct FailureWords: Equatable, Sendable {
    public var title: String
    public var message: String

    public init(title: String, message: String) { self.title = title; self.message = message }

    /// The one phrase every failure ends with.
    public static let saved = "The recording is saved."

    /// `failure` as `words` would say it: the device that failed is "this Mac", "this iPhone", or its name ("Studio
    /// Mac"); one not known is `words.unknown`.
    public init(_ failure: ProcessingStatus.Failure, words: DeviceWords) {
        self.init(kind: failure.kind, reason: failure.reason, hadTranscripts: failure.hadTranscripts,
                  device: words.name(of: failure.device))
    }

    /// The same from its parts: `device` is already "this Mac" or a name.
    public init(kind: ProcessingRequest.FailureKind, reason: String, hadTranscripts: Bool, device: String) {
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let plain = reason.isEmpty ? nil : (reason.hasSuffix(".") || reason.hasSuffix("?") || reason.hasSuffix("!") ? reason : reason + ".")
        func ending(_ sentence: String) -> String { sentence + " " + Self.saved }
        switch kind {
        case .noSpeech:
            title = "No speech in this recording"
            message = Self.saved
        case .recordingDidNotStart:
            title = "Recording didn’t start"
            message = plain ?? "Nothing was recorded."
        case .modelsMissing:
            title = Self.couldntFinish(hadTranscripts)
            message = ending("The models it needs aren’t on \(device) yet.")
        case .modelCouldNotStart:
            title = Self.couldntFinish(hadTranscripts)
            message = ending("The \(hadTranscripts ? "summary" : "speech") model couldn’t start on \(device).")
        case .cloud(let cloud):
            title = "Couldn’t finish summarizing"
            message = ending(plain ?? Self.cloudSentence(cloud))
        case .plainReason:
            title = Self.couldntFinish(hadTranscripts)
            message = ending(plain ?? "Something went wrong on \(device).")
        case .other:
            title = Self.couldntFinish(hadTranscripts)
            message = ending("Something went wrong on \(device).")
        }
    }

    /// "Couldn’t finish transcribing", or "summarizing" once transcripts were made.
    public static func couldntFinish(_ hadTranscripts: Bool) -> String {
        "Couldn’t finish \(hadTranscripts ? "summarizing" : "transcribing")"
    }

    /// A cloud failure with no words of its own (an older record): what kind of trouble it was.
    static func cloudSentence(_ cloud: ProcessingRequest.FailureKind.CloudFailure) -> String {
        switch cloud {
        case .badKey: return "The cloud didn’t accept the key."
        case .noCredit: return "The cloud account is out of credit."
        case .modelUnavailable: return "The key can’t use this model."
        case .offline: return "You’re offline."
        case .rateLimited: return "The cloud is limiting requests from this key. Try again in a minute."
        case .busy: return "The cloud is busy. Try again in a few minutes."
        case .connectionLost: return "The connection to the cloud was lost."
        case .other: return "The cloud couldn’t summarize it."
        }
    }
}

extension CloudError: ProcessingFailureClassifying {
    /// What a failed summary records: the kinds that call for different fixes (Settings › Cloud for a key or credit,
    /// Try Again for the passing ones). The sentence (`message`) is stored as the reason and shown as it is.
    public var failureKind: ProcessingRequest.FailureKind {
        switch self {
        case .noKey, .badKey: return .cloud(.badKey)
        case .noCredit: return .cloud(.noCredit)
        case .modelUnavailable: return .cloud(.modelUnavailable)
        case .offline: return .cloud(.offline)
        case .rateLimited: return .cloud(.rateLimited)
        case .busy: return .cloud(.busy)
        case .connectionLost: return .cloud(.connectionLost)
        case .refused, .tooLong, .rejected, .unreadable: return .cloud(.other)
        }
    }
}
