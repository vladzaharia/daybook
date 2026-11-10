import DaybookKit
import Foundation
import XCTest
@testable import DaybookUI

/// VI-22: Settings › Models' download rows are named for what they download ("Transcription and speakers", "Live
/// captions"), with where the download stands and its size on the line under the name.
@MainActor
final class ModelRowsTests: XCTestCase {
    func testBehaviorADownloadRowsLineSaysWhereItStandsAndItsSize() {
        let all = ModelDownloadSummary.missing(names: ["Parakeet Ultra", "Community-1"], bytes: 853_000_000, rest: .nothing)
        XCTAssertEqual(ModelDownloadRow.status(all), ModelLine("Not downloaded yet · 853 MB"))
        let some = ModelDownloadSummary.missing(names: ["Community-1"], bytes: 22_000_000, rest: .here)
        XCTAssertEqual(ModelDownloadRow.status(some), ModelLine("Partly downloaded · Community-1 · 22 MB"))
        let wifi = ModelDownloadSummary.waiting(bytes: 853_000_000, forWiFi: true)
        XCTAssertEqual(ModelDownloadRow.status(wifi), ModelLine(ModelStatus.waitingForWiFi.label + " · 853 MB"))
        let going = ModelDownloadSummary.downloading(done: 400_000_000, total: 1_600_000_000)
        XCTAssertEqual(ModelDownloadRow.status(going), ModelLine("Downloading · 0.4 of 1.6 GB"))
    }

    func testBehaviorWithoutRoomTheLineSaysOnlyWhatItNeeds() {
        let all = ModelDownloadSummary.missing(names: ["Parakeet Ultra"], bytes: 853_000_000, rest: .nothing)
        XCTAssertEqual(ModelDownloadRow.status(all, space: ModelSpace(free: 100_000_000)),
                       ModelLine("Needs 853 MB · 100 MB free", needsAttention: true), "in the warning ink, without a prefix")
    }
}
