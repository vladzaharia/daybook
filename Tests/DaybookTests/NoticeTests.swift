import DaybookCore
@testable import DaybookKit
import Foundation
import XCTest
@testable import Daybook

/// Notices from one job (several recordings, photos) are all kept, not each replacing the last.
@MainActor
final class NoticeTests: XCTestCase {
    func testEveryDistinctNoticeIsKept() async throws {
        let rig = try await MultiSourceRig.make(in: self)
        addTeardownBlock { await rig.tearDown() }
        rig.state.notice = nil
        rig.state.post(["Speaker detection failed for mic.caf.", "Older transcript has no word timings."])
        rig.state.post(["Speaker detection failed for mic.caf.", "Photos couldn’t be read: Vision is unavailable"])
        XCTAssertEqual(rig.state.notice?.components(separatedBy: "\n"), [
            "Older transcript has no word timings.", "Speaker detection failed for mic.caf.", "Photos couldn’t be read: Vision is unavailable"])
    }
}
