import DaybookKit
import Foundation
import XCTest
@testable import DaybookUI

/// Settings › Models › Transcription › Language, one row on both apps (xdev-settings-08): Automatic first, then every
/// language a transcription model in the catalog covers, by name, the same list whatever the device runs.
@MainActor
final class TranscriptionLanguageSettingsTests: XCTestCase {
    private let english = Locale(identifier: "en_US")

    func testBehaviorTheLanguageRowSaysAutomaticThenEachLanguageByName() {
        XCTAssertEqual(SettingsWords.languageLabel, "Language")
        XCTAssertEqual(SettingsWords.titleCased(SettingsWords.languageLabel), "Language", "the iPhone's label is the same word")
        XCTAssertEqual(SettingsWords.languageName(nil), "Automatic")
        XCTAssertEqual(SettingsWords.languageName("de", locale: english), "German")

        let items = TranscriptionLanguageSettings.items(in: .builtIn, keeping: nil, locale: english)
        XCTAssertEqual(items.first, .init(id: "", title: "Automatic"))
        XCTAssertTrue(items.contains(.init(id: "de", title: "German")))
        XCTAssertTrue(items.contains(.init(id: "ja", title: "Japanese")), "Whisper's languages too, on an iPhone that can't run it")
        XCTAssertEqual(Set(items.map(\.id)).count, items.count, "each language once")
        XCTAssertEqual(items.count, TranscriptionLanguages.choices(in: .builtIn).count + 1)
    }

    /// A language another device chose that no model here covers (a newer catalog's) stays in the list, so the row shows
    /// the library's choice rather than an empty selection.
    func testBehaviorTheLibrarysChoiceStaysInTheListWhereNoModelHereCoversIt() {
        let items = TranscriptionLanguageSettings.items(in: .builtIn, keeping: "tlh", locale: english)
        XCTAssertEqual(items.last?.id, "tlh")
        XCTAssertEqual(items.filter { $0.id == "de" }.count, 1)
        XCTAssertEqual(TranscriptionLanguageSettings.items(in: .builtIn, keeping: "de-AT", locale: english).filter { $0.id == "de" }.count, 1,
                       "a regional code is its language, listed once")
    }
}
