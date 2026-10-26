import AppKit
import DaybookCore
import DaybookDesign
import SwiftUI

// Floating Notes (docs/interface.md, "Floating Notes"): a floating version of the iPhone's main
// screen, on a non-activating panel that sits over someone else's full-screen call without taking
// focus from it. A status bar across the title band; while recording, the clock, You and Call
// meters, your notes with their times, live captions, and large Bookmark and Stop; afterwards,
// what's becoming of the recording; with nothing recording, a small home: status lines, Record and
// Import, and recent conversations. The views live in `FloatingNotes/`.

/// AppState's handle on the panel. There is one panel for the app, so every handle drives it.
@MainActor
final class NotesPanelController {
    /// Shows the panel on `meetingID`, or on its home when nil.
    func show(state: AppState, meetingID: UUID?) {
        FloatingNotesWindow.shared.show(state: state, focus: meetingID)
    }

    func close() { FloatingNotesWindow.shared.close() }
}

/// The panel itself: made once, kept for the life of the app, hidden rather than closed.
@MainActor
final class FloatingNotesWindow {
    static let shared = FloatingNotesWindow()

    private var panel: FloatingNotesPanel?
    private let chrome = PanelChrome()
    private var model: FloatingNotesModel?

    var isVisible: Bool { panel?.isVisible == true }

    /// - Parameters:
    ///   - focus: The conversation to show; nil shows the home (or the recording, while there is one).
    ///   - afterStop: Show `focus` as just stopped, as if the panel had watched it record.
    func show(state: AppState, focus: UUID?, afterStop: Bool = false) {
        let panel = self.panel ?? makePanel()
        if model?.state !== state || panel.contentViewController == nil {
            let model = FloatingNotesModel(state: state)
            self.model = model
            let hosting = NSHostingController(rootView: FloatingNotesRoot(model: model, state: state, chrome: chrome))
            // The person sizes the panel; SwiftUI must not shrink it to the content's minimum.
            hosting.sizingOptions = []
            let frame = panel.frame
            panel.contentViewController = hosting
            panel.setFrame(frame, display: false)
            chrome.track(hosting.view)
        }
        var watched = afterStop
        #if DEBUG
        // `--notes-after-stop` shows the post-Stop sheet, which a simulated recording can't reach.
        if CommandLine.arguments.contains("--notes-after-stop") { watched = true }
        #endif
        model?.focus(focus, afterStop: watched)
        // Appearing automatically must not take typing focus from the meeting app.
        panel.orderFrontRegardless()
        chrome.measure(panel)
        DispatchQueue.main.async { [chrome] in chrome.measure(panel) }
    }

    func close() { panel?.close() }

    private func makePanel() -> FloatingNotesPanel {
        let panel = Self.floatingPanel()
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isExcludedFromWindowsMenu = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.minSize = FloatingLayout.minimumSize
        panel.maxSize = FloatingLayout.maximumSize
        panel.animationBehavior = .utilityWindow
        panel.title = "Floating Notes"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        // Paper behind everything, so a live resize never flashes window grey.
        panel.backgroundColor = NSColor(DaybookPalette.paper)
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        // Close stays in the accessibility tree and fades in only while the pointer is over the panel.
        panel.standardWindowButton(.closeButton)?.alphaValue = 0
        chrome.closeButton = panel.standardWindowButton(.closeButton)
        chrome.panel = panel
        self.panel = panel
        if !panel.setFrameUsingName("FloatingNotes") { place(panel) }
        panel.setFrameAutosaveName("FloatingNotes")
        #if DEBUG
        if let size = FloatingNotesDemo.size {
            panel.setFrame(NSRect(origin: panel.frame.origin, size: size), display: false)
        }
        // Increase Contrast can't be turned on for one app, so the shared tokens draw their
        // contrast values (and SwiftUI's contrast is set on the root view).
        if FloatingNotesDemo.increasedContrast { DaybookShade.simulatesIncreasedContrast = true }
        #endif
        return panel
    }

    /// The window itself: a floating, non-activating panel on every Space and over full-screen apps.
    static func floatingPanel() -> FloatingNotesPanel {
        // A full title bar, not `.utilityWindow`: its 28 pt band and standard close button hold the
        // status bar. No toolbar, so the window keeps the smaller corner radius.
        let panel = FloatingNotesPanel(contentRect: NSRect(origin: .zero, size: FloatingLayout.defaultSize),
                                       styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // It floats over calls with your notes and live captions: keep it out of screen shares and
        // screenshots (docs/validation.md has the per-app check).
        panel.sharingType = .none
        return panel
    }

    /// First appearance: top-trailing of the screen under the pointer, inset 20 pt.
    private func place(_ panel: NSPanel) {
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = NSSize(width: min(FloatingLayout.defaultSize.width, frame.width - 40), height: min(FloatingLayout.defaultSize.height, frame.height - 40))
        panel.setFrame(NSRect(x: frame.maxX - size.width - 20, y: frame.maxY - size.height - 20, width: size.width, height: size.height), display: true)
    }
}

final class FloatingNotesPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The panel's sizes and the grid its content keeps, in points.
enum FloatingLayout {
    static let defaultSize = NSSize(width: 360, height: 560)
    static let minimumSize = NSSize(width: 280, height: 196)
    static let maximumSize = NSSize(width: 640, height: 1000)
    /// Below this height (the whole window), the panel is compact: the status bar, one caption
    /// line, and the controls.
    static let compactBelow: CGFloat = 380
    /// The height the Compact button snaps to.
    static let compactHeight: CGFloat = 212

    /// Every left and right edge of content.
    static let inset: CGFloat = 16
    /// Times, caption sources, and the bookmark glyph are right-aligned here; text starts at `textLeading`.
    static let laneTrailing: CGFloat = 44
    static let laneGap: CGFloat = 8
    static var textLeading: CGFloat { laneTrailing + laneGap }
    static let timeSize: CGFloat = 11
}

/// What the sheet needs from the window around it. SwiftUI's own hover tracking isn't reliable in a
/// non-key panel of an inactive app, which is this panel's normal state during a call.
@MainActor
final class PanelChrome: NSResponder, ObservableObject {
    @Published var isHovering = false
    /// The title-bar band's height: the status bar is centred in it.
    @Published var band: CGFloat = 28
    /// The close button's centre line, from the top of the window.
    @Published var buttonCenter: CGFloat = 14
    /// The close button's leading inset, which the Compact button's trailing inset mirrors.
    @Published var buttonInset: CGFloat = 8
    /// The close button's width, so the status bar starts clear of it.
    @Published var buttonWidth: CGFloat = 14
    weak var closeButton: NSButton?
    weak var panel: NSPanel?
    /// The height to return to from Compact.
    private var fullHeight: CGFloat?
    private var area: NSTrackingArea?

    override init() {
        super.init()
        #if DEBUG
        // `--notes-hover` shows the hover-only chrome in snapshots, which have no pointer.
        if CommandLine.arguments.contains("--notes-hover") { isHovering = true }
        #endif
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func track(_ view: NSView) {
        if let area { view.removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        view.addTrackingArea(area)
        self.area = area
    }

    func measure(_ panel: NSPanel) {
        let band = panel.frame.height - panel.contentLayoutRect.height
        if band > 0, band != self.band { self.band = band }
        if let button = panel.standardWindowButton(.closeButton) {
            let rect = button.convert(button.bounds, to: nil)
            let center = panel.frame.height - rect.midY, inset = rect.minX
            if center > 0, center != buttonCenter { buttonCenter = center }
            if inset > 0, inset != buttonInset { buttonInset = inset }
            if rect.width > 0, rect.width != buttonWidth { buttonWidth = rect.width }
        } else if band > 0 {
            buttonCenter = band / 2
        }
        if NSMouseInRect(NSEvent.mouseLocation, panel.frame, false) { setHovering(true) }
        closeButton?.alphaValue = isHovering ? 1 : 0
    }

    /// Compact snaps the panel to its compact height, keeping its top edge; Expand returns it to the
    /// height it had. The layout follows the size, so dragging the edge does the same.
    func setCompact(_ compact: Bool, animate: Bool) {
        guard let panel else { return }
        var frame = panel.frame
        let height: CGFloat
        if compact {
            fullHeight = frame.height
            height = FloatingLayout.compactHeight
        } else {
            height = max(FloatingLayout.compactBelow + 40, fullHeight ?? FloatingLayout.defaultSize.height)
        }
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: true, animate: animate)
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }

    private func setHovering(_ value: Bool) {
        #if DEBUG
        if CommandLine.arguments.contains("--notes-hover") { return }
        #endif
        guard value != isHovering else { return }
        isHovering = value
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            closeButton?.animator().alphaValue = value ? 1 : 0
        }
    }
}
