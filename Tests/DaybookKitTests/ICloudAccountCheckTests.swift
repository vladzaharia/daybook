import CloudKit
import XCTest
@testable import DaybookKit

/// Telling "signed out" from "iCloud Drive is off" through CloudKit, which works in the App Sandbox.
final class ICloudAccountCheckTests: XCTestCase {
    func testCloudKitAccountStatusMapsToSignedInSignedOutOrUnknown() {
        XCTAssertEqual(ICloudAccountCheck.signedIn(.available), true)
        XCTAssertEqual(ICloudAccountCheck.signedIn(.noAccount), false)
        XCTAssertNil(ICloudAccountCheck.signedIn(.restricted))
        XCTAssertNil(ICloudAccountCheck.signedIn(.couldNotDetermine))
        XCTAssertNil(ICloudAccountCheck.signedIn(.temporarilyUnavailable))
    }

    /// `swift test` isn't signed for CloudKit: the check answers "unknown" without creating a container, which would
    /// stop the process.
    func testWithoutTheCloudKitEntitlementTheAnswerIsUnknown() async {
        let answer = await ICloudAccountCheck.signedIn(containerIdentifier: "iCloud.local.daybook")
        XCTAssertNil(answer)
        let unexpanded = await ICloudAccountCheck.signedIn(containerIdentifier: "$(DAYBOOK_ICLOUD_CONTAINER)")
        XCTAssertNil(unexpanded)
    }
}
