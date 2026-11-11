import DaybookKit
import SwiftUI
import UIKit
import XCTest

@testable import DaybookPhone

/// The library's chrome (docs/iphone.md, "Scope" and "iPhone Duo"): the same bar on one page and two, what More
/// offers in each place, and, hosted the way the open Duo lays it out, a left page that keeps its navigation bar with
/// the place's menu while the standing sheet stands at its foot (VI-01: the status tray's stack, nested in the page's
/// stack, once hid it).
@MainActor
final class LibraryChromeTests: XCTestCase {
  /// The bar holds the place's menu, More, and Settings; Record, Import, and Search are the status sheet's, at the foot,
  /// so More holds New Note (the bottom toolbar's "+" did).
  func testBehaviorTheLibraryOffersItsPlacesMoreAndSettingsInEveryPlace() {
    XCTAssertEqual(LibraryChrome.topBar(selecting: false), [.titleMenu, .more, .settings])
    XCTAssertEqual(LibraryChrome.topBar(selecting: true), [], "selection has its own bar")
    XCTAssertEqual(
      LibraryChrome.more(in: .section(.all), isEmpty: false), [.newNote, .select, .newFolder, .devices])
    XCTAssertEqual(
      LibraryChrome.more(in: .section(.all), isEmpty: true), [.newNote, .newFolder, .devices],
      "no Select with nothing to select")
    XCTAssertEqual(
      LibraryChrome.more(in: .trash, isEmpty: false), [.newFolder, .devices], "nothing is written into the Trash")
    XCTAssertEqual(LibraryChrome.MoreItem.newNote.title, "New Note")
    XCTAssertEqual(LibraryChrome.MoreItem.devices.title, "Devices")
    XCTAssertEqual(LibraryChrome.MoreItem.select.title, "Select Conversations")
  }

  /// VI-01: on two pages the library's left page has its navigation bar, with the place's menu as its title.
  func testBehaviorOnTwoPagesTheLibrarysTitleMenuIsThere() async throws {
    let library = PhoneLibrary(rootURL: try temporaryDirectory("library"), installation: "INSTALL-1")
    let model = PhoneAppModel(
      recorder: RecorderRig().recorder, library: library, posture: DevicePosture(),
      options: DebugLaunch(arguments: [], environment: ["XCTestConfigurationFilePath": "1"]),
      environment: try .test(self))
    try await library.reload()
    _ = library.controller.newMeeting(title: "Design review")
    let session = ReadingSession()

    let browser = LibraryBrowser(style: .notebook)
      .environment(model)
      .environment(session)
      .environment(\.surfaceStyle, .notebook)
    let host = UIHostingController(rootView: browser)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    // The open Duo's inner display.
    window.frame = CGRect(x: 0, y: 0, width: 951, height: 669)
    window.rootViewController = host
    window.isHidden = false
    defer { window.isHidden = true }

    var bar: UINavigationController?
    for _ in 0..<40 where bar == nil {
      try await Task.sleep(for: .milliseconds(100))
      host.view.layoutIfNeeded()
      bar = Self.navigationControllers(in: host).first {
        $0.topViewController?.navigationItem.title == LibrarySection.all.rawValue
      }
    }
    let left = try XCTUnwrap(bar, "the left page's stack shows All Conversations")
    XCTAssertFalse(left.isNavigationBarHidden, "its bar is there, not hidden by a stack inside it")
    let item = try XCTUnwrap(left.topViewController?.navigationItem)
    XCTAssertFalse(
      (item.leftBarButtonItems ?? []).isEmpty && item.leadingItemGroups.isEmpty,
      "the places' menu leads the bar")
    XCTAssertLessThan(
      left.view.convert(left.view.bounds, to: window).width, 951,
      "it's the left page's, not the whole display's")
    XCTAssertNil(
      host.presentedViewController,
      "on two pages the status sheet stands at the left page's foot, never the system's sheet across the crease")
  }

  private static func navigationControllers(in root: UIViewController) -> [UINavigationController] {
    var found: [UINavigationController] = []
    var queue = [root]
    while let controller = queue.popLast() {
      if let navigation = controller as? UINavigationController { found.append(navigation) }
      queue += controller.children
      if let presented = controller.presentedViewController { queue.append(presented) }
    }
    return found
  }
}
