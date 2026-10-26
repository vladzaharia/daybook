import Foundation
import XCTest
@testable import DaybookCore

/// The person's home folder, which the App Sandbox hides behind the app's container.
final class UserHomeTests: XCTestCase {
    func testTheAccountHomeIsUsedEvenWhenTheProcessHomeIsAContainer() {
        let container = "/Users/dana/Library/Containers/local.daybook.app/Data"
        XCTAssertEqual(UserHome.resolve(accountHome: "/Users/dana", fallback: container).path, "/Users/dana")
    }

    func testAMissingOrUnusableAccountHomeFallsBackToTheProcessHome() {
        XCTAssertEqual(UserHome.resolve(accountHome: nil, fallback: "/Users/dana").path, "/Users/dana")
        XCTAssertEqual(UserHome.resolve(accountHome: "", fallback: "/Users/dana").path, "/Users/dana")
        XCTAssertEqual(UserHome.resolve(accountHome: "relative/home", fallback: "/Users/dana").path, "/Users/dana")
        XCTAssertEqual(UserHome.resolve(accountHome: "/", fallback: "/Users/dana").path, "/Users/dana")
    }

    func testOutsideTheSandboxItIsTheProcessHome() {
        // `swift test` isn't sandboxed, so the user database and Foundation agree.
        XCTAssertEqual(UserHome.url.standardizedFileURL.path, FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path)
        XCTAssertEqual(UserHome.iCloudDrive.path, UserHome.url.path + "/Library/Mobile Documents/com~apple~CloudDocs")
        XCTAssertEqual(UserHome.mobileDocuments.path, UserHome.url.path + "/Library/Mobile Documents")
    }
}
