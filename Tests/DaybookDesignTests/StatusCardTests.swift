import SwiftUI
import XCTest
@testable import DaybookDesign

/// A card's divider starts where the row under it starts its text: past the glyph column, or at the card's edge for a
/// row with none (a conversation at the top of a card, with no device above it).
@MainActor
final class StatusCardTests: XCTestCase {
    private final class Probe { var values: [Bool] = [] }

    private struct ProbeCard<Content: View>: View {
        let probe: Probe
        @ViewBuilder var content: Content
        var body: some View {
            Group(subviews: content) { rows in
                ForEach(rows) { row in
                    let _ = probe.values.append(row.containerValues.statusRowAtCardEdge)
                    row
                }
            }
        }
    }

    private struct Row: View {
        let text: String
        var body: some View { Text(text).padding(4) }
    }

    func testBehaviorARowAtTheCardsEdgeSaysSoToTheCard() {
        let probe = Probe()
        let card = ProbeCard(probe: probe) {
            ForEach(["a", "b"], id: \.self) { text in Row(text: text).statusRowAtCardEdge() }
            Row(text: "c")
            Row(text: "d").statusRowAtCardEdge(false)
        }
        let renderer = ImageRenderer(content: card.frame(width: 200))
        _ = renderer.cgImage
        XCTAssertEqual(probe.values, [true, true, false, false])
    }
}
