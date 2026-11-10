import DaybookTestSupport
import Darwin
import XCTest
@testable import DaybookIntelligence

/// Copies processing makes of a conversation's audio stay in a folder of Daybook's own, cleared at launch of whatever
/// a run that has ended left there (`ProcessingScratch`).
final class ProcessingScratchTests: XCTestCase {
    func testACopyIsMadeInThisRunsOwnerOnlyFolder() throws {
        let base = makeTemporaryFolder("DaybookTests")
        let file = try ProcessingScratch.file(extension: "caf", in: base)
        let folder = file.deletingLastPathComponent()
        XCTAssertEqual(folder.lastPathComponent, String(getpid()))
        XCTAssertEqual(folder.deletingLastPathComponent().standardizedFileURL.path, ProcessingScratch.root(in: base).standardizedFileURL.path)
        XCTAssertEqual(file.pathExtension, "caf")
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertNotEqual(try ProcessingScratch.file(extension: "caf", in: base), file, "each copy is a file of its own")
    }

    func testLaunchClearsWhatEndedRunsLeftAndKeepsRunningOnes() throws {
        let base = makeTemporaryFolder("DaybookTests")
        let root = ProcessingScratch.root(in: base)
        let own = try ProcessingScratch.file(extension: "caf", in: base)
        try Data("this run".utf8).write(to: own)
        // launchd is always running, and this process may not signal it: another run still going.
        let running = root.appendingPathComponent("1", isDirectory: true)
        // Above the highest process ID: a run that has ended.
        let ended = root.appendingPathComponent("999999", isDirectory: true)
        let stray = root.appendingPathComponent("stray", isDirectory: true)
        for folder in [running, ended, stray] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("audio".utf8).write(to: folder.appendingPathComponent("copy.caf"))
        }
        let loose = root.appendingPathComponent("loose.caf")
        try Data("audio".utf8).write(to: loose)

        ProcessingScratch.clear(in: base)
        XCTAssertTrue(FileManager.default.fileExists(atPath: own.path), "this run keeps its own")
        XCTAssertTrue(FileManager.default.fileExists(atPath: running.path), "a run still going keeps its own")
        for gone in [ended, stray, loose] { XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path), gone.lastPathComponent) }
    }

    func testClearingWhenNothingWasLeftChangesNothing() {
        let base = makeTemporaryFolder("DaybookTests")
        ProcessingScratch.clear(in: base)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProcessingScratch.root(in: base).path))
    }
}
