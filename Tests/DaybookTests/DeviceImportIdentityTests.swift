import DaybookCore
import DaybookDevices
import Foundation
import XCTest
@testable import Daybook

/// A recorder's recording is in the library once, however many devices import it: the Mac's
/// importer checks the library's device identity right before it ingests, because another device's
/// import can arrive through sync while this one transfers. Temporary library, synthetic audio.
@MainActor
final class DeviceImportIdentityTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_780_000_000)

    func testARecordingTheLibraryAlreadyHoldsIsNotImportedAgain() async throws {
        let rig = try await MultiSourceRig.make(models: false)
        addTeardownBlock { await rig.tearDown() }
        let identity = MultiSourceRig.soundcore(start)
        let first = try await rig.state.importFromDevice(try rig.audio("phone-decoded.wav", frequency: 523), identity: identity,
                                                         attachTo: nil, source: .soundcore)
        // The same recording, decoded on this Mac (other bytes), even asked to join another conversation.
        let other = rig.state.newMeeting(title: "Design review", date: start)
        let again = try await rig.state.importFromDevice(try rig.audio("mac-decoded.wav", frequency: 524), identity: identity,
                                                         attachTo: other, source: .soundcore)
        XCTAssertEqual(again, first, "the conversation that already holds it")
        let holding = rig.state.meetings.filter { $0.tracks.contains { $0.deviceRecordingID == identity.recordingID } }
        XCTAssertEqual(holding.map(\.id), [first])
        XCTAssertEqual(rig.meeting(first)?.tracks.count, 1)
        XCTAssertEqual(rig.meeting(other)?.tracks.count, 0)

        // A recorder with another serial is another recording; a Listen Live portion is its own audio.
        var elsewhere = identity
        elsewhere.serial = "OTHER"
        XCTAssertNil(DeviceLibraryLinks.meeting(holding: elsewhere, in: rig.state.meetings))
        var portion = identity
        portion.recordingID = DeviceLibraryLinks.partialID(identity.recordingID)
        XCTAssertNil(DeviceLibraryLinks.meeting(holding: portion, in: rig.state.meetings))
        var unnamed = identity
        unnamed.serial = nil
        XCTAssertEqual(DeviceLibraryLinks.meeting(holding: unnamed, in: rig.state.meetings), first)
    }
}
