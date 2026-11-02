import DaybookKit
import SwiftUI
import XCTest
@testable import DaybookDesign
@testable import DaybookUI

/// The status overview both apps draw: the shared words as lines, its depths, and a queue row's words.
final class StatusOverviewTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testBehaviorTheSharedWordsBecomeTheLineBothAppsDraw() throws {
        let queue = try XCTUnwrap(QueueStatusWords.line(.init(running: .summarizing, countdown: now.addingTimeInterval(12), waiting: 1),
                                                        words: .iPhone(), now: now))
        let line = StatusLineItem(queue)
        XCTAssertEqual(line.id, queue.id)
        XCTAssertEqual(line.title, "This iPhone")
        XCTAssertEqual(line.symbol, "iphone")
        XCTAssertEqual(line.tone, .calm, "a countdown is calm on both apps")
        XCTAssertEqual(line.countdownUntil, now.addingTimeInterval(12))
        XCTAssertEqual(line.text(at: now.addingTimeInterval(2)), queue.text(at: now.addingTimeInterval(2)))
        XCTAssertEqual(line.shortText, queue.shortText)

        let working = try XCTUnwrap(QueueStatusWords.line(.init(running: .transcribing, fraction: 0.4), words: .mac(), now: now))
        XCTAssertEqual(StatusLineItem(working).tone, .working)
        XCTAssertEqual(StatusLineItem(working).progress, 0.4)
        for tone in [StatusLineWords.Tone.calm, .working, .linked, .recording, .attention] {
            let words = StatusLineWords(id: "x", symbol: "x", title: "x", text: "x", tone: tone)
            XCTAssertEqual("\(StatusLineItem(words).tone)", "\(tone)")
        }
    }

    func testBehaviorEachDepthAddsToTheOneBefore() {
        XCTAssertEqual(StatusDensity.allCases, [.lines, .cards, .manage])
        XCTAssertFalse(StatusDensity.lines.showsGroups)
        XCTAssertTrue(StatusDensity.cards.showsGroups)
        XCTAssertTrue(StatusDensity.manage.showsGroups)
        XCTAssertFalse(StatusDensity.cards.manages)
        XCTAssertTrue(StatusDensity.manage.manages)
        XCTAssertLessThan(StatusDensity.lines, StatusDensity.manage)
    }

    private final class Probe { var values: [String: Bool] = [:] }

    private struct ProbeCard<Content: View>: View {
        let probe: Probe
        @ViewBuilder var content: Content
        var body: some View {
            Group(subviews: content) { rows in
                ForEach(rows) { row in
                    let _ = probe.values[row.containerValues.probeLabel] = row.containerValues.statusRowAtCardEdge
                    row
                }
            }
        }
    }

    /// ui-iphone-15: a conversation at the top of a card, with no device above it, starts at the card's edge, and
    /// tells the card so its divider does too.
    @MainActor
    func testBehaviorAQueueRowAtTheTopOfACardTellsTheCard() {
        let probe = Probe()
        let items = [StatusQueueItem(id: UUID(), title: "A", line: "Waiting"), StatusQueueItem(id: UUID(), title: "B", line: "Waiting")]
        let card = ProbeCard(probe: probe) {
            ForEach(items) { item in
                StatusQueueRow(item, indented: false, open: {}).statusRowAtCardEdge().containerValue(\.probeLabel, item.title)
            }
            StatusQueueRow(StatusQueueItem(id: UUID(), title: "C", line: "Waiting")).containerValue(\.probeLabel, "C")
        }
        _ = ImageRenderer(content: card.frame(width: 320)).cgImage
        XCTAssertEqual(probe.values, ["A": true, "B": true, "C": false])
    }

    func testBehaviorAQueueRowCountsDownAndOffersItsChoices() {
        let id = UUID()
        let item = StatusQueueItem(id: id, title: "Weekly sync", line: "Summarizing in 12 s", countdownUntil: now.addingTimeInterval(12),
                                   actions: [.placement(.useCloud), .placement(.startNow)])
        XCTAssertEqual(item.line(at: now.addingTimeInterval(4)), "Summarizing in 8 s")
        XCTAssertEqual(item.actions.map(\.title), ["Use the Cloud", "Start Now"])
        XCTAssertEqual(StatusQueueItem.Action.tryAgain(.newAudio).title, "Try Again")
        let still = StatusQueueItem(id: id, title: "A", line: "Transcribing · 40%", progress: 0.4)
        XCTAssertEqual(still.line(at: now), "Transcribing · 40%")
        XCTAssertFalse(still.isProblem)
    }
}

extension ContainerValues {
    /// Which row a test's card is looking at.
    @Entry fileprivate var probeLabel = ""
}
