import DaybookCore
import Foundation
import XCTest
@testable import DaybookKit

/// The foot of a summary's page reads the same on the Mac and the iPhone: where it ran, the local model, the date,
/// and one glyph rule for where it ran.
final class SummaryColophonTests: XCTestCase {
    private let created = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let studio = ProcessingRequest.Device(id: "studio", name: "Studio Mac")
    private let phone = ProcessingRequest.Device(id: "phone", name: "Alex’s iPhone")
    private let laptop = ProcessingRequest.Device(id: "laptop", name: "Vlad’s MacBook Pro")

    private func local(by device: ProcessingRequest.Device) -> MeetingSummary {
        MeetingSummary(overview: "Plans", modelID: "gemma-4/e4b-4bit", createdAt: created).placed(.thisDevice, by: device, inputs: [:])
    }

    private var date: String { SummaryColophon.date(created) }

    func testBehaviorTheSameSummaryReadsTheSameOnBothDevices() {
        let summary = local(by: studio)
        let onMac = SummaryColophon(summary, thisDeviceID: laptop.id, words: .mac(id: laptop.id, symbol: "laptopcomputer"))
        let onPhone = SummaryColophon(summary, thisDeviceID: phone.id, words: .iPhone(id: phone.id))
        XCTAssertEqual(onMac.line, "Summarized on Studio Mac · Gemma 4 · E4B · \(date)", "the model is named on both")
        XCTAssertEqual(onPhone.line, onMac.line)
        XCTAssertEqual(onMac.symbol, "desktopcomputer")
        XCTAssertEqual(onPhone.symbol, onMac.symbol, "one glyph for one Mac")

        let here = SummaryColophon(summary, thisDeviceID: studio.id, words: .mac(id: studio.id))
        XCTAssertEqual(here.line, "Summarized on this Mac · Gemma 4 · E4B · \(date)")
    }

    func testBehaviorTheGlyphSaysWhatKindOfDeviceItRanOn() {
        // An iPhone's summary never shows a laptop on the Mac, nor another iPhone's a laptop on an iPhone.
        let byPhone = local(by: phone)
        XCTAssertEqual(SummaryColophon(byPhone, thisDeviceID: laptop.id, words: .mac(id: laptop.id)).symbol, "iphone")
        XCTAssertEqual(SummaryColophon(byPhone, thisDeviceID: "other-phone", words: .iPhone(id: "other-phone")).symbol, "iphone")
        XCTAssertEqual(SummaryColophon(byPhone, thisDeviceID: phone.id, words: .iPhone(id: phone.id)).line,
                       "Summarized on this iPhone · Gemma 4 · E4B · \(date)")
        // A MacBook's own glyph, by its name; a device's presence wins over its name.
        XCTAssertEqual(SummaryColophon(local(by: laptop), thisDeviceID: phone.id, words: .iPhone(id: phone.id)).symbol, "laptopcomputer")
        let named = ProcessingRequest.Device(id: "x", name: "Kitchen")
        XCTAssertEqual(SummaryColophon(local(by: named), thisDeviceID: phone.id, words: .iPhone(id: phone.id)).symbol, "macbook.and.iphone")
        XCTAssertEqual(SummaryColophon(local(by: named), thisDeviceID: phone.id, words: .iPhone(id: phone.id), deviceClass: .mac).symbol,
                       "desktopcomputer")
        // From before devices were recorded: a Mac's.
        let old = MeetingSummary(overview: "Old", modelID: "gemma-4/e4b-4bit", createdAt: created)
        XCTAssertEqual(SummaryColophon(old, thisDeviceID: phone.id, words: .iPhone(id: phone.id)).line,
                       "Summarized on your Mac · Gemma 4 · E4B · \(date)")
        XCTAssertEqual(SummaryColophon(old, thisDeviceID: phone.id, words: .iPhone(id: phone.id)).symbol, "desktopcomputer")
        XCTAssertEqual(SummaryColophon(old, thisDeviceID: studio.id, words: .mac(id: studio.id, symbol: "laptopcomputer")).symbol,
                       "laptopcomputer")
    }

    func testBehaviorACloudSummaryNamesItsModelOnce() {
        let sonnet = CloudModel(provider: .anthropic, id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", tier: .balanced,
                                inputPrice: 2, outputPrice: 10, priceIsEstimated: false, contextTokens: nil, rank: 1)
        let summary = MeetingSummary(overview: "Plans", modelID: "anthropic/claude-sonnet-5-5", createdAt: created)
            .placed(.cloud(sonnet), by: phone, inputs: [:])
        let colophon = SummaryColophon(summary, thisDeviceID: laptop.id, words: .mac(id: laptop.id))
        XCTAssertEqual(colophon.line, "Summarized with Claude Sonnet 5.5 · \(date)")
        XCTAssertEqual(colophon.symbol, "cloud")
    }

    func testBehaviorASummaryWithoutAModelLeavesItOut() {
        let summary = MeetingSummary(overview: "Plans", modelID: "", createdAt: created).placed(.thisDevice, by: studio, inputs: [:])
        XCTAssertEqual(SummaryColophon(summary, thisDeviceID: studio.id, words: .mac(id: studio.id)).line, "Summarized on this Mac · \(date)")
    }
}
