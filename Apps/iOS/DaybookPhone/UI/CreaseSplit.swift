import SwiftUI

/// Two pages split at the crease of an open iPhone Duo, never across it. Shared by the library and
/// the recorder; on a regular iPhone at regular width it's simply the middle.
///
/// The crease is the middle of the whole display, not of the safe area: on the Duo's inner display
/// the status bar is an 84 pt column on the right, so the crease sits at x = 475.5 of 951 pt, and
/// the pages are 475.5 pt (left) and 391.5 pt of safe area (right) (docs/iphone.md, Measured). The
/// system adds no inset for the fold, so each page learns which of its edges meets the crease
/// (`\.creaseEdge`) and keeps its content `PhoneStyle.Page.creaseClearance` away from it.
///
/// The leading page comes first for VoiceOver, then the trailing one, as a reader turns pages.
struct CreaseSplit<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        GeometryReader { proxy in
            let crease = CreaseGeometry.crease(width: proxy.size.width,
                                               leadingInset: proxy.safeAreaInsets.leading,
                                               trailingInset: proxy.safeAreaInsets.trailing)
            HStack(spacing: 0) {
                leading
                    .frame(width: crease)
                    .environment(\.creaseEdge, .trailing)
                    .accessibilityElement(children: .contain)
                    .accessibilitySortPriority(2)
                trailing
                    .frame(maxWidth: .infinity)
                    .environment(\.creaseEdge, .leading)
                    .accessibilityElement(children: .contain)
                    .accessibilitySortPriority(1)
            }
            .overlay(alignment: .leading) {
                CreaseSpine()
                    .frame(width: 24)
                    .offset(x: crease - 12)
                    .ignoresSafeArea(edges: .vertical)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Where the crease falls in a view laid out inside the safe area.
enum CreaseGeometry {
    /// The crease's x in the view's own coordinates: the middle of the full display width, moved
    /// by the leading inset, and kept within the view.
    static func crease(width: CGFloat, leadingInset: CGFloat, trailingInset: CGFloat) -> CGFloat {
        let full = width + leadingInset + trailingInset
        return max(0, min(width, full / 2 - leadingInset))
    }
}

/// The fold between the pages: a hairline with a soft shade either side, like a book's gutter.
/// It holds no content.
private struct CreaseSpine: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shade = Color.black.opacity(scheme == .dark ? 0.28 : 0.045)
        ZStack {
            if contrast == .standard {
                LinearGradient(colors: [.clear, shade], startPoint: .leading, endPoint: .center)
                    .frame(maxWidth: .infinity)
                    .mask(HStack(spacing: 0) { Rectangle(); Color.clear })
                LinearGradient(colors: [shade, .clear], startPoint: .center, endPoint: .trailing)
                    .mask(HStack(spacing: 0) { Color.clear; Rectangle() })
            }
            Rectangle().fill(Color(uiColor: .separator)).frame(width: contrast == .increased ? 1 : 0.5)
        }
    }
}
