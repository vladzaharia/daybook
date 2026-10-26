import Foundation

// One way for the package's tests to wait for something to happen. It always fails on timeout (by
// throwing, which fails the test and stops it), says what it was waiting for, where, and what it
// last saw, and stretches every timeout by DAYBOOK_TEST_TIMEOUT_SCALE so a slow or starved machine
// gets longer.

/// Timeouts in tests, stretched on slow machines.
public enum TestTiming {
    /// `DAYBOOK_TEST_TIMEOUT_SCALE` (1 when unset or not a number of at least 1). CI's starved
    /// runners can set 2 or more; nothing ever waits less than its nominal timeout.
    public static let scale: Double = {
        guard let raw = ProcessInfo.processInfo.environment["DAYBOOK_TEST_TIMEOUT_SCALE"], let value = Double(raw),
              value.isFinite else { return 1 }
        return max(1, value)
    }()

    /// `seconds`, stretched by `scale`.
    public static func scaled(_ seconds: TimeInterval) -> TimeInterval { seconds * scale }
}

/// A wait that ran out of time. Thrown, so the test fails with this description.
public struct WaitTimeout: Error, CustomStringConvertible, LocalizedError {
    public let description: String
    public var errorDescription: String? { description }

    public init(_ what: String, after seconds: TimeInterval, file: StaticString, line: UInt, lastState: String?) {
        var text = "Timed out after \(String(format: "%.1f", seconds)) s waiting for \(what) (\(file):\(line))"
        if let lastState { text += ". Last seen: \(lastState)" }
        description = text
    }
}

/// Polls `condition` on the caller's actor until it holds. Throws `WaitTimeout` after `timeout`
/// seconds (stretched by `TestTiming.scale`), with `state()` describing what it last saw.
public func waitUntil(_ what: String, timeout: TimeInterval = 10, poll: Duration = .milliseconds(10),
                      file: StaticString = #filePath, line: UInt = #line,
                      isolation: isolated (any Actor)? = #isolation,
                      state: (() -> String)? = nil, _ condition: () throws -> Bool) async throws {
    _ = try await waitFor(what, timeout: timeout, poll: poll, file: file, line: line, state: state) { try condition() ? true : nil }
}

/// Polls `value` on the caller's actor until it returns something, and returns that. Throws
/// `WaitTimeout` after `timeout` seconds (stretched by `TestTiming.scale`).
public func waitFor<T>(_ what: String, timeout: TimeInterval = 10, poll: Duration = .milliseconds(10),
                       file: StaticString = #filePath, line: UInt = #line,
                       isolation: isolated (any Actor)? = #isolation,
                       state: (() -> String)? = nil, _ value: () throws -> T?) async throws -> T {
    let limit = TestTiming.scaled(timeout)
    let start = ContinuousClock.now
    let deadline = start + .seconds(limit)
    while true {
        if let found = try value() { return found }
        guard ContinuousClock.now < deadline else {
            let timeout = WaitTimeout(what, after: limit, file: file, line: line, lastState: state?())
            print("error: \(timeout)")
            throw timeout
        }
        try await Task.sleep(for: poll)
    }
}

/// The async form of `waitUntil`, for conditions that await (an actor's state, a file read).
public func waitUntilAsync(_ what: String, timeout: TimeInterval = 10, poll: Duration = .milliseconds(10),
                           file: StaticString = #filePath, line: UInt = #line,
                           isolation: isolated (any Actor)? = #isolation,
                           state: (() async -> String)? = nil, _ condition: () async throws -> Bool) async throws {
    let limit = TestTiming.scaled(timeout)
    let deadline = ContinuousClock.now + .seconds(limit)
    while try await !condition() {
        guard ContinuousClock.now < deadline else {
            let timeout = WaitTimeout(what, after: limit, file: file, line: line, lastState: await state?())
            print("error: \(timeout)")
            throw timeout
        }
        try await Task.sleep(for: poll)
    }
}
