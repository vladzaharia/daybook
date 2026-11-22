#if os(macOS) && canImport(PencilKit)
import CoreGraphics
import DaybookCore
import DaybookDesign
import DaybookKit
import SwiftUI

/// What the notebook block says, the same words as the iPhone's notebook.
enum NotebookPagesWords {
    static let heading = "Notebook"
    static func page(_ number: Int) -> String { "Page \(number)" }
    static func position(_ number: Int, of total: Int) -> String { "Page \(number) of \(total)" }
    static func summaryChoice(leftOut: Bool) -> String { leftOut ? "Include in Summaries" : "Leave Out of Summaries" }
    static let unavailable = "This page’s writing isn’t available."

    /// A page's accessibility label: its number, and when it is out of summaries.
    static func label(_ number: Int, leftOut: Bool) -> String { leftOut ? "\(page(number)), left out of summaries" : page(number) }

    /// The time a passage was written, in the recording ("2:05"), nil without one.
    static func time(_ passage: NotebookPassage) -> String? { PageWordsList.time(passage) }
}

/// A conversation's handwritten notebook pages, read only: a heading and a row of pages (the iPhone writes them; the Mac shows them),
/// each opening larger with its words. Nothing shows for a conversation with no pages. Pages that are deleted aren't here.
public struct NotebookPagesBlock: View {
    private let meeting: Meeting
    private let library: LibraryController
    private let canPlay: Bool
    private let play: (PlaybackTarget) -> Void
    @State private var opened: UUID?
    @Environment(\.readingScale) private var scale
    @Environment(\.daybookDensity) private var density

    /// - Parameters:
    ///   - canPlay: Whether a passage's time plays the conversation (not while it records).
    ///   - play: Plays the conversation from a passage's moment.
    public init(meeting: Meeting, library: LibraryController, canPlay: Bool = true, play: @escaping (PlaybackTarget) -> Void) {
        self.meeting = meeting; self.library = library; self.canPlay = canPlay; self.play = play
    }

    /// A strip tile's width, a page's shape (A5) taller than a photo's tile.
    static func tileWidth(density: DaybookDensity, scale: CGFloat) -> CGFloat { density == .touch ? 96 : 104 * scale }

    public var body: some View {
        let pages = meeting.visiblePages
        if !pages.isEmpty {
            VStack(alignment: .leading, spacing: DaybookSpacing.s2) {
                PageBlock {
                    Text(NotebookPagesWords.heading)
                        .font(DaybookFont.heading.font(density, scale: scale))
                        .foregroundStyle(DaybookPalette.Ink.body)
                        .accessibilityAddTraits(.isHeader)
                }
                PageBlock {
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: density == .touch ? DaybookSpacing.s3 : DaybookSpacing.s2) {
                            ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                                NotebookPageTile(page: page, number: index + 1, meetingID: meeting.id, library: library,
                                                 width: Self.tileWidth(density: density, scale: scale)) { opened = page.id }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .padding(.top, DaybookSpacing.s6)
            #if DEBUG
            // `--open-notebook-page <n>`: opens the nth page, for snapshots.
            .task(id: pages.count) {
                let arguments = CommandLine.arguments
                if let at = arguments.firstIndex(of: "--open-notebook-page"), arguments.indices.contains(at + 1),
                   let number = Int(arguments[at + 1]), pages.indices.contains(number - 1), opened == nil { opened = pages[number - 1].id }
            }
            #endif
            .sheet(isPresented: Binding(get: { opened != nil }, set: { if !$0 { opened = nil } })) {
                NotebookPageSheet(meetingID: meeting.id, library: library, start: opened, canPlay: canPlay, play: play)
            }
        }
    }
}

/// One page's picture on its paper.
struct NotebookPageImage: View {
    let page: NotebookPage
    let meetingID: UUID
    let library: LibraryController
    let maxPixels: Int
    @State private var image: CGImage?
    @State private var unavailable = false

    var body: some View {
        Color(cgColor: NotebookPageImages.sheet)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                } else if unavailable {
                    Image(systemName: "scribble").foregroundStyle(Color(white: 0.55)).accessibilityHidden(true)
                }
            }
            .task(id: "\(NotebookPageImages.key(page, maxPixels: maxPixels))") { await load() }
    }

    private func load() async {
        if let hit = NotebookPageImages.shared.cached(page, maxPixels: maxPixels) { image = hit; unavailable = false; return }
        image = nil
        var file: URL?
        if let drawing = page.drawing {
            guard library.hasLocalPageDrawing(drawing, in: meetingID), let url = try? await library.pageDrawingURL(for: drawing, in: meetingID) else {
                unavailable = true
                return
            }
            file = url
        }
        let made = await NotebookPageImages.shared.image(of: page, file: file, maxPixels: maxPixels)
        guard !Task.isCancelled else { return }
        image = made
        unavailable = made == nil
    }
}

/// A page in the strip: its picture at its own shape, its number under it.
private struct NotebookPageTile: View {
    let page: NotebookPage
    let number: Int
    let meetingID: UUID
    let library: LibraryController
    let width: CGFloat
    let open: () -> Void
    @Environment(\.readingScale) private var scale
    @Environment(\.daybookDensity) private var density

    var body: some View {
        let leftOut = page.hiddenFromSummary == true
        Button(action: open) {
            VStack(alignment: .leading, spacing: 4) {
                NotebookPageImage(page: page, meetingID: meetingID, library: library, maxPixels: 480)
                    .aspectRatio(page.width / max(1, page.height), contentMode: .fit)
                    .frame(width: width)
                    .clipShape(DaybookRadius.shape(DaybookRadius.row))
                    .overlay(DaybookRadius.shape(DaybookRadius.row).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                HStack(spacing: 4) {
                    Text("\(number)").monospacedDigit()
                    if leftOut { Image(systemName: "text.badge.minus").accessibilityHidden(true) }
                }
                .font(DaybookFont.marginTime.font(density, scale: scale))
                .foregroundStyle(DaybookPalette.Ink.meta)
            }
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NotebookPagesWords.label(number, leftOut: leftOut))
        .accessibilityAddTraits(.isButton)
        .contextMenu {
            Button(NotebookPagesWords.summaryChoice(leftOut: leftOut), systemImage: leftOut ? "text.badge.plus" : "text.badge.minus") {
                library.setPageHiddenFromSummary(page.id, hidden: !leftOut, in: meetingID)
            }
        }
    }
}

/// A page larger over the conversation: the page with its words beside it, a way to the other pages, and a way to leave it out of
/// summaries. Nothing here changes the page's writing.
private struct NotebookPageSheet: View {
    let meetingID: UUID
    let library: LibraryController
    let canPlay: Bool
    let play: (PlaybackTarget) -> Void
    @State private var current: UUID
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @Environment(\.dismiss) private var dismiss

    init(meetingID: UUID, library: LibraryController, start: UUID?, canPlay: Bool, play: @escaping (PlaybackTarget) -> Void) {
        self.meetingID = meetingID; self.library = library; self.canPlay = canPlay; self.play = play
        _current = State(initialValue: start ?? UUID())
    }

    private var meeting: Meeting? { library.meeting(meetingID) }
    private var pages: [NotebookPage] { meeting?.visiblePages ?? [] }
    private var index: Int { pages.firstIndex { $0.id == current } ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            if let page = pages.indices.contains(index) ? pages[index] : nil, let meeting {
                HStack(alignment: .top, spacing: 0) {
                    paper(page)
                    Divider()
                    words(page, meeting: meeting)
                        .frame(width: 240)
                }
                Divider()
                footer(page)
            } else {
                Text("This page is gone.").foregroundStyle(DaybookPalette.Ink.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear { if pages.isEmpty { dismiss() } }
            }
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 560, idealHeight: 680)
        .background(.background)
        .onChange(of: pages.map(\.id)) { _, ids in if !ids.contains(current), let first = ids.first { current = first } }
    }

    /// The page, fit to the space, zoomed by pinch, ⌘+ and ⌘−; scrolls once it is larger than the space.
    private func paper(_ page: NotebookPage) -> some View {
        GeometryReader { proxy in
            let fit = min((proxy.size.width - 48) / page.width, (proxy.size.height - 48) / page.height)
            let level = min(4, max(1, zoom * pinch))
            ScrollView(level > 1 ? [.horizontal, .vertical] : []) {
                NotebookPageImage(page: page, meetingID: meetingID, library: library, maxPixels: 2048)
                    .frame(width: page.width * fit * level, height: page.height * fit * level)
                    .clipShape(DaybookRadius.shape(DaybookRadius.row))
                    .overlay(DaybookRadius.shape(DaybookRadius.row).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    .padding(24)
                    .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
            }
            .scrollIndicators(level > 1 ? .automatic : .hidden)
            .gesture(MagnifyGesture().updating($pinch) { value, state, _ in state = value.magnification }
                .onEnded { value in zoom = min(4, max(1, zoom * value.magnification)) })
            .onTapGesture(count: 2) { withAnimation(DaybookMotion.hover) { zoom = zoom > 1 ? 1 : 2 } }
            .accessibilityLabel(NotebookPagesWords.label(index + 1, leftOut: page.hiddenFromSummary == true))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DaybookPalette.quietFill)
    }

    private func words(_ page: NotebookPage, meeting: Meeting) -> some View {
        List {
            if page.passages.isEmpty {
                Text(page.needsReading ? "Reading" : "No words")
                    .foregroundStyle(DaybookPalette.Ink.secondary)
                    .listRowBackground(Color.clear)
            }
            ForEach(page.passages) { passage in
                HStack(alignment: .firstTextBaseline, spacing: DaybookSpacing.s3) {
                    time(passage, page: page, meeting: meeting)
                    Text(page.words(of: passage).flatMap { $0.isEmpty ? nil : $0 } ?? (passage.kind == .sketch ? "Sketch" : "No words"))
                        .foregroundStyle(passage.kind == .sketch || page.words(of: passage)?.isEmpty != false
                                         ? DaybookPalette.Ink.secondary : DaybookPalette.Ink.title)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .safeAreaPadding(.top, DaybookSpacing.s4)
        .accessibilityLabel("Words")
    }

    @ViewBuilder private func time(_ passage: NotebookPassage, page: NotebookPage, meeting: Meeting) -> some View {
        if let label = NotebookPagesWords.time(passage) {
            if canPlay, let target = meeting.playbackTarget(of: passage, on: page) {
                Button { play(target) } label: {
                    Label { Text(label) } icon: { Image(systemName: "play.fill").foregroundStyle(DaybookPalette.accent) }
                        .font(.footnote.monospacedDigit())
                }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Play from \(label)")
            } else {
                Text(label).font(.footnote.monospacedDigit()).foregroundStyle(DaybookPalette.Ink.secondary)
            }
        }
    }

    private func footer(_ page: NotebookPage) -> some View {
        let leftOut = page.hiddenFromSummary == true
        return HStack(spacing: DaybookSpacing.s3) {
            Button("Previous Page", systemImage: "chevron.left") { move(-1) }
                .labelStyle(.iconOnly)
                .disabled(index == 0)
                .keyboardShortcut(.leftArrow, modifiers: [])
            Text(NotebookPagesWords.position(index + 1, of: pages.count))
                .font(.callout.monospacedDigit())
                .foregroundStyle(DaybookPalette.Ink.secondary)
            Button("Next Page", systemImage: "chevron.right") { move(1) }
                .labelStyle(.iconOnly)
                .disabled(index >= pages.count - 1)
                .keyboardShortcut(.rightArrow, modifiers: [])
            Spacer()
            Button("Zoom Out", systemImage: "minus.magnifyingglass") { zoom = max(1, zoom / 1.5) }
                .labelStyle(.iconOnly)
                .keyboardShortcut("-", modifiers: .command)
                .disabled(zoom <= 1)
            Button("Zoom In", systemImage: "plus.magnifyingglass") { zoom = min(4, zoom * 1.5) }
                .labelStyle(.iconOnly)
                .keyboardShortcut("=", modifiers: .command)
                .disabled(zoom >= 4)
            Button(NotebookPagesWords.summaryChoice(leftOut: leftOut)) {
                library.setPageHiddenFromSummary(page.id, hidden: !leftOut, in: meetingID)
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .buttonStyle(.bordered)
        .padding(DaybookSpacing.s4)
    }

    private func move(_ step: Int) {
        let target = index + step
        guard pages.indices.contains(target) else { return }
        current = pages[target].id
        zoom = 1
    }
}
#endif
