import SwiftUI
import XCTest
@testable import DaybookDesign

/// A card's divider starts where the row under it starts its text: past the glyph column, or at the card's edge for a
/// row with none (a conversation at the top of a card, with no device above it).
@MainActor
final class StatusCardTests: XCTestCase {
    private final class Probe { var values: [String: Bool] = [:] }

    /// Reads what each row tells its card, as `StatusCard` does.
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

    func testBehaviorARowAtTheCardsEdgeSaysSoToTheCard() {
        let probe = Probe()
        let card = ProbeCard(probe: probe) {
            ForEach(["a", "b"], id: \.self) { text in
                Text(text).statusRowAtCardEdge().containerValue(\.probeLabel, text)
            }
            Text("c").containerValue(\.probeLabel, "c")
            Text("d").statusRowAtCardEdge(false).containerValue(\.probeLabel, "d")
        }
        _ = ImageRenderer(content: card.frame(width: 200)).cgImage
        XCTAssertEqual(probe.values, ["a": true, "b": true, "c": false, "d": false])
        // And the card draws one from it: a whole card renders.
        _ = ImageRenderer(content: StatusCard { Text("a").statusRowAtCardEdge(); Text("b") }.frame(width: 200)).cgImage
    }
}

extension ContainerValues {
    /// Which row a test's card is looking at.
    @Entry fileprivate var probeLabel = ""
}
