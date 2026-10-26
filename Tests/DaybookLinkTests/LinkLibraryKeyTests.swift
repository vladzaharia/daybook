@testable import DaybookLink
import DaybookTestSupport
import Foundation
import XCTest

/// An encrypted library's key over the link (LinkLibraryKey.swift): a paired phone of the same library asks and gets
/// it over loopback; one whose library is another gets nothing.
final class LinkLibraryKeyTests: XCTestCase {
    private let key = Data(repeating: 3, count: 32)
    private let keyID = String(repeating: "c", count: 32)

    func testAPairedDeviceOfTheSameLibraryGetsTheKey() async throws {
        let pair = try await LinkedPair.make(self)
        let (macSide, _) = try await pair.connect()
        let request = LinkLibraryKeyRequest(libraryID: Fixture.libraryID, keyIDs: [keyID])
        try await pair.client.send(.libraryKeyRequest(request))
        let (message, from) = try await pair.macEvents.next("request on Mac") { $0.received }
        XCTAssertEqual(from, pair.phone.deviceID)
        guard case .libraryKeyRequest(let received) = message else { return XCTFail("\(message)") }
        // The Mac answers from the phone's capabilities as the session reported them.
        let grants = received.grants(toPeerOf: macSide.capabilities.libraryID, libraryID: Fixture.libraryID,
                                     held: [(id: keyID, key: key), (id: String(repeating: "d", count: 32), key: key)])
        XCTAssertEqual(grants, [LinkLibraryKeyGrant(libraryID: Fixture.libraryID, keyID: keyID, key: key)], "Only the keys asked for")
        for grant in grants { try await pair.service.send(.libraryKeyGrant(grant), to: pair.phone.deviceID) }
        let (onPhone, _) = try await pair.phoneEvents.next("grant on phone") { $0.received }
        XCTAssertEqual(onPhone, .libraryKeyGrant(grants[0]))
    }

    func testADeviceOfAnotherLibraryGetsNothing() {
        let other = UUID()
        let request = LinkLibraryKeyRequest(libraryID: other, keyIDs: [keyID])
        XCTAssertTrue(request.grants(toPeerOf: other, libraryID: Fixture.libraryID, held: [(id: keyID, key: key)]).isEmpty)
        let mine = LinkLibraryKeyRequest(libraryID: Fixture.libraryID, keyIDs: [keyID])
        XCTAssertTrue(mine.grants(toPeerOf: other, libraryID: Fixture.libraryID, held: [(id: keyID, key: key)]).isEmpty,
                      "A request naming this library from a device whose library is another")
        XCTAssertTrue(mine.grants(toPeerOf: nil, libraryID: Fixture.libraryID, held: [(id: keyID, key: key)]).isEmpty)
        XCTAssertTrue(mine.grants(toPeerOf: Fixture.libraryID, libraryID: nil, held: [(id: keyID, key: key)]).isEmpty)
    }
}
