import AppKit
import DaybookCore
import DaybookKit
import DaybookTestSupport
import Foundation
import SwiftUI
import XCTest
@testable import Daybook

/// The inspector sits in a split view with the page. Moving between a conversation and a device
/// page keeps that split view's items, so an inspector animation still running (as at launch)
/// never finishes on an item that was taken out, which AppKit answers with an exception.
@MainActor
final class LibraryInspectorTests: XCTestCase {
    func testSwitchingPagesKeepsTheInspectorsSplitItems() async throws {
        let root = makeTemporaryFolder("DaybookInspector")
        let defaults = makeTestDefaults()
        let state = AppState(libraryURL: root, defaults: defaults)
        await state.initialize()
        defaults.set(true, forKey: "isInspectorPresented")
        let id = state.newMeeting(title: "Vendor walkthrough")
        state.selectedID = id

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 860), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingController(rootView: LibraryView(state: state).defaultAppStorage(defaults))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1400, height: 860))
        defer { window.close() }
        try await settle()
        let split = try XCTUnwrap(inspectorSplit(in: window.contentView), "The inspector's split view")
        let items = split.splitViewItems.map(ObjectIdentifier.init)

        // The page changes while the inspector collapses and expands again, as a device page opening at launch does.
        for place in [LibraryPlace.device("demo-phone"), .section(.all), .device("demo-phone"), .section(.all)] {
            state.place = place
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(split.splitViewItems.map(ObjectIdentifier.init), items, "Showing \(place) keeps the split view's items")
        }
        try await settle()
        XCTAssertEqual(split.splitViewItems.map(ObjectIdentifier.init), items)
        let inspector = try XCTUnwrap(split.splitViewItems.first { $0.behavior == .inspector })
        XCTAssertNotNil(inspector.viewController.view.superview, "The inspector is still in the window")
    }

    /// Lets SwiftUI update and its animations run.
    private func settle() async throws { try await Task.sleep(for: .milliseconds(600)) }

    /// The split view controller that holds the inspector, found through the window's views.
    private func inspectorSplit(in view: NSView?) -> NSSplitViewController? {
        guard let view else { return nil }
        if let split = (view as? NSSplitView)?.delegate as? NSSplitViewController,
           split.splitViewItems.contains(where: { $0.behavior == .inspector }) { return split }
        for subview in view.subviews { if let found = inspectorSplit(in: subview) { return found } }
        return nil
    }
}
