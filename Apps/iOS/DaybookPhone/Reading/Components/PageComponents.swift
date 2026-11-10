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
/// the specified full clearance on the side that meets it.
struct PageColumn: ViewModifier {
    let creaseClearance: CGFloat
    @Environment(\.creaseEdge) private var creaseEdge

    init(creaseClearance: CGFloat) {
        self.creaseClearance = creaseClearance
    }

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: PhoneStyle.Page.measure, alignment: .leading)
            .padding(.leading, Self.inset(for: .leading, creaseEdge: creaseEdge, creaseClearance: creaseClearance))
            .padding(.trailing, Self.inset(for: .trailing, creaseEdge: creaseEdge, creaseClearance: creaseClearance))
            .frame(maxWidth: .infinity)
    }

    static func inset(for edge: Edge, creaseEdge: Edge?, creaseClearance: CGFloat) -> CGFloat {
        edge == creaseEdge ? creaseClearance : PhoneStyle.Page.gutter
    }
}

extension View {
    func pageColumn(creaseClearance: CGFloat = PhoneStyle.Page.readingCreaseClearance) -> some View {
        modifier(PageColumn(creaseClearance: creaseClearance))
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
