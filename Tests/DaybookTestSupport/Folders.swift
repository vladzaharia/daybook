import Foundation
import XCTest

// Folders for tests, kept in one folder per test process in the temporary directory.
//
// A test's folder is removed when the test ends. What the test started can still write into it
// afterwards: a library's queued save that lands while the folder is being emptied leaves it behind
// with that one file, and a later save can make it again. Those leftovers are inside the process's
// folder, which is removed when the bundle finishes, as `TestDefaults.folder` is.

extension XCTestCase {
    /// A new empty folder for this test, `<process folder>/<prefix>-<UUID>`, removed when the test ends.
    public func makeTemporaryFolder(_ prefix: String = "DaybookTests") -> URL {
        let url = TestFolders.root.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        catch { preconditionFailure("Couldn’t make a test folder at \(url.path): \(error)") }
        TestFolders.startSweeping()
        addTeardownBlock { TestFolders.remove(url) }
        return url
    }
}

public enum TestFolders {
    /// This process's test folders: a folder of its own in the temporary directory.
    public static let root: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DaybookTests-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Removes a test's folder, again if a write landed in it while it was being emptied.
    public static func remove(_ url: URL) {
        for attempt in 0..<5 {
            try? FileManager.default.removeItem(at: url)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            Thread.sleep(forTimeInterval: 0.02 * Double(attempt + 1))
        }
    }

    static func startSweeping() { Sweeper.shared.start() }

    /// Deletes the process's folder when the bundle finishes.
    private final class Sweeper: NSObject, XCTestObservation, @unchecked Sendable {
        static let shared = Sweeper()
        private let lock = NSLock()
        private var started = false

        func start() {
            guard lock.withLock({ defer { started = true }; return !started }) else { return }
            // The observation center belongs to the main thread.
            if Thread.isMainThread {
                XCTestObservationCenter.shared.addTestObserver(self)
            } else {
                DispatchQueue.main.async { XCTestObservationCenter.shared.addTestObserver(self) }
            }
        }

        func testBundleDidFinish(_ testBundle: Bundle) {
            try? FileManager.default.removeItem(at: TestFolders.root)
        }
    }
}
