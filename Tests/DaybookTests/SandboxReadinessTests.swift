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
