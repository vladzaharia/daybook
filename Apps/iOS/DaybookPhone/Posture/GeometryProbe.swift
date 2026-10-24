import SwiftUI
import UIKit

/// Debug only (`--log-geometry`): records the window's size, safe area, screen, and posture every
/// time they change, to Documents/geometry.jsonl and the console. This is how the iPhone Duo's
/// displays were measured for docs/iphone.md.
struct GeometryProbe: ViewModifier {
    let enabled: Bool
    let posture: DevicePosture

    func body(content: Content) -> some View {
        if enabled {
            content.background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { log(proxy) }
                        .onChange(of: proxy.size) { log(proxy) }
                        .onChange(of: proxy.safeAreaInsets) { log(proxy) }
                        .onChange(of: posture.summary) { log(proxy) }
                }
                .ignoresSafeArea()
            }
        } else {
            content
        }
    }

    private func log(_ proxy: GeometryProxy) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        let screen = scene?.screen
        let insets = window?.safeAreaInsets ?? .zero
        let record: [String: Any] = [
            "time": Date().timeIntervalSince1970,
            "posture": posture.summary,
            "hingeReports": posture.reports,
            "window": ["width": window?.bounds.width ?? proxy.size.width, "height": window?.bounds.height ?? proxy.size.height],
            "safeArea": ["top": insets.top, "left": insets.left, "bottom": insets.bottom, "right": insets.right],
            "screen": ["width": screen?.bounds.width ?? 0, "height": screen?.bounds.height ?? 0, "scale": screen?.scale ?? 0,
                       "nativeWidth": screen?.nativeBounds.width ?? 0, "nativeHeight": screen?.nativeBounds.height ?? 0],
            "orientation": scene.map { "\($0.effectiveGeometry.interfaceOrientation.rawValue)" } ?? "?",
            "sizeClass": window.map { $0.traitCollection.horizontalSizeClass == .regular ? "regular" : "compact" } ?? "?",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        print("GEOMETRY \(line)")
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("geometry.jsonl")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.close()
        } else {
            try? Data((line + "\n").utf8).write(to: url)
        }
    }
}
