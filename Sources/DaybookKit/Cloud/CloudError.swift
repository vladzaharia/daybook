import Foundation

/// Why a cloud request didn't work, as one plain sentence (`message`, also the error's description) and the
/// provider's own words behind Details… (`details`: the HTTP status, the error's type and message, the request
/// ID). Neither ever contains a key: anything in the provider's words that looks like one is masked.
public enum CloudError: Error, Equatable, Sendable, LocalizedError {
    case noKey(CloudProvider)
    case badKey(CloudProvider, details: String)
    case noCredit(CloudProvider, details: String)
    /// The provider's rate limit; `retryAfter` is how long it asked to wait, when it said.
    case rateLimited(CloudProvider, retryAfter: TimeInterval?, details: String)
    /// Overloaded or failing on the provider's side.
    case busy(CloudProvider, details: String)
    /// No internet connection.
    case offline(details: String)
    /// The connection broke, timed out, or never opened.
    case connectionLost(CloudProvider, details: String)
    /// The key can't use this model (gone, or not open to this account).
    case modelUnavailable(CloudProvider, model: String, details: String)
    /// The model declined to write the summary; `category` is the provider's reason, when it gave one.
    case refused(model: String, category: String?, details: String)
    /// The summary ran past the most the model can write, even after raising the limit.
    case tooLong(model: String, details: String)
    /// The provider couldn't take the request as sent.
    case rejected(CloudProvider, details: String)
    /// The reply couldn't be read.
    case unreadable(CloudProvider, details: String)

    static func providerName(_ provider: CloudProvider) -> String {
        provider == .anthropic ? "Anthropic" : "OpenAI"
    }

    /// One plain sentence, from the person's side.
    public var message: String {
        switch self {
        case .noKey(let provider): return "Add an \(Self.providerName(provider)) key in Settings."
        case .badKey(let provider, _): return "\(Self.providerName(provider)) didn’t accept this key."
        case .noCredit(let provider, _): return "Your \(Self.providerName(provider)) account is out of credit."
        case .rateLimited(let provider, _, _): return "\(Self.providerName(provider)) is limiting requests from this key. Try again in a minute."
        case .busy(let provider, _): return "\(Self.providerName(provider)) is busy. Try again in a few minutes."
        case .offline: return "You’re offline."
        case .connectionLost(let provider, _): return "The connection to \(Self.providerName(provider)) was lost."
        case .modelUnavailable(_, let model, _): return "This key can’t use \(model)."
        case .refused(let model, _, _): return "\(model) declined to summarize this conversation."
        case .tooLong(let model, _): return "The summary was longer than \(model) can write."
        case .rejected(let provider, _): return "\(Self.providerName(provider)) couldn’t take this request."
        case .unreadable(let provider, _): return "\(Self.providerName(provider))’s reply couldn’t be read."
        }
    }

    /// The provider's own words, for Details….
    public var details: String {
        switch self {
        case .noKey: return ""
        case .badKey(_, let details), .noCredit(_, let details), .rateLimited(_, _, let details), .busy(_, let details),
             .offline(let details), .connectionLost(_, let details), .modelUnavailable(_, _, let details), .refused(_, _, let details),
             .tooLong(_, let details), .rejected(_, let details), .unreadable(_, let details):
            return details
        }
    }

    public var errorDescription: String? { message }

    /// How long to wait before trying again, on try `attempt` (1, 2, …); nil when trying again won't help, or
    /// the provider asked for longer than a minute.
    func retryDelay(attempt: Int) -> TimeInterval? {
        let backoff = 2 * pow(4, Double(max(0, attempt - 1)))
        switch self {
        case .rateLimited(_, let after, _):
            guard let after else { return backoff }
            return after <= 60 ? max(after, 0.5) : nil
        case .busy, .connectionLost: return backoff
        default: return nil
        }
    }

    /// Anything shaped like an API key, masked: providers quote part of a rejected key back.
    static func scrubbed(_ text: String) -> String {
        guard let pattern = try? NSRegularExpression(pattern: #"sk-[A-Za-z0-9_\-*]{8,}"#) else { return text }
        var result = text
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: CloudAPIKey.mask(String(result[range])))
        }
        return result
    }
}
