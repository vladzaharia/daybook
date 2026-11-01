import DaybookCaptions
import DaybookDesign
import DaybookUI
import SwiftUI

/// The recording's live captions on its screen: the shared `LiveCaptionStrip` in the style the posture
/// asks for (`.strip` in a pocket, `.page` on the notebook's right page, `.stage` on the table), as
/// Floating Notes draws them on the Mac. Shown while captions can run; the newest lines once heard,
/// else what they're doing ("Listening…").
struct LiveCaptionsView: View {
    @Environment(PhoneAppModel.self) private var model
    var style: CaptionStripStyle

    var body: some View {
        let captions = model.captions
        if captions.isShowing {
            LiveCaptionStrip(segments: captions.recent(style.lines), state: captions.state, locale: model.settings.captionLocale,
                             names: captions.sourceNames, style: style)
        }
    }
}

/// Two halves split at a horizontal crease: the iPhone Duo partly open and turned a quarter turn
/// like a laptop, the top half standing and the bottom half flat on the table. The crease is the
/// middle of the whole display, not of the safe area. `CreaseSplit` (vertical) is the reading work's;
/// this is the recorder's.
struct HorizontalCreaseSplit<Top: View, Bottom: View>: View {
    @ViewBuilder var top: Top
    @ViewBuilder var bottom: Bottom

    var body: some View {
        GeometryReader { proxy in
            let full = proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
            let crease = max(0, min(proxy.size.height, full / 2 - proxy.safeAreaInsets.top))
            VStack(spacing: 0) {
                top.frame(height: crease)
                Rectangle().fill(.separator).frame(height: 1).ignoresSafeArea(edges: .horizontal)
                bottom.frame(maxHeight: .infinity)
            }
        }
    }
}
