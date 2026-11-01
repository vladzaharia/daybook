import Foundation
import Observation

/// Counts the changes a view reading what `read` reads would be told of: every change to an `@Observable` property it
/// reads, as it's made. The app's models are `@Observable`, so this is how a test says what redraws what.
@MainActor
public final class ObservationCount {
    /// Changes so far.
    public private(set) var count = 0
    private let read: @MainActor () -> Void
    private var isCancelled = false

    public init(_ read: @escaping @MainActor () -> Void) {
        self.read = read
        follow()
    }

    /// Stops counting.
    public func cancel() { isCancelled = true }

    private func follow() {
        withObservationTracking {
            read()
        } onChange: { [weak self] in
            // Told as the change is made, on the thread making it: the main thread for every model here. Following
            // again at once counts the next change too, however soon it comes.
            MainActor.assumeIsolated {
                guard let self, !self.isCancelled else { return }
                self.count += 1
                self.follow()
            }
        }
    }
}
