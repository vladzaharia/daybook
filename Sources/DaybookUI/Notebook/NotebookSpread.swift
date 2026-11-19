#if os(iOS)
import DaybookCore
import DaybookDesign
import SwiftUI
import UIKit

/// The open notebook: two facing pages split at the crease, or one page, each drawn at the same scale on its own paper
/// (docs/notebook.md). A band over the pages holds the tools (left) and what the app puts there, the recorder pill (right).
/// Pages never cross the crease. Everything else, the notes card over the right page included, is the app's.
public struct NotebookSpread<Band: View, Pill: View, Foot: View, Card: View>: View {
    private let session: NotebookSession
    private let crease: CGFloat?
    private let band: Band
    private let pill: Pill
    private let foot: (_ page: UUID?) -> Foot
    private let card: (_ pageFrame: CGRect, _ isSpread: Bool) -> Card
    private let words: (UUID) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - crease: Where the display folds, in the safe area; nil for one display.
    ///   - band: Leading the band, beside the tools.
    ///   - foot: Under the last open page (the live caption).
    ///   - card: Over the last open page, clear of the crease (the notes card); `isSpread` says whether it sits beside a page.
    ///   - words: Opens a page's words.
    public init(session: NotebookSession, crease: CGFloat?, @ViewBuilder band: () -> Band, @ViewBuilder pill: () -> Pill,
                @ViewBuilder foot: @escaping (UUID?) -> Foot, @ViewBuilder card: @escaping (CGRect, Bool) -> Card,
                words: @escaping (UUID) -> Void) {
        self.session = session; self.crease = crease; self.band = band(); self.pill = pill(); self.foot = foot; self.card = card
        self.words = words
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
                    PageSurface(session: session, page: page, scale: layout.scale, isFirst: index == 0, isLast: index == open.count - 1,
                                isSingle: !layout.isSpread, words: words)
                        .frame(width: frames[index].width, height: frames[index].height)
                        .offset(x: frames[index].minX, y: frames[index].minY)
                        .transition(.opacity)
                }
                if let last = frames.last { card(last, layout.isSpread) }
                if layout.isSpread {
                    HStack(alignment: .top, spacing: 0) {
                        band.frame(maxWidth: .infinity, alignment: .leading)
                        pill
                    }
                    .padding(.horizontal, NotebookLayout.margin)
                    .padding(.top, DaybookSpacing.s1)
                } else {
                    // One page: the pill takes the top, and the tools the foot, where there's the room for them.
                    pill
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, NotebookLayout.margin)
                        .padding(.top, DaybookSpacing.s1)
                    band
                        .padding(.leading, NotebookLayout.margin)
                        .frame(width: size.width, height: size.height, alignment: .bottomLeading)
                        .padding(.bottom, DaybookSpacing.s1)
                }
                if let last = frames.last {
                    foot(open.last?.id)
                        .frame(width: last.width, alignment: .center)
                        .offset(x: last.minX, y: last.maxY - 30)
                }
                if let crease { CreaseSpineLine().offset(x: crease).allowsHitTesting(false) }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .animation(DaybookMotion.resolved(DaybookMotion.page, reduceMotion: reduceMotion), value: session.first)
            .onChange(of: layout, initial: true) { _, new in session.resolve(new) }
            .onChange(of: session.pages.count) { session.reconcile() }
        }
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
    let scale: CGFloat
    let isFirst: Bool
    let isLast: Bool
    let isSingle: Bool
    let words: (UUID) -> Void
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
        .overlay(alignment: isSingle ? .bottomTrailing : .bottom) { numberLabel(number).offset(y: 34) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Page \(number)")
    }

    /// The page's number under it, a menu for what can be done with the page.
    private func numberLabel(_ number: Int) -> some View {
        Menu {
            Button("Words") { words(page.id) }
            if session.model?.isEditable == true {
                Button("Delete Page", role: .destructive) { _ = session.remove(page.id) }
            }
        } label: {
            Text("\(number)")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(DaybookPalette.Ink.secondary)
                .frame(minWidth: 44, minHeight: 30)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Page \(number) menu")
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
#endif
