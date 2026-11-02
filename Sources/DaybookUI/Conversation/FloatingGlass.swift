import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// The floating layer over a page (the player, a moment's confirmation) is the one place content's surroundings are
// glass (docs/interface.md, "Chrome is a frame").

/// Neighbouring glass blends as one: on iPhone, and on macOS 26.
struct FloatingGlassGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        #if os(iOS)
        GlassEffectContainer { content }
        #else
        if #available(macOS 26, *) { GlassEffectContainer { content } } else { content }
        #endif
    }
}

extension View {
    /// A floating surface: Liquid Glass, or on macOS 15 a material with a hairline and a shadow.
    @ViewBuilder
    func floatingGlass(in shape: some Shape) -> some View {
        #if os(iOS)
        glassEffect(.regular, in: shape)
        #else
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        }
        #endif
    }
}
