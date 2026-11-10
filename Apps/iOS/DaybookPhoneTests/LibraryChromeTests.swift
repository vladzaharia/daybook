import DaybookKit
import SwiftUI
import UIKit
import XCTest

@testable import DaybookPhone

/// The library's chrome (docs/iphone.md, "Scope" and "iPhone Duo"): the same bars on one page and two, what More
/// offers in each place, and, hosted the way the open Duo lays it out, a left page that keeps its navigation bar with
/// the place's menu (VI-01: a stack nested in the page's stack once hid it).
@MainActor
final class LibraryChromeTests: XCTestCase {
  func testBehaviorTheLibraryOffersItsPlacesMoreAndSettingsInEveryPlace() {
    XCTAssertEqual(LibraryChrome.topBar(selecting: false), [.titleMenu, .more, .settings])
    XCTAssertEqual(LibraryChrome.topBar(selecting: true), [], "selection has its own bar")
    XCTAssertEqual(
      LibraryChrome.more(in: .section(.all), isEmpty: false), [.select, .newFolder, .devices])
    XCTAssertEqual(
      LibraryChrome.more(in: .section(.all), isEmpty: true), [.newFolder, .devices],
      "no Select with nothing to select")
    XCTAssertEqual(LibraryChrome.more(in: .trash, isEmpty: false), [.newFolder, .devices])
    XCTAssertEqual(LibraryChrome.MoreItem.devices.title, "Devices")
    XCTAssertEqual(LibraryChrome.MoreItem.select.title, "Select Conversations")

    // The toolbar at the foot: Record, search, and New, everywhere but the Trash and selection.
    XCTAssertTrue(LibraryChrome.showsToolbar(in: .section(.work), selecting: false))
    XCTAssertFalse(LibraryChrome.showsToolbar(in: .section(.work), selecting: true))
    XCTAssertFalse(LibraryChrome.showsToolbar(in: .trash, selecting: false))
    XCTAssertTrue(LibraryChrome.offersSearch(in: .section(.all), selecting: false))
    XCTAssertFalse(LibraryChrome.offersSearch(in: .trash, selecting: false))
    XCTAssertFalse(
      LibraryChrome.offersSearch(in: .section(.all), selecting: true),
      "no search button under the selection's bar")
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
