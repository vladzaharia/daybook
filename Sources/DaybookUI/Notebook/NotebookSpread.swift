#if os(iOS)
import DaybookCore
import DaybookDesign
import SwiftUI
import UIKit

/// The open notebook: two facing pages split at the crease, or one page, each drawn at the same scale on its own paper, with the
/// whole display for writing (docs/notebook.md). The pill and the tools float over the top of the pages as glass and collapse
/// so the paper under them can be written on. Pages never cross the crease. The notes card over the right page is the app's.
public struct NotebookSpread<Tools: View, Pill: View, Caption: View, Card: View>: View {
    public typealias Floating<Content: View> = (_ collapsed: Bool, _ setCollapsed: @escaping (Bool) -> Void, _ available: CGFloat) -> Content

    private let session: NotebookSession
    private let crease: CGFloat?
    private let tools: Floating<Tools>
    private let pill: Floating<Pill>
    private let caption: Caption
    private let card: (_ pageFrame: CGRect, _ isSpread: Bool) -> Card
    private let words: (UUID) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How far down the right page the card starts, clear of the pill.
    private static var cardTop: CGFloat { 72 }

    /// - Parameters:
    ///   - crease: Where the display folds, in the safe area; nil for one display.
    ///   - tools: Floating over the left page's top (a single page's foot).
    ///   - pill: Floating over the right page's top.
    ///   - caption: The live caption line, under the last page where there's a strip, over it as glass where there isn't.
    ///   - card: Over the last open page, clear of the crease (the notes card); `isSpread` says whether it sits beside a page.
    ///   - words: Opens a page's words.
    public init(session: NotebookSession, crease: CGFloat?, @ViewBuilder tools: @escaping Floating<Tools>,
                @ViewBuilder pill: @escaping Floating<Pill>, @ViewBuilder caption: () -> Caption,
                @ViewBuilder card: @escaping (CGRect, Bool) -> Card, words: @escaping (UUID) -> Void) {
        self.session = session; self.crease = crease; self.tools = tools; self.pill = pill; self.caption = caption()
        self.card = card; self.words = words
    }

    public var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let page = CGSize(width: NotebookPage.a5.width, height: NotebookPage.a5.height)
            let layout = NotebookLayout.resolve(size: size, crease: crease, page: page)
            let frames = layout.frames(in: size, crease: crease, page: page)
            let open = Array(session.visible.prefix(frames.count))
            ZStack(alignment: .topLeading) {
                ForEach(Array(open.enumerated()), id: \.element.id) { index, page in
                    PageSurface(session: session, page: page, isFirst: index == 0, isLast: index == open.count - 1,
                                isSingle: !layout.isSpread)
                        .frame(width: frames[index].width, height: frames[index].height)
                        .offset(x: frames[index].minX, y: frames[index].minY)
                        .transition(.opacity)
                    if layout.hasStrip(under: frames[index], in: size) {
                        strip(page, frame: frames[index], isLast: index == open.count - 1)
                    }
                }
                if let last = frames.last, let first = frames.first {
                    let inset = NotebookLayout.margin
                    // The card is under the pill and the tools, over the rest of the right page: Stop is never covered.
                    card(CGRect(x: last.minX, y: last.minY + Self.cardTop, width: last.width, height: last.height - Self.cardTop), layout.isSpread)
                    // The tools: top-left of the left page, the foot of a single page.
                    NotebookFloating(session: session, edge: .leading) { collapsed, set in
                        tools(collapsed, set, first.width - 2 * inset)
                    }
                    .frame(width: first.width - 2 * inset, height: first.height - 2 * inset,
                           alignment: layout.isSpread ? .topLeading : .bottomLeading)
                    .offset(x: first.minX + inset, y: first.minY + inset)
                    // The pill: top-right of the right page.
                    NotebookFloating(session: session, edge: .trailing) { collapsed, set in
                        pill(collapsed, set, last.width - 2 * inset)
                    }
                    .frame(width: last.width - 2 * inset, height: last.height - 2 * inset, alignment: .topTrailing)
                    .offset(x: last.minX + inset, y: last.minY + inset)
                    if !layout.hasStrip(under: last, in: size) {
                        NotebookFloatingCaption(session: session, pageFrame: last, origin: proxy.frame(in: .global).origin) { caption }
                    }
                }
                if let crease { CreaseSpineLine().offset(x: crease).allowsHitTesting(false) }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .animation(DaybookMotion.resolved(DaybookMotion.page, reduceMotion: reduceMotion), value: session.first)
            .onChange(of: layout, initial: true) { _, new in session.resolve(new) }
            .onChange(of: session.pages.count) { session.reconcile() }
        }
    }

    /// Under a page: its number (a menu for what can be done with the page) and, under the last page, the caption line.
    private func strip(_ page: NotebookPage, frame: CGRect, isLast: Bool) -> some View {
        HStack(spacing: 0) {
            PageNumberMenu(session: session, page: page, words: words)
            if isLast { caption }
        }
        .frame(width: frame.width, height: NotebookLayout.stripHeight, alignment: isLast ? .leading : .center)
        .offset(x: frame.minX, y: frame.maxY)
    }
}

/// A control floating over the paper, glass: it collapses to its chip when dragged toward the display's edge, and by itself when
/// a pen is writing near it, coming back a moment after the stroke ends. Reduce Motion fades instead of sliding.
struct NotebookFloating<Content: View>: View {
    let session: NotebookSession
    /// The edge it collapses toward.
    let edge: HorizontalEdge
    let content: (_ collapsed: Bool, _ setCollapsed: @escaping (Bool) -> Void) -> Content
    @State private var chosen: Bool
    @State private var steppedAside = false
    @State private var frame: CGRect = .zero
    @State private var returning: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(session: NotebookSession, edge: HorizontalEdge,
         @ViewBuilder content: @escaping (_ collapsed: Bool, _ setCollapsed: @escaping (Bool) -> Void) -> Content) {
        self.session = session; self.edge = edge; self.content = content
        _chosen = State(initialValue: session.startsCollapsed)
    }

    private var collapsed: Bool { chosen || steppedAside }

    var body: some View {
        // Glass over paper, and the paper is always light: so it is too, in Dark Mode.
        content(collapsed) { chosen = $0 }
            .environment(\.colorScheme, .light)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .transition(reduceMotion ? .opacity : .move(edge: edge == .leading ? .leading : .trailing).combined(with: .opacity))
            .id(collapsed)
            .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { value in
                let toward = edge == .leading ? -value.translation.width : value.translation.width
                if toward > 40, abs(value.translation.height) < toward { chosen = true }
            })
            .onChange(of: session.writingPoint) { _, point in
                if let point {
                    if PenProximity.isNear(point, frame) { returning?.cancel(); steppedAside = true }
                } else if steppedAside {
                    returning = Task {
                        try? await Task.sleep(for: PenProximity.returnDelay)
                        guard !Task.isCancelled else { return }
                        steppedAside = false
                    }
                }
            }
            .animation(DaybookMotion.resolved(DaybookMotion.fade, reduceMotion: reduceMotion), value: collapsed)
            .accessibilityAction(named: "Collapse") { chosen = true }
    }
}

/// The caption line as glass over the foot of the last page, for a display with no strip under it. It steps aside for a pen.
private struct NotebookFloatingCaption<Caption: View>: View {
    let session: NotebookSession
    let pageFrame: CGRect
    let origin: CGPoint
    @ViewBuilder let caption: Caption

    var body: some View {
        let zone = pageFrame.offsetBy(dx: origin.x, dy: origin.y)
        caption
            .padding(.horizontal, DaybookSpacing.s3)
            .glassEffect(.regular, in: Capsule())
            .frame(width: pageFrame.width - 16)
            .offset(x: pageFrame.minX + 8, y: pageFrame.maxY - 48)
            .opacity(PenProximity.isNear(session.writingPoint, CGRect(x: zone.minX, y: zone.maxY - 80, width: zone.width, height: 80)) ? 0 : 1)
            .animation(.easeOut(duration: 0.2), value: session.writingPoint == nil)
    }
}

/// The page's number, a menu for what can be done with the page.
private struct PageNumberMenu: View {
    let session: NotebookSession
    let page: NotebookPage
    let words: (UUID) -> Void

    var body: some View {
        let number = session.number(of: page.id) ?? 1
        Menu {
            Button("Words") { words(page.id) }
            if session.model?.isEditable == true {
                Button("Delete Page", role: .destructive) { _ = session.remove(page.id) }
            }
        } label: {
            Text("\(number)")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(DaybookPalette.Ink.secondary)
                .frame(minWidth: 44, minHeight: NotebookLayout.stripHeight)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Page \(number) menu")
    }
}

/// A hairline where the display folds, drawn under nothing: pages stay clear of it.
private struct CreaseSpineLine: View {
    var body: some View {
        Rectangle().fill(DaybookPalette.Ink.faint.opacity(0.35)).frame(width: 0.5)
            .frame(maxHeight: .infinity)
            .ignoresSafeArea(edges: .vertical)
            .accessibilityHidden(true)
    }
}

/// One open page: its canvas, its number (a menu), and a corner to turn it by.
private struct PageSurface: View {
    @Bindable var session: NotebookSession
    let page: NotebookPage
    let isFirst: Bool
    let isLast: Bool
    let isSingle: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let number = session.number(of: page.id) ?? 1
        ZStack {
            if let canvas = session.canvas(for: page.id) {
                PageCanvasHost(canvas: canvas)
            } else {
                Color(uiColor: PagePaperView.sheet)
            }
            if session.loading.contains(page.id) {
                ProgressView().tint(.gray).accessibilityLabel("Loading page \(number)")
            } else if session.unavailable.contains(page.id) {
                Text("This page’s writing isn’t available.")
                    .font(.footnote)
                    .foregroundStyle(Color(white: 0.35))
                    .multilineTextAlignment(.center)
                    .padding(DaybookSpacing.s5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.14), radius: 8, y: 2)
        .overlay(alignment: isFirst && !isLast ? .bottomLeading : .bottomTrailing) { corner }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Page \(number)")
    }

    /// The page's outer bottom corner turns it: back from the left page, on from the right (or only) one.
    @ViewBuilder private var corner: some View {
        let isBack = isFirst && !isLast
        let enabled = isBack ? session.canGoBack : session.canGoForward
        if enabled {
            Button { withAnimation(DaybookMotion.resolved(DaybookMotion.page, reduceMotion: reduceMotion)) { session.turn(isBack ? -1 : 1) } } label: {
                DogEar(flipped: isBack)
                    .fill(Color.black.opacity(0.1))
                    .frame(width: 30, height: 30)
                    .frame(width: 44, height: 44, alignment: isBack ? .bottomLeading : .bottomTrailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isBack ? "Previous Pages" : "Next Pages")
        }
    }
}

private struct DogEar: Shape {
    let flipped: Bool
    func path(in rect: CGRect) -> Path {
        var path = Path()
        if flipped {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY)); path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY)); path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        path.closeSubpath()
        return path
    }
}

/// Shows a pooled canvas: the same view moves between hosts as the layout changes, so a fold never recreates it.
private struct PageCanvasHost: UIViewRepresentable {
    let canvas: PageCanvasView

    func makeUIView(context: Context) -> CanvasContainer { CanvasContainer(canvas) }

    func updateUIView(_ container: CanvasContainer, context: Context) { container.adopt(canvas) }

    final class CanvasContainer: UIView {
        init(_ canvas: PageCanvasView) {
            super.init(frame: .zero)
            adopt(canvas)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        func adopt(_ canvas: PageCanvasView) {
            guard canvas.superview !== self else { return }
            canvas.removeFromSuperview()
            addSubview(canvas)
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            subviews.forEach { $0.frame = bounds }
        }
    }
}

/// The pen, highlighter, eraser, lasso, Undo and Redo, and the pen's colours: in full when there's room, otherwise the tool
/// and its colour in a menu beside Undo and Redo.
public struct NotebookTools: View {
    @Bindable private var ink: InkSession

    public init(ink: InkSession) { self.ink = ink }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            InkTools(session: ink, showsColors: true)
            compact
        }
    }

    private var compact: some View {
        HStack(spacing: 0) {
            Menu {
                Picker("Tool", selection: $ink.tool) {
                    ForEach(InkSession.Tool.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                Picker("Colour", selection: $ink.color) {
                    ForEach(InkColor.allCases) { colour in Text(colour.title).tag(colour) }
                }
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: ink.tool.symbol).font(.body.weight(.medium)).foregroundStyle(DaybookPalette.Ink.title)
                    Circle().fill(ink.color.color).frame(width: 10, height: 10).offset(x: 6, y: 4)
                }
                .frame(width: 42, height: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Pen")
            Button { ink.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 38, height: 44).contentShape(Rectangle()) }
                .disabled(!ink.canUndo).opacity(ink.canUndo ? 1 : 0.35).accessibilityLabel("Undo")
            Button { ink.redo() } label: { Image(systemName: "arrow.uturn.forward").frame(width: 38, height: 44).contentShape(Rectangle()) }
                .disabled(!ink.canRedo).opacity(ink.canRedo ? 1 : 0.35).accessibilityLabel("Redo")
        }
        .buttonStyle(.plain)
        .foregroundStyle(DaybookPalette.Ink.title)
        .padding(.horizontal, DaybookSpacing.s1)
        .glassEffect(.regular, in: Capsule())
        .fixedSize()
    }
}

/// The tools collapsed: one button showing the pen's tool and colour, which opens them again.
public struct NotebookToolsChip: View {
    @Bindable private var ink: InkSession
    private let expand: () -> Void

    public init(ink: InkSession, expand: @escaping () -> Void) { self.ink = ink; self.expand = expand }

    public var body: some View {
        Button(action: expand) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: ink.tool.symbol).font(.body.weight(.medium)).foregroundStyle(DaybookPalette.Ink.title)
                Circle().fill(ink.color.color).frame(width: 10, height: 10).offset(x: 6, y: 4)
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: Circle())
        .accessibilityLabel("Tools")
    }
}
#endif
