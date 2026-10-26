import XCTest
@testable import DaybookKit

/// The keychain group library keys use. The keychain itself needs a signed build: device checks in docs/validation.md.
final class KeychainLibraryKeyStoreTests: XCTestCase {
    func testOnlyAnExpandedSharedGroupIsUsed() {
        XCTAssertTrue(KeychainLibraryKeyStore.isSharedGroup("48H7CLBV8Y.local.daybook.shared"))
        XCTAssertFalse(KeychainLibraryKeyStore.isSharedGroup("$(AppIdentifierPrefix)local.daybook.shared"))
        XCTAssertFalse(KeychainLibraryKeyStore.isSharedGroup(".local.daybook.shared"))
        XCTAssertFalse(KeychainLibraryKeyStore.isSharedGroup("48H7CLBV8Y.local.daybook.app"))
        XCTAssertFalse(KeychainLibraryKeyStore.isSharedGroup("48h7clbv8y.local.daybook.shared"))
    }

    func testUnsignedBuildsHaveNoStore() {
        // `swift test` runs unsigned: no keychain groups, so no library keys (and no iCloud sync either).
        XCTAssertNil(KeychainLibraryKeyStore.system)
    }
}
