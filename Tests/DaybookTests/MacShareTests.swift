import AppKit
import XCTest
@testable import Daybook

/// A share on the Mac keeps its export files while the sharing picker is open and while the service chosen in it is
/// sharing them, and lets them go once, when it's done: never at the start of the next share, which may still be using
/// an earlier one's.
@MainActor
final class MacShareTests: XCTestCase {
    private let files = [URL(fileURLWithPath: "/private/tmp/Daybook Export/A/Weekly sync.md")]

    func testBehaviorAShareLetsItsFilesGoOnceItsDone() {
        var finished: [[URL]] = []
        let picker = NSSharingServicePicker(items: files)
        let service = NSSharingService(title: "Test", image: NSImage(), alternateImage: nil) {}

        let dismissed = ShareCleanup(files: files) { finished.append($0.files) }
        dismissed.sharingServicePicker(picker, didChoose: nil)
        XCTAssertEqual(finished, [files], "the picker dismissed without a choice")
        dismissed.finish()
        XCTAssertEqual(finished.count, 1, "only once")

        finished = []
        let shared = ShareCleanup(files: files) { finished.append($0.files) }
        XCTAssertTrue(shared.sharingServicePicker(picker, delegateFor: service) === shared, "it hears from the service too")
        shared.sharingServicePicker(picker, didChoose: service)
        XCTAssertTrue(finished.isEmpty, "the service is still sharing them (AirDrop, Mail)")
        shared.sharingService(service, didShareItems: files)
        XCTAssertEqual(finished, [files])

        finished = []
        let failed = ShareCleanup(files: files) { finished.append($0.files) }
        failed.sharingServicePicker(picker, didChoose: service)
        failed.sharingService(service, didFailToShareItems: files, error: CocoaError(.userCancelled))
        XCTAssertEqual(finished, [files], "cancelled in the service, or failed")
    }
}
