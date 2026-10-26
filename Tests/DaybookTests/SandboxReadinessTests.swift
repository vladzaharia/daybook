import DaybookCore
import Foundation
import XCTest
@testable import Daybook

/// What the Mac app shows and suggests about places on disk, which the App Sandbox moves into a container.
final class SandboxReadinessTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/dana", isDirectory: true)

    func testSettingsShowTheLibraryFromThePersonsHome() {
        let unsandboxed = URL(fileURLWithPath: "/Users/dana/Library/Application Support/Daybook", isDirectory: true)
        XCTAssertEqual(SettingsPath.display(unsandboxed, home: home), "~/Library/Application Support/Daybook")
        // Sandboxed, the library is in the container, and Settings says so rather than hiding it behind "~".
        let container = URL(fileURLWithPath: "/Users/dana/Library/Containers/local.daybook.app/Data/Library/Application Support/Daybook",
                            isDirectory: true)
        XCTAssertEqual(SettingsPath.display(container, home: home), "~/Library/Containers/local.daybook.app/Data/Library/Application Support/Daybook")
        XCTAssertEqual(SettingsPath.display(URL(fileURLWithPath: "/Volumes/Archive/Daybook"), home: home), "/Volumes/Archive/Daybook")
    }

    /// `swift run` is never sandboxed: it keeps its own library instead of opening the app's.
    func testUnbundledRunsUseADevelopmentLibrary() {
        XCTAssertEqual(LibraryLocation.folderName(bundleURL: URL(fileURLWithPath: "/Applications/Daybook.app")), "Daybook")
        XCTAssertEqual(LibraryLocation.folderName(bundleURL: URL(fileURLWithPath: "/Users/dana/daybook/.build/arm64-apple-macosx/debug")),
                       "Daybook Development")
        XCTAssertEqual(LibraryLocation.folderName(bundleURL: URL(fileURLWithPath: "/Users/dana/daybook/.build/debug")), "Daybook Development")
        // `swift test` is unbundled too.
        XCTAssertEqual(AppState.libraryURL.lastPathComponent, "Daybook Development")
    }

    /// In the App Sandbox, the path flags may only name the container or the ad hoc build's scratch folder.
    func testSandboxedLaunchPathsMustBeReachable() {
        let container = "/Users/dana/Library/Containers/local.daybook.app.adhoc/Data"
        let roots = [container, "/private/tmp/daybook/"]
        XCTAssertTrue(LaunchPaths.isReachable("/tmp/daybook/ui", roots: roots))
        XCTAssertTrue(LaunchPaths.isReachable("/private/tmp/daybook", roots: roots))
        XCTAssertTrue(LaunchPaths.isReachable(container + "/Library/Application Support/Daybook/Models", roots: roots))
        XCTAssertFalse(LaunchPaths.isReachable("/tmp/daybook-smoke.json", roots: roots), "a sibling isn't inside the folder")
        XCTAssertFalse(LaunchPaths.isReachable("/tmp/daybook/../elsewhere", roots: roots))
        XCTAssertFalse(LaunchPaths.isReachable("/Users/dana/Library/Application Support/Daybook", roots: roots))

        let arguments = ["Daybook", "--library", "/tmp/daybook/ui", "--snapshot", "/Users/dana/Desktop/shots", "--output", "/tmp/smoke.json"]
        let problems = LaunchPaths.problems(arguments: arguments, sandboxed: true, roots: roots)
        XCTAssertEqual(problems.count, 2, problems.joined(separator: "\n"))
        XCTAssertTrue(problems[0].hasPrefix("--snapshot /Users/dana/Desktop/shots:"), problems[0])
        XCTAssertTrue(problems[0].contains("/private/tmp/daybook/"), problems[0])
        XCTAssertTrue(problems[1].hasPrefix("--output /tmp/smoke.json:"), problems[1])
        XCTAssertEqual(LaunchPaths.problems(arguments: arguments, sandboxed: false, roots: roots), [])
    }

    func testTestsRunOutsideTheSandbox() {
        XCTAssertFalse(SandboxEnvironment.isSandboxed)
        XCTAssertEqual(LaunchPaths.problems(arguments: ["Daybook", "--library", "/anywhere"]), [])
    }

    func testExportNamesHaveNoFolderSeparators() {
        XCTAssertEqual(AppState.exportName("Q3/Q4 planning"), "Q3-Q4 planning")
        XCTAssertEqual(AppState.exportName("10:30 sync"), "10-30 sync")
        XCTAssertEqual(AppState.exportName("  "), "Conversation")
        XCTAssertEqual(AppState.exportName(".."), "Conversation")
    }

    func testSettingsShowICloudPlacesByName() {
        let drive = URL(fileURLWithPath: "/Users/dana/Library/Mobile Documents/com~apple~CloudDocs/Daybook Sync")
        XCTAssertEqual(SettingsPath.display(drive, home: home), "iCloud Drive › Daybook Sync")
        let container = URL(fileURLWithPath: "/Users/dana/Library/Mobile Documents/iCloud~local~daybook/Documents/Daybook")
        XCTAssertEqual(SettingsPath.display(container, home: home), "iCloud Drive › Daybook")
    }
}
