import Foundation
import XCTest

// UserDefaults suites for tests, kept out of ~/Library/Preferences.
//
// A suite named by an absolute path keeps its plist at that path, so each test bundle's suites live
// in a folder of its own in the temporary directory, removed when the bundle finishes. Removing a
// named suite in ~/Library/Preferences doesn't work: the preferences daemon writes the emptied
// domain's file again seconds later, whatever the test does first, and thousands of runs left
// thousands of them.

extension XCTestCase {
    /// A new suite name for this test: `<folder>/<prefix>.<UUID>`, an absolute path. Its file is
    /// deleted when the test ends, and the folder when the bundle does. The system's speech model
    /// doesn't stand in for a missing transcription model in it (`TestDefaults.transcriptionStandInKey`).
    public func makeTestSuite(_ prefix: String = "local.daybook.tests") -> String {
        let name = TestDefaults.folder.appendingPathComponent("\(prefix).\(UUID().uuidString)").path
        removeTestSuiteAtTeardown(name)
        UserDefaults(suiteName: name)?.set(false, forKey: TestDefaults.transcriptionStandInKey)
        return name
    }

    /// A new suite for this test, removed when it ends.
    public func makeTestDefaults(_ prefix: String = "local.daybook.tests") -> UserDefaults {
        let name = makeTestSuite(prefix)
        guard let defaults = UserDefaults(suiteName: name) else { preconditionFailure("UserDefaults refused the suite \(name)") }
        return defaults
    }

    /// Deletes a suite this test made some other way (one derived from a `makeTestSuite` name, say)
    /// when it ends.
    public func removeTestSuiteAtTeardown(_ name: String) {
        TestDefaults.startSweeping()
        addTeardownBlock { TestDefaults.remove(name) }
    }
}

public enum TestDefaults {
    /// The Mac's `AppState.Preference.transcriptionStandIn`, set off in every test suite: a test's "no models" means
    /// none, whatever system speech model the Mac running it has. A test of the stand-in turns it on.
    public static let transcriptionStandInKey = "transcriptionStandIn"

    /// This process's suites: a folder of its own in the temporary directory.
    public static let folder: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DaybookTestDefaults-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Deletes a suite's file. A suite named by path is a file; one named otherwise is a domain in
    /// ~/Library/Preferences, removed as well as that allows.
    public static func remove(_ suite: String) {
        if suite.hasPrefix("/") {
            try? FileManager.default.removeItem(atPath: suite + ".plist")
        } else {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
    }

    static func startSweeping() { Sweeper.shared.start() }

    /// Deletes the folder when the bundle finishes; anything still writing then writes nowhere.
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
            try? FileManager.default.removeItem(at: TestDefaults.folder)
        }
    }
}
