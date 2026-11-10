import Foundation
import XCTest

/// Siri's phrases and Shortcuts' titles for an action both apps have are one set, said the same on the Mac and the
/// iPhone. App Intents reads each app's `DaybookShortcuts` from its own target, as literals, so they can't share a
/// constant; this reads both sources and holds them together.
final class ShortcutPhrasesTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private struct Shortcut: Equatable {
        var phrases: [String]
        var shortTitle: String
        var symbol: String
    }

    /// Each `AppShortcut(intent: XIntent(), phrases: [...], shortTitle: "...", systemImageName: "...")`, by intent.
    private func shortcuts(in path: String) throws -> [String: Shortcut] {
        let text = try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
        let shortcut = try NSRegularExpression(
            pattern: #"AppShortcut\(intent: ([A-Za-z]+)\(\),\s*phrases: \[(.*?)\],\s*shortTitle: "([^"]*)", systemImageName: "([^"]*)"\)"#,
            options: [.dotMatchesLineSeparators])
        let literal = try NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
        var found: [String: Shortcut] = [:]
        for match in shortcut.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            func group(_ index: Int) -> String { Range(match.range(at: index), in: text).map { String(text[$0]) } ?? "" }
            let list = group(2)
            let phrases = literal.matches(in: list, range: NSRange(list.startIndex..., in: list)).compactMap {
                Range($0.range(at: 1), in: list).map { String(list[$0]) }
            }
            found[group(1)] = Shortcut(phrases: phrases, shortTitle: group(3), symbol: group(4))
        }
        return found
    }

    func testBehaviorAnActionBothAppsHaveIsSaidTheSameOnBoth() throws {
        let mac = try shortcuts(in: "Sources/Daybook/App/Intents/DaybookIntents.swift")
        let phone = try shortcuts(in: "Apps/iOS/DaybookPhone/App/DaybookShortcuts.swift")
        // The reader finds them: the four both apps have, and each app's own.
        let shared = Set(mac.keys).intersection(phone.keys)
        XCTAssertEqual(shared, ["StartRecordingIntent", "StopRecordingIntent", "AddBookmarkIntent", "NewNoteIntent"])
        XCTAssertEqual(Set(mac.keys).subtracting(shared), ["ShowFloatingNotesIntent"], "the Mac's own")
        XCTAssertEqual(Set(phone.keys).subtracting(shared), ["OpenConversationIntent"], "the iPhone's own")
        for intent in shared.sorted() {
            XCTAssertFalse(mac[intent]?.phrases.isEmpty ?? true, intent)
            XCTAssertEqual(mac[intent], phone[intent], "\(intent) is said differently on the Mac and the iPhone")
        }
    }
}
