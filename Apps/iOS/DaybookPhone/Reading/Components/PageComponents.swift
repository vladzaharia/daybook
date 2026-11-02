import DaybookDesign
import DaybookKit
import DaybookUI
import SwiftUI

// The side of a page that meets the iPhone Duo's crease is DaybookUI's `creaseEdge`, which its pages read too.

extension EnvironmentValues {
    /// The library search's text, so the page can mark its matches.
    @Entry var findQuery: String = ""
    /// True when this page is one of two (the notebook): links between the pages work by scrolling
    /// the other page instead of switching to it.
    @Entry var isTwoPage: Bool = false
}

/// A page's column: centred, at most the Mac's measure wide, with the gutters a phone page needs and
/// extra room on the side that meets the crease.
struct PageColumn: ViewModifier {
    @Environment(\.creaseEdge) private var creaseEdge

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: PhoneStyle.Page.measure, alignment: .leading)
            .padding(.leading, PhoneStyle.Page.gutter + (creaseEdge == .leading ? PhoneStyle.Page.creaseClearance - 8 : 0))
            .padding(.trailing, PhoneStyle.Page.gutter + (creaseEdge == .trailing ? PhoneStyle.Page.creaseClearance - 8 : 0))
            .frame(maxWidth: .infinity)
    }
}

extension View {
    func pageColumn() -> some View { modifier(PageColumn()) }
}

/// A time that plays from there: meta ink, monospaced digits.
struct TimeButton: View {
    let time: TimeInterval
    var ink: Color = PhoneStyle.Ink.meta
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            Text(TimeLabel.short(time))
                .font(PhoneStyle.Typeface.time)
                .foregroundStyle(ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                // A 44 pt target without making its row taller.
                .daybookHitTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play from \(SpokenTime.format(time))")
    }
}

/// A heading on the page: Body ink at semibold. Weight, not grey, makes a heading.
struct PageHeading: View {
    let text: String
    var body: some View {
        Text(text)
            .font(PhoneStyle.Typeface.heading)
            .foregroundStyle(PhoneStyle.Ink.body)
            .accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A tag, as a teal chip.
struct TagChip: View {
    let tag: String
    var body: some View {
        Text(tag)
            .font(.caption.weight(.medium))
            .foregroundStyle(PhoneStyle.Ink.link)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(PhoneStyle.accent.opacity(0.14), in: Capsule())
    }
}

/// Paper behind a page, under the status column and home indicator too.
struct PaperBackground: ViewModifier {
    func body(content: Content) -> some View {
        content.background(PhoneStyle.paper.ignoresSafeArea())
    }
}

extension View {
    func paperBackground() -> some View { modifier(PaperBackground()) }
}
