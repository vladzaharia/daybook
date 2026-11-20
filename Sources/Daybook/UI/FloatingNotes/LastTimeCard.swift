import DaybookCore
import DaybookDesign
import DaybookKit
import SwiftUI

/// "Last time" over the notes while a calendar meeting records: the earlier conversation of the same meeting, its date,
/// and a few of the next steps still open (`LastTime`). It takes only the height it needs, above the notes and never over
/// them; one press anywhere on it opens that conversation in Daybook. Nothing is drawn when there isn't one.
struct LastTimeCard: View {
    let last: LastTime
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        let shown = last.openSteps.prefix(LastTime.listed)
        let more = last.openSteps.count - shown.count
        Button(action: open) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Last time")
                        .font(.system(size: 10.5, weight: .semibold))
                        .textCase(.uppercase)
                        .tracking(0.5)
                    Text(last.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                        .font(.system(size: 11))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(DaybookPalette.Ink.meta)
                ForEach(Array(shown)) { step in
                    Label {
                        Text(step.text).lineLimit(1)
                    } icon: {
                        Image(systemName: "circle").font(.system(size: 7))
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(DaybookPalette.Ink.secondary)
                }
                if more > 0 {
                    Text("+\(more) more").font(.system(size: 11)).foregroundStyle(DaybookPalette.Ink.meta)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(hovering ? 0.05 : 0.03), in: DaybookRadius.shape(DaybookRadius.row))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, FloatingLayout.inset - 6)
        .padding(.top, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(last))
        .accessibilityHint("Opens it in Daybook")
        .accessibilityAddTraits(.isButton)
    }

    private static func spoken(_ last: LastTime) -> String {
        let date = last.date.formatted(.dateTime.weekday(.wide).month(.wide).day())
        let steps = last.openSteps.prefix(LastTime.listed).map(\.text).joined(separator: ", ")
        return "Last time, \(date)" + (steps.isEmpty ? "" : ". Open next steps: \(steps)")
    }
}
