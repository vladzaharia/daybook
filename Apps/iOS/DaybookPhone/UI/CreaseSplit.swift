import DaybookUI
import SwiftUI

/// Two pages split at the crease of an open iPhone Duo, never across it. Shared by the library and
/// the recorder; on a regular iPhone at regular width it's simply the middle.
///
/// The crease is the middle of the whole display, not of the safe area: on the Duo's inner display
/// the status bar is an 84 pt column on the right, so the crease sits at x = 475.5 of 951 pt, and
/// the pages are 475.5 pt (left) and 391.5 pt of safe area (right) (docs/iphone.md, Measured). The
/// system adds no inset for the fold, so each page learns which of its edges meets the crease
/// (`\.creaseEdge`) and keeps its reading content and controls clear of it.
///
/// The leading page comes first for VoiceOver, then the trailing one, as a reader turns pages.
struct CreaseSplit<Leading: View, Trailing: View>: View {
    /// Only the open conversation supplies a rail. Other uses keep the plain spine.
    var spineRail: ConversationSpineRail? = nil
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
                CreaseSpine(rail: spineRail)
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
private struct CreaseSpine: View {
    let rail: ConversationSpineRail?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    init(rail: ConversationSpineRail?) {
        self.rail = rail
    }

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
            if let rail { SpineTimeline(rail: rail) }
        }
    }
}

/// A passive overview of the open conversation's timeline, entirely within the existing spine.
private struct SpineTimeline: View {
    let rail: ConversationSpineRail

    var body: some View {
        GeometryReader { proxy in
            let inset = min(52, proxy.size.height / 2)
            let length = max(0, proxy.size.height - inset * 2)
            let x = proxy.size.width / 2
            ZStack {
                Capsule()
                    .fill(Color.secondary.opacity(0.55))
                    .frame(width: 1, height: length)
                    .position(x: x, y: inset + length / 2)
                ForEach(rail.data.bookmarks.indices, id: \.self) { index in
                    Capsule()
                        .fill(PhoneStyle.bookmark)
                        .frame(width: 10, height: 2)
                        .position(x: x, y: inset + length * CGFloat(rail.data.bookmarks[index]))
                }
                if let player = rail.player, let fraction = rail.data.playhead(at: player.position) {
                    Circle()
                        .fill(PhoneStyle.neonMint)
                        .frame(width: 7, height: 7)
                        .position(x: x, y: inset + length * CGFloat(fraction))
                }
            }
        }
    }
}
