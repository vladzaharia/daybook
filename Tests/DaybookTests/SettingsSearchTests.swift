import XCTest
@testable import Daybook

/// Settings' sidebar (docs/interface.md, "Settings"): every page once, in its groups, and the search finding a page by
/// its name or by what's on it.
final class SettingsSearchTests: XCTestCase {
    private func found(_ query: String) -> [SettingsPane] { SettingsPane.allCases.filter { $0.matches(query) } }

    func testTheSidebarHasEveryPageOnce() {
        XCTAssertEqual(SettingsPane.groups.flatMap { $0 }.sorted { $0.rawValue < $1.rawValue },
                       SettingsPane.allCases.sorted { $0.rawValue < $1.rawValue })
    }

    func testSearchFindsAPageByItsNameOrWhatsOnIt() {
        XCTAssertEqual(found(""), SettingsPane.allCases, "Nothing typed: every page")
        XCTAssertEqual(found("  "), SettingsPane.allCases)
        XCTAssertEqual(found("mod"), [.models])
        XCTAssertEqual(found("microphone"), [.recording])
        XCTAssertEqual(found("icloud"), [.library], "Case doesn't matter")
        XCTAssertEqual(found("gemma"), [.models], "A model's name finds Models")
        XCTAssertEqual(found("Anthropic"), [.cloud])
        XCTAssertEqual(found("Soundcore"), [.devices])
        XCTAssertEqual(found("captions"), [.recording])
        XCTAssertTrue(found("zebra").isEmpty)
    }

    /// What's on a page, or what its rows open, finds it (uxf-13): the library's own things on Library, where Models
    /// keeps them too beside their models.
    func testSearchFindsWhatEveryPageHolds() {
        XCTAssertEqual(found("Speaker Profiles"), [.library, .models])
        XCTAssertEqual(found("profiles"), [.library, .models])
        XCTAssertEqual(found("voiceprint"), [.library, .models])
        XCTAssertEqual(found("glossary"), [.library, .models])
        XCTAssertEqual(found("vocabulary"), [.library, .models])
        XCTAssertEqual(found("templates"), [.library, .models])
        XCTAssertEqual(found("recovery"), [.library])
        XCTAssertEqual(found("Recovery Key"), [.library])
        XCTAssertEqual(found("notifications"), [.recording])
        XCTAssertEqual(found("zoom"), [.recording])
        XCTAssertEqual(found("synced recordings"), [.models])
        XCTAssertEqual(found("login items"), [.general])
        XCTAssertEqual(found("countdown"), [.cloud])
    }

    /// What shipped since the first pass is findable too (SET-08), under the words the rows use.
    func testSearchFindsWhatShippedLater() {
        XCTAssertEqual(found("Number of Speakers"), [.models])
        XCTAssertEqual(found("Match Voices"), [.library, .models])
        XCTAssertEqual(found("Other Languages"), [.models])
        XCTAssertEqual(found("Balanced"), [.models])
        XCTAssertEqual(found("Not Filed"), [.cloud])
        XCTAssertEqual(found("Trash"), [.library])
        XCTAssertEqual(found("Backup"), [.library])
        XCTAssertEqual(found("This Is Me"), [.library, .models])
        XCTAssertEqual(found("Screen & System Audio Recording"), [.recording])
        XCTAssertEqual(found("Add Recorder"), [.devices])
    }

    func testPagesKeepTheNamesOtherPlacesOpenThemBy() {
        // Menus, pages, Floating Notes, and --open-settings name these; the window restores its page from them too.
        XCTAssertEqual(["general", "models", "cloud", "devices", "library"].compactMap(SettingsPane.init(rawValue:)).count, 5)
        XCTAssertEqual(SettingsPane(rawValue: "recording"), .recording)
    }
}
