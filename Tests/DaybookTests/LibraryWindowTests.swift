import DaybookCore
import DaybookKit
import DaybookTestSupport
import SwiftUI
import XCTest
@testable import Daybook

/// The library window keeps the page readable as it narrows, never takes its own squeeze for the person's choice, and
/// reopens where the person left it while what they left is still there.
@MainActor
final class LibraryWindowTests: XCTestCase {
    func testBehaviorTheSidebarStepsAsideWhenNarrowAndComesBackWithRoomToSpare() {
        XCTAssertEqual(ColumnFit.cap(window: 1280, inspector: false, previous: .all), .all)
        XCTAssertEqual(ColumnFit.cap(window: 990, inspector: false, previous: .all), .doubleColumn)
        XCTAssertEqual(ColumnFit.cap(window: 1040, inspector: false, previous: .all), .doubleColumn, "the page would be under 560 pt")
        XCTAssertEqual(ColumnFit.cap(window: 1100, inspector: false, previous: .doubleColumn), .all)
        // With the inspector, the page keeps 560 pt beside the list: the sidebar goes below 1340 pt.
        XCTAssertEqual(ColumnFit.cap(window: 1400, inspector: true, previous: .all), .all)
        XCTAssertEqual(ColumnFit.cap(window: 1300, inspector: true, previous: .all), .doubleColumn)
        XCTAssertEqual(ColumnFit.cap(window: 1345, inspector: true, previous: .doubleColumn), .all,
                       "it comes back once there's room, 1100 pt being passed")
        XCTAssertEqual(ColumnFit.cap(window: 1090, inspector: true, previous: .doubleColumn), .doubleColumn)
    }

    func testBehaviorTheInspectorShowsOnlyWithRoomForThePageBesideIt() {
        XCTAssertEqual(ColumnFit.narrowestWithInspector, 1140, "the list, the inspector, and a 560 pt page")
        XCTAssertFalse(ColumnFit.inspectorFits(window: 735), "half a 13-inch screen")
        XCTAssertTrue(ColumnFit.inspectorFits(window: 1140))

        let screen = CGRect(x: 0, y: 0, width: 1470, height: 920)
        XCTAssertEqual(ColumnFit.widened(CGRect(x: 0, y: 0, width: 735, height: 900), to: 1140, on: screen),
                       CGRect(x: 0, y: 0, width: 1140, height: 900))
        XCTAssertEqual(ColumnFit.widened(CGRect(x: 735, y: 0, width: 735, height: 900), to: 1140, on: screen),
                       CGRect(x: 330, y: 0, width: 1140, height: 900), "the right half grows leftward, staying on its screen")
        XCTAssertNil(ColumnFit.widened(CGRect(x: 0, y: 0, width: 1280, height: 900), to: 1140, on: screen), "already wide enough")
    }

    /// On a screen narrower than the inspector needs (a 13-inch laptop at Larger Text, 1024 pt), a window as wide as the
    /// screen allows shows it beside a narrower page, rather than holding it back for good.
    func testBehaviorTheInspectorShowsOnANarrowScreenInAWindowAsWideAsTheScreen() {
        XCTAssertTrue(ColumnFit.inspectorFits(window: 1024, screen: 1024), "full width, or full screen")
        XCTAssertTrue(ColumnFit.inspectorFits(window: 1008, screen: 1024), "tiled to fill it, with a margin")
        XCTAssertFalse(ColumnFit.inspectorFits(window: 735, screen: 1024), "half of it: the window widens first")
        XCTAssertFalse(ColumnFit.inspectorFits(window: 1130, screen: 1470), "a wide screen keeps the page its 560 pt")
        XCTAssertTrue(ColumnFit.inspectorFits(window: 1140, screen: nil), "before the window is on a screen, the usual rule")
        XCTAssertEqual(ColumnFit.cap(window: 1024, inspector: true, previous: .all), .doubleColumn, "the sidebar still steps aside")
    }

    /// The toolbar, ⌃⌘I, Tags…, and the byline's people all widen a window that holds the inspector back, even when it
    /// was asked for already (opened in a wider window, or before a relaunch), so none of them does nothing.
    func testBehaviorAskingForTheInspectorWidensAWindowThatHoldsItBack() {
        XCTAssertTrue(ColumnFit.widensForInspector(asked: true, available: true, window: 735, screen: 1470))
        XCTAssertTrue(ColumnFit.widensForInspector(asked: true, available: true, window: 735, screen: 1024), "as far as the screen allows")
        XCTAssertFalse(ColumnFit.widensForInspector(asked: true, available: true, window: 1280, screen: 1470), "it shows already")
        XCTAssertFalse(ColumnFit.widensForInspector(asked: true, available: true, window: 1024, screen: 1024), "as wide as it goes")
        XCTAssertFalse(ColumnFit.widensForInspector(asked: false, available: true, window: 735, screen: 1470), "putting it away")
        XCTAssertFalse(ColumnFit.widensForInspector(asked: true, available: false, window: 735, screen: 1470), "a device's page has none")
    }

    func testBehaviorOnlyThePersonsOwnChangeOfColumnsIsKept() {
        XCTAssertEqual(ColumnFit.choice(from: .doubleColumn, to: .all, cap: .doubleColumn), .all, "showing the sidebar is a choice")
        XCTAssertEqual(ColumnFit.choice(from: .all, to: .doubleColumn, cap: .all), .doubleColumn, "hiding it with room to spare is too")
        XCTAssertNil(ColumnFit.choice(from: .all, to: .doubleColumn, cap: .doubleColumn), "in a cramped window it's AppKit's squeeze")
        XCTAssertNil(ColumnFit.choice(from: .all, to: .all, cap: .all))
        XCTAssertEqual(ColumnFit("doubleColumn"), .doubleColumn)
        XCTAssertEqual(ColumnFit("nonsense"), .all, "an unreadable choice shows every column")
        XCTAssertEqual(ColumnFit(NavigationSplitViewVisibility.detailOnly), .detailOnly)
        XCTAssertEqual(min(ColumnFit.all, .doubleColumn).visibility, .doubleColumn)
    }

    func testBehaviorTheWindowReopensWhereItWasWhileThatIsStillThere() {
        let folder = UUID()
        for place in [LibraryPlace.section(.work), .section(.personal), .section(.all), .folder(folder), .device("soundcore-1")] {
            XCTAssertEqual(LibraryRestoration.decode(LibraryRestoration.encode(place), folders: [folder], devices: ["soundcore-1"]), place)
        }
        XCTAssertNil(LibraryRestoration.decode(LibraryRestoration.encode(.folder(folder)), folders: [], devices: []), "a deleted folder")
        XCTAssertNil(LibraryRestoration.decode("device:gone", folders: [], devices: ["soundcore-1"]), "a removed recorder")
        XCTAssertNil(LibraryRestoration.decode("", folders: [], devices: []))
        XCTAssertNil(LibraryRestoration.decode("section:nowhere", folders: [], devices: []))

        let kept = Meeting(title: "Weekly product sync")
        XCTAssertEqual(LibraryRestoration.selection(kept.id.uuidString, in: [Meeting(title: "Other"), kept]), kept.id)
        XCTAssertNil(LibraryRestoration.selection(UUID().uuidString, in: [kept]), "gone: the place's first is chosen instead")
        XCTAssertNil(LibraryRestoration.selection("", in: [kept]))
    }

    func testBehaviorRecordSaysSavedOnlyForARecordingThatWasSaved() async throws {
        let state = AppState(libraryURL: makeTemporaryFolder("DaybookLibraryWindow"), defaults: makeTestDefaults("local.daybook.tests.library-window"))
        await state.initialize()
        XCTAssertFalse(RecordControl.savedWell(UUID(), state: state), "a conversation that isn't there wasn't saved")
        let saved = state.newMeeting(title: "Weekly product sync")
        state.update(saved) { $0.status = .transcribing }
        XCTAssertTrue(RecordControl.savedWell(saved, state: state))
        let failed = state.newMeeting(title: "Board prep")
        state.update(failed) { $0.status = .failed }
        XCTAssertFalse(RecordControl.savedWell(failed, state: state), "a recording that failed says so instead")
    }
}
