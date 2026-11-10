import Foundation
import Observation

/// Follows what a closure reads from `@Observable` models, for code that isn't a view: after anything it read changes,
/// the watch reads again and calls back. Both apps' models are `@Observable`, and macOS 15 has no sequence of changes
/// (`Observations` arrived with macOS 26), so this is `withObservationTracking` made to keep following.
///
/// - The call comes on the main queue once the change has landed, never while it's being made. Changes in one turn of
///   the main queue are told once, and the main queue runs while a slider is dragged or a window resized, which a
///   `RunLoop.main` scheduler doesn't.
/// - With `delay`, the call waits until nothing has changed for that long, so a burst of edits (typing) is told once.
/// - It follows until `cancel()` or until the watch is released, like a Combine subscription.
@MainActor
public final class ObservationWatch {
    private var isCancelled = false
    private var pending: Task<Void, Never>?
    /// Reads what's followed, and follows its next change.
    private var follow: (@MainActor () -> Void)?

    private init() {}

    /// Calls `changed` after anything `read` reads changes.
    public convenience init(delay: Duration? = nil, _ read: @escaping @MainActor () -> Void, changed: @escaping @MainActor () -> Void) {
        self.init()
        start(read, delay: delay, tell: changed)
    }

    /// Calls `changed` with what `value` reads: now when `initial`, and after each change to anything it read.
    public static func values<Value>(of value: @escaping @MainActor () -> Value, initial: Bool = true, delay: Duration? = nil,
                                     _ changed: @escaping @MainActor (Value) -> Void) -> ObservationWatch {
        let latest = Latest<Value>()
        let watch = ObservationWatch()
        watch.start({ latest.value = value() }, delay: delay) { if let value = latest.value { changed(value) } }
        if initial, let value = latest.value { changed(value) }
        return watch
    }

    /// The same, told only when the value differs from the last one told (or, without `initial`, from the first).
    public static func distinctValues<Value: Equatable>(of value: @escaping @MainActor () -> Value, initial: Bool = true,
                                                        delay: Duration? = nil,
                                                        _ changed: @escaping @MainActor (Value) -> Void) -> ObservationWatch {
        let told = Latest<Value>()
        if !initial { told.value = value() }
        return values(of: value, initial: initial, delay: delay) { next in
            guard told.value != next else { return }
            told.value = next
            changed(next)
        }
    }

    /// Returns once `condition` holds: at once when it does, else after the change to what it reads that makes it hold.
    public static func until(_ condition: @escaping @MainActor () -> Bool) async {
        if condition() { return }
        let watch = Latest<ObservationWatch>()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waiting = Latest<CheckedContinuation<Void, Never>>()
            waiting.value = continuation
            watch.value = values(of: condition, initial: false) { holds in
                guard holds, let continuation = waiting.value else { return }
                waiting.value = nil
                continuation.resume()
            }
        }
        watch.value?.cancel()
    }

    /// Follows for as long as the calling task runs (a view's `.task`), then stops: returns once the task is cancelled.
    public func followWhileRunning() async {
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(86_400)) }
        cancel()
    }

    /// Stops following. Nothing more is told, including a delayed call that hasn't happened yet.
    public func cancel() {
        isCancelled = true
        follow = nil
        pending?.cancel()
        pending = nil
    }

    private func start(_ read: @escaping @MainActor () -> Void, delay: Duration?, tell: @escaping @MainActor () -> Void) {
        // Called only on the main actor (`onMain`), so it may ride through the change callback, which is `@Sendable`.
        nonisolated(unsafe) let tell = tell
        follow = { [weak self] in
            withObservationTracking {
                read()
            } onChange: { [weak self] in
                Self.onMain { self?.changed(delay: delay, tell: tell) }
            }
        }
        follow?()
    }

    private func changed(delay: Duration?, tell: @escaping @MainActor () -> Void) {
        guard !isCancelled else { return }
        // Read again first, which follows the next change, then tell.
        follow?()
        guard let delay else { return tell() }
        pending?.cancel()
        pending = Task { [weak self] in
            guard (try? await Task.sleep(for: delay)) != nil, let self, !self.isCancelled else { return }
            self.pending = nil
            tell()
        }
    }

    /// `withObservationTracking` calls back on the thread that changes the value, before it changes; every model here
    /// is main-actor, so that's the main thread. The work waits for the change to land: the next turn of the main queue.
    private nonisolated static func onMain(_ work: @escaping @MainActor () -> Void) {
        nonisolated(unsafe) let work = work
        DispatchQueue.main.async { MainActor.assumeIsolated(work) }
    }

    @MainActor
    private final class Latest<Value> {
        var value: Value?
    }
}
