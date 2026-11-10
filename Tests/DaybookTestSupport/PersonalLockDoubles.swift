import DaybookKit
import Foundation

/// Stands in for Touch ID and Face ID (`PersonalLockAuthenticating`): answers as it's told, counts how often it was
/// asked and why, and can hold its answer while a test looks at what happens with the prompt up. Nothing reaches
/// LocalAuthentication.
public final class FakePersonalLockAuthenticator: PersonalLockAuthenticating, @unchecked Sendable {
    public let method: PersonalLockMethod
    private let state = NSLock()
    private var answer: Bool
    private var holding = false
    private var askedReasons: [String] = []
    private var waiting: [CheckedContinuation<Bool, Never>] = []

    public init(method: PersonalLockMethod = .touchID, answers answer: Bool = true) {
        self.method = method
        self.answer = answer
    }

    /// How many times the person was asked.
    public var asked: Int { state.withLock { askedReasons.count } }
    /// The reasons each prompt gave.
    public var reasons: [String] { state.withLock { askedReasons } }
    /// A prompt is up, held until `release`.
    public var isWaiting: Bool { state.withLock { !waiting.isEmpty } }

    /// What the person answers from now on.
    public func answers(_ answer: Bool) { state.withLock { self.answer = answer } }

    /// The next prompts stay up until `release`.
    public func hold() { state.withLock { holding = true } }

    /// Answers the prompts that are up, and lets later ones answer at once.
    public func release(_ answer: Bool) {
        let held = state.withLock {
            holding = false
            self.answer = answer
            defer { waiting = [] }
            return waiting
        }
        for prompt in held { prompt.resume(returning: answer) }
    }

    public func authenticate(reason: String) async -> Bool {
        let (holds, answer) = state.withLock {
            askedReasons.append(reason)
            return (holding, self.answer)
        }
        guard holds else { return answer }
        return await withCheckedContinuation { continuation in
            state.withLock { waiting.append(continuation) }
        }
    }
}
