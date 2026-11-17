import DaybookCaptions
import DaybookDesign
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// The whole live transcript, opened from the live caption line on both apps: every line the recording's
// captions have so far (`LiveTranscriptModel`), in the saved captions' rows (`SavedCaptionRow`), following the
// newest words until the person scrolls up to read. Tentative like every live caption; never the transcript.

/// A live caption line that opens the live transcript: a button with a sheet under touch and a popover on the Mac.
/// Only while there are lines to open; before, and once the captions end, it's the strip alone, and the
/// transcript closes with it.
public struct LiveTranscriptLink<Content: View>: View {
    private let source: LiveTranscriptModel.Source
    private let isEnabled: Bool
    private let content: Content
    @State private var showing = false
    @Environment(\.daybookDensity) private var density

    /// - Parameters:
    ///   - source: Where the transcript reads its lines (`LiveCaptionSession.transcriptSource`, or a recorder's).
    ///   - isEnabled: Whether there is anything to open (`LiveTranscriptLink.opens`).
    public init(source: LiveTranscriptModel.Source, isEnabled: Bool, @ViewBuilder content: () -> Content) {
        self.source = source
        self.isEnabled = isEnabled
        self.content = content()
    }

    /// What VoiceOver says the line does, after what it reads.
    static var hint: String { "Shows the live transcript" }

    /// Under touch the transcript opens in a sheet, as the app's other sheets do; on the Mac in a popover attached to the line.
    static func usesSheet(_ density: DaybookDensity) -> Bool { density == .touch }

    /// Whether a caption line opens the transcript: captions are listening and have heard something.
    public static func opens(state: LiveCaptionState, lines: Int) -> Bool { state == .listening && lines > 0 }

    public var body: some View {
        if isEnabled {
            Button { showing = true } label: { content }
                .buttonStyle(.daybookCaptionLine)
                .accessibilityHint(Self.hint)
                .sheet(isPresented: Binding(get: { showing && Self.usesSheet(density) }, set: { showing = $0 })) {
                    LiveTranscriptSheet(source: source)
                }
                .popover(isPresented: Binding(get: { showing && !Self.usesSheet(density) }, set: { showing = $0 }), arrowEdge: .bottom) {
                    LiveTranscriptView(source: source)
                        .frame(width: 560, height: 520)
                }
                .onChange(of: isEnabled) { if !isEnabled { showing = false } }
        } else {
            content
        }
    }
}

/// The live transcript in a sheet under touch: a title and Close, medium and large like the app's other sheets.
struct LiveTranscriptSheet: View {
    let source: LiveTranscriptModel.Source
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LiveTranscriptView(source: source)
                .navigationTitle("Live Transcript")
                .touchInlineTitle()
                #if os(iOS)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(role: .close) { dismiss() }.tint(DaybookPalette.Ink.title) } }
                #endif
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // The line it opens from may cap its type size (the recorder's strip does); the transcript is for reading
        // and follows the person's own setting.
        .dynamicTypeSize(DynamicTypeSize(UIApplication.shared.preferredContentSizeCategory) ?? .large)
        #endif
    }
}

/// Every live line, oldest first, in a lazy list that follows the newest words. It reads only while it's
/// shown and holds nothing of the recording.
public struct LiveTranscriptView: View {
    private let source: LiveTranscriptModel.Source
    @State private var model: LiveTranscriptModel
    @State private var position = ScrollPosition(edge: .bottom)
    @Environment(\.daybookDensity) private var density
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameter model: One already made (a test's); else a new one, which reads `source` while this is shown.
    @MainActor
    public init(source: LiveTranscriptModel.Source, model: LiveTranscriptModel? = nil) {
        self.source = source
        _model = State(initialValue: model ?? LiveTranscriptModel())
    }

    /// What goes before a line's words: the person live speakers recognized, the device that heard it, You or
    /// Call, else the model's own label for the voice ("S2").
    static func name(_ segment: LiveCaptionSegment, names: [String: String]) -> String? {
        LiveCaptionLabels.speaker(segment, names: names) ?? LiveCaptionLabels.lane(segment) ?? segment.speaker?.slot
    }

    /// How a scroll reads, for the model: how far from the newest words, and the sizes that move it.
    private struct Reach: Equatable {
        var distance: CGFloat
        var content: CGSize
        var container: CGSize
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.lines) { segment in
                    SavedCaptionRow(segment: segment, name: Self.name(segment, names: model.names), isPlaying: false, play: nil)
                }
            }
            .padding(.horizontal, density == .touch ? DaybookSpacing.s4 : DaybookSpacing.s5)
            .padding(.vertical, DaybookSpacing.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .environment(\.readingWidth, density == .touch ? .narrow : .regular)
        .scrollPosition($position)
        .background(DaybookPalette.paper)
        .onScrollGeometryChange(for: Reach.self) { geometry in
            let farthest = geometry.contentSize.height + geometry.contentInsets.bottom - geometry.containerSize.height
            return Reach(distance: farthest - geometry.contentOffset.y, content: geometry.contentSize, container: geometry.containerSize)
        } action: { _, reach in
            model.scrolled(distanceFromLatest: reach.distance, content: reach.content, container: reach.container)
        }
        .overlay(alignment: .bottom) {
            if !model.isFollowing {
                Button { model.jumpToLatest() } label: { Label("Latest", systemImage: "arrow.down") }
                    .buttonStyle(.daybookTinted)
                    // Its wash is translucent: the words it floats over would show through.
                    .background(DaybookPalette.paper, in: Capsule())
                    .padding(.bottom, DaybookSpacing.s4)
                    .transition(.opacity)
            }
        }
        .daybookMotion(DaybookMotion.fade, value: model.isFollowing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live transcript")
        .task { await model.run(source) }
        .onChange(of: model.revision) { if model.isFollowing { position.scrollTo(edge: .bottom) } }
        .onChange(of: model.jumps) {
            withAnimation(DaybookMotion.scrollAnimation(reduceMotion: reduceMotion)) { position.scrollTo(edge: .bottom) }
        }
    }
}
