import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Time the system grants to finish work once the app leaves the foreground: UIKit's background tasks on iPhone, a
/// fake in tests.
@MainActor
public protocol BackgroundTime {
    /// Starts an assertion, or nil when there's no time to grant. `expired` runs when the time is up; an assertion
    /// still held then gets the app ended instead of suspended.
    func begin(_ name: String, expired: @escaping @MainActor @Sendable () -> Void) -> Int?
    func end(_ assertion: Int)
}

/// One background-time assertion, ended once: by whichever of the work and the time finishes first.
@MainActor
public final class BackgroundAssertion {
    private let time: any BackgroundTime
    private var id: Int?

    public init(_ time: any BackgroundTime) { self.time = time }

    public func begin(_ name: String) { id = time.begin(name) { [weak self] in self?.end() } }

    /// Ends the assertion if it's still held; later calls, and the time running out after it, do nothing.
    public func end() {
        guard let id else { return }
        self.id = nil
        time.end(id)
    }
}

#if canImport(UIKit)
/// UIKit's background tasks.
public struct SystemBackgroundTime: BackgroundTime {
    public nonisolated init() {}

    public func begin(_ name: String, expired: @escaping @MainActor @Sendable () -> Void) -> Int? {
        let id = UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: expired)
        return id == .invalid ? nil : id.rawValue
    }

    public func end(_ assertion: Int) { UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: assertion)) }
}
#endif
