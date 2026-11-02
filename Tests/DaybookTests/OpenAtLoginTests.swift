import ServiceManagement
import XCTest
@testable import Daybook

/// Settings › General › Open at login: off until the person turns it on, on while System Settings still waits to
/// approve it (with the way there), and a refusal said in place. Never touches this Mac's login items.
@MainActor
final class OpenAtLoginTests: XCTestCase {
    /// A login item that records what it was asked and answers as told.
    final class FakeService: LoginItemService {
        var status: SMAppService.Status = .notRegistered
        /// What register() makes the status; nil throws.
        var registers: SMAppService.Status? = .enabled
        var calls: [String] = []

        struct Refused: LocalizedError { var errorDescription: String? { "Operation not permitted" } }

        func register() throws {
            calls.append("register")
            guard let registers else { throw Refused() }
            status = registers
        }

        func unregister() throws {
            calls.append("unregister")
            status = .notRegistered
        }

        func openSystemSettings() { calls.append("settings") }
    }

    func testBehaviorItsOffUntilTurnedOnAndAddsNothingByItself() {
        let service = FakeService()
        let item = LoginItem(service: service)
        XCTAssertFalse(item.isOn)
        XCTAssertNil(item.problem)
        XCTAssertEqual(service.calls, [], "never a login item added silently")

        item.set(true)
        XCTAssertTrue(item.isOn)
        XCTAssertNil(item.problem)
        item.set(true)
        XCTAssertEqual(service.calls, ["register"], "turning on what's on asks nothing again")
        item.set(false)
        XCTAssertFalse(item.isOn)
        XCTAssertEqual(service.calls, ["register", "unregister"])
    }

    func testBehaviorWaitingForApprovalIsOnWithTheWayToLoginItems() {
        let service = FakeService()
        service.registers = .requiresApproval
        let item = LoginItem(service: service)
        item.set(true)
        XCTAssertTrue(item.isOn, "registered, so the switch stays on")
        XCTAssertEqual(item.problem?.text, "Allow Daybook in Login Items to open it at login.")
        XCTAssertEqual(item.problem?.opensSettings, true)
        item.openSettings()
        XCTAssertEqual(service.calls.last, "settings")

        // Approved in System Settings, then back in Daybook: the line goes.
        service.status = .enabled
        item.refresh()
        XCTAssertNil(item.problem)
    }

    func testBehaviorARefusalIsSaidInPlaceWithTheSystemsWordsBehindDetails() {
        let service = FakeService()
        service.registers = nil
        let item = LoginItem(service: service)
        item.set(true)
        XCTAssertFalse(item.isOn)
        XCTAssertEqual(item.problem?.text, "Daybook couldn’t be added to Login Items.")
        XCTAssertEqual(item.problem?.details, "Operation not permitted")

        service.registers = .enabled
        item.set(true)
        XCTAssertNil(item.problem, "a later success clears it")
    }
}
