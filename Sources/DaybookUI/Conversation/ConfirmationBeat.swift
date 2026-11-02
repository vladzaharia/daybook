import DaybookDesign
import SwiftUI

/// A moment's word after something that leaves nothing else to see ("Copied"): a checkmark and the word in a small
/// capsule at the top of the page, for `DaybookMotion.hold`, then gone. VoiceOver hears the word.
public struct ConfirmationBeat: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let words: String

    public init(_ words: String) {
        id = UUID()
        self.words = words
    }

    /// Copy Summary's, on both apps.
    public static var copied: ConfirmationBeat { ConfirmationBeat("Copied") }
}

extension View {
    /// Shows `beat` over the top of this view while it's set, and clears it after `DaybookMotion.hold`. A new beat
    /// replaces the one showing and holds again.
    public func confirmationBeat(_ beat: Binding<ConfirmationBeat?>) -> some View {
        modifier(ConfirmationBeatOverlay(beat: beat))
    }
}

private struct ConfirmationBeatOverlay: ViewModifier {
    @Binding var beat: ConfirmationBeat?
    @Environment(\.daybookDensity) private var density
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let beat {
                    HStack(spacing: 6) {
                        DoneMark()
                        Text(beat.words)
                            .foregroundStyle(DaybookPalette.Ink.title)
                    }
                    .font(density == .touch ? .subheadline.weight(.semibold) : .system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, density == .touch ? 8 : 5)
                    .floatingGlass(in: Capsule(style: .circular))
                    .padding(.top, DaybookSpacing.s3)
                    .id(beat.id)
                    .daybookTransition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityElement(children: .combine)
                    .allowsHitTesting(false)
                }
            }
            .animation(DaybookMotion.resolved(DaybookMotion.fade, reduceMotion: reduceMotion), value: beat?.id)
            .task(id: beat?.id) {
                guard let shown = beat else { return }
                AccessibilityNotification.Announcement(shown.words).post()
                try? await Task.sleep(for: DaybookMotion.hold)
                guard !Task.isCancelled, beat?.id == shown.id else { return }
                beat = nil
            }
    }
}
