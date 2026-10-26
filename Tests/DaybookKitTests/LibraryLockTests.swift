import DaybookCore
import Foundation
import XCTest
@testable import DaybookKit

/// The library's lock: waiting can end when the waiting task is cancelled, without holding the lock,
/// and the lock still passes, in order, to whoever waits next.
@MainActor
final class LibraryLockTests: XCTestCase {
    func testACancelledWaiterStopsWaitingWithoutTheLockAndTheNextOneGetsIt() async throws {
        let library = LibraryController(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("Lock-\(UUID())"), sync: nil)
        await library.acquireLock()
        var order: [String] = []
        let cancelled = Task {
            do { try await library.acquireLockUnlessCancelled(); order.append("cancelled one got it"); library.releaseLock() }
            catch { order.append(error is CancellationError ? "cancelled one stopped waiting" : "\(error)") }
        }
        let patient = Task {
            await library.acquireLock()
            order.append("patient one got it")
            library.releaseLock()
        }
        let stubborn = Task {
            // Waiting without cancellation keeps waiting even when cancelled.
            await library.acquireLock()
            order.append("stubborn one got it")
            library.releaseLock()
        }
        for _ in 0..<5 { await Task.yield() }
        cancelled.cancel(); stubborn.cancel()
        await cancelled.value
        XCTAssertEqual(order, ["cancelled one stopped waiting"])
        library.releaseLock()
        await patient.value; await stubborn.value
        XCTAssertEqual(order, ["cancelled one stopped waiting", "patient one got it", "stubborn one got it"])
        // Free again: an already-cancelled task doesn't take it.
        let late = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do { try await library.acquireLockUnlessCancelled(); return true } catch { return false }
        }
        let tookIt = await late.value
        XCTAssertFalse(tookIt)
        await library.acquireLock()
        library.releaseLock()
    }
}
