import DaybookCaptions
import SwiftUI

/// Live captions as calm closed captions: the newest line large and in body ink, earlier lines
/// smaller and quieter, words still being heard in lighter ink, and a small "Live captions ·
/// tentative" label, because they're never the transcript.
struct LiveCaptionsView: View {
    enum Style {
        /// Pocket: two lines in a strip above the controls.
        case strip
        /// Notebook: a column on the right page.
        case page
        /// Table, landscape: large type on the standing half, readable across a table.
        case stage
    }

    @Environment(PhoneAppModel.self) private var model
    var style: Style

    var body: some View {
        let captions = model.captions
        if captions.isShowing {
            VStack(alignment: .leading, spacing: spacing) {
                label
                switch captions.state {
                case .listening:
                    if captions.segments.isEmpty {
                        Text("Listening…").font(lineFont(newest: false)).foregroundStyle(PhoneStyle.Ink.meta)
                    } else {
                        lines(captions.recent(lineCount))
                    }
                default:
                    Text(stateLine(captions.state))
                        .font(style == .stage ? .title3 : .subheadline)
                        .foregroundStyle(PhoneStyle.Ink.meta)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Live captions, tentative")
            .accessibilityValue(captions.segments.last?.text ?? "")
        }
    }

    private var lineCount: Int {
        switch style {
        case .strip: return 2
        case .page: return 4
        case .stage: return 2
        }
    }

    private var spacing: CGFloat { style == .stage ? 10 : 6 }

    private var label: some View {
        Label("Live captions · tentative", systemImage: "captions.bubble")
            .font(style == .stage ? .subheadline.weight(.semibold) : .caption.weight(.semibold))
            .foregroundStyle(PhoneStyle.Ink.meta)
            .textCase(.uppercase)
            .tracking(0.5)
    }

    private func lines(_ segments: [LiveCaptionSegment]) -> some View {
        VStack(alignment: .leading, spacing: style == .stage ? 8 : 4) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                let newest = index == segments.count - 1
                Text(segment.text)
                    .font(lineFont(newest: newest))
                    .foregroundStyle(segment.isTentative ? PhoneStyle.Ink.meta : (newest ? PhoneStyle.Ink.body : PhoneStyle.Ink.secondary))
                    // The newest line keeps its latest words; earlier ones read from the start.
                    .lineLimit(newest ? (style == .stage ? 3 : 2) : (style == .page ? 2 : 1))
                    .truncationMode(newest ? .head : .tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: segments.map(\.id))
    }

    private func lineFont(newest: Bool) -> Font {
        switch style {
        case .strip: return newest ? .system(size: 19, weight: .medium) : .system(size: 15)
        case .page: return newest ? .system(size: 21, weight: .medium) : .system(size: 17)
        case .stage: return newest ? .system(size: 34, weight: .medium) : .system(size: 24)
        }
    }

    private func stateLine(_ state: LiveCaptionState) -> String {
        switch state {
        case .preparing: return "Getting captions ready…"
        case .downloading(let fraction):
            let percent = fraction.map { " · \(Int($0 * 100))%" } ?? ""
            return "Downloading captions for \(LiveCaptionAvailability.name(model.settings.captionLocale))\(percent)"
        case .unavailable(let reason): return reason
        case .failed: return "Captions stopped"
        case .listening, .off, .finished: return ""
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
