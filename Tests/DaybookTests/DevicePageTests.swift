import DaybookCore
import DaybookKit
import Foundation
import XCTest
@testable import Daybook

/// What the Mac's device page and sidebar offer: one way to act on a problem, and no import from a
/// recorder another device manages. A fake recorder stands in: no Bluetooth.
@MainActor
final class DevicePageTests: XCTestCase {
    private func session(_ recorder: FakeRecorder) -> DeviceSession {
        let defaults = UserDefaults(suiteName: "DevicePageTests-\(UUID().uuidString)")!
        let session = DeviceSession(device: ConfiguredDevice(id: "recorder", kind: SoundcoreWorkIntegration().kind),
                                    kind: SoundcoreWorkIntegration().kind, connections: [recorder], defaults: defaults)
        session.libraryChanged([], ready: true)
        addTeardownBlock { session.shutDown() }
        return session
    }

    func testARecorderAnotherDeviceManagesOffersNothingToImportHere() {
        let recorder = FakeRecorder()
        recorder.recordings = [DeviceRecording(id: "1780000000", startedAt: Date(timeIntervalSince1970: 1_780_000_000))]
        let session = session(recorder)
        XCTAssertTrue(session.importsHere)
        XCTAssertEqual(session.importableCount, 1, "this Mac manages it: its new recording is offered")

        session.applyOwnership([RecorderOwnership(kind: SoundcoreWorkIntegration.id, serial: "FAKE1", ownerID: "phone-1",
                                                  ownerName: "Alex’s iPhone", ownerClass: .phone)], thisDevice: "this-mac")
        XCTAssertEqual(session.newRecordings.count, 1, "still on the recorder, and listed")
        XCTAssertFalse(session.importsHere)
        XCTAssertEqual(session.importableCount, 0, "the iPhone imports it; it arrives here through sync")
    }

    func testTheMoreMenuOffersOnlyWhatApplies() {
        let recorder = FakeRecorder()
        let session = session(recorder)
        let away = DeviceMenuOffer(session)
        XCTAssertFalse(away.recordControl, "Not offered while it isn't linked, rather than dimmed")
        XCTAssertFalse(away.disconnect)
        XCTAssertTrue(away.connect)

        recorder.state = .connected
        let linked = DeviceMenuOffer(session)
        XCTAssertTrue(linked.recordControl)
        XCTAssertTrue(linked.disconnect)
        XCTAssertFalse(linked.connect)
        XCTAssertFalse(linked.listenLive, "A recorder without live audio never offers it")

        recorder.state = .unavailable
        XCTAssertFalse(DeviceMenuOffer(session).connect, "Bluetooth is off: Connect would do nothing")
    }

    func testAMethodRowLeavesOutWhatTheBylineSays() {
        XCTAssertTrue(DeviceMethodRows.bylineSays(.connected, managedElsewhere: false))
        XCTAssertTrue(DeviceMethodRows.bylineSays(.notConnected, managedElsewhere: true), "\"Managed by …\" is the byline")
        XCTAssertFalse(DeviceMethodRows.bylineSays(.notConnected, managedElsewhere: false), "\"Connects when it's nearby.\" says more")
    }

    func testAProblemOffersAtMostTwoActionsWithDismissWhenThereIsRoom() {
        func problem(_ actions: [DeviceProblemAction]) -> DeviceProblem {
            DeviceProblem(id: "test", title: "Something happened", message: "What to do.", actions: actions)
        }
        XCTAssertEqual(DeviceProblemBanner.actions(problem([.reconnect])), [.reconnect, .dismiss])
        XCTAssertEqual(DeviceProblemBanner.actions(problem([.openBluetoothSettings, .tryAgain, .technicalDetails])),
                       [.openBluetoothSettings, .tryAgain])
        XCTAssertEqual(DeviceProblemBanner.actions(problem([.dismiss])), [.dismiss])
        XCTAssertEqual(DeviceProblemBanner.actions(problem([.setUpFolder, .technicalDetails]), excluding: [.setUpFolder]),
                       [.technicalDetails, .dismiss], "a folder that's set up already isn't offered again")
    }
}
