import Foundation
import XCTest

/// A type declared in an app shadows the shared library's type of the same name without a word from the
/// compiler, so a half-done move leaves call sites on the app's old copy (as the iPhone's own TimeLabel
/// once hid DaybookKit's). These read the sources and hold the shared names apart.
final class SharedNameTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// App types that still shadow a shared one, each until the screens that use it move to the library.
    /// Remove a name here once its app copy is gone; never add one.
    private static let movingOver: Set<String> = [
        // The Mac: the page's geometry (ConversationPage.swift) and Settings' problem line (SettingsView.swift).
        "MarginRow", "ProblemLine", "DetailsButton", "SettingsFooter",
        // The iPhone: the status sheet's cards (StatusSheet.swift).
        "StatusCard", "StatusCardMetrics", "StatusDivider", "StatusRow"
    ]

    private func swiftFiles(_ path: String) -> [URL] {
        let folder = Self.root.appendingPathComponent(path)
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// Top-level type names declared in a folder's sources. `publicOnly`: only the public ones.
    private func declaredTypes(in path: String, publicOnly: Bool) throws -> [String] {
        let pattern = publicOnly
            ? #"^public (?:final )?(?:struct|enum|class|protocol|actor|typealias) ([A-Za-z_][A-Za-z0-9_]*)"#
            : #"^(?:(?:private|fileprivate|internal|public|final|@MainActor) )*(?:struct|enum|class|protocol|actor|typealias) ([A-Za-z_][A-Za-z0-9_]*)(.*)$"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        var names: [String] = []
        for file in swiftFiles(path) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let name = Range(match.range(at: 1), in: text).map({ String(text[$0]) }) else { continue }
                // A typealias to the shared type itself is the shared type, by another route.
                if !publicOnly, let rest = Range(match.range(at: 2), in: text).map({ String(text[$0]) }),
                   rest.contains("= DaybookDesign.") || rest.contains("= DaybookUI.") { continue }
                names.append(name)
            }
        }
        return names
    }

    func testTheSharedLibrariesDeclareEachPublicNameOnce() throws {
        let design = try declaredTypes(in: "Sources/DaybookDesign", publicOnly: true)
        let ui = try declaredTypes(in: "Sources/DaybookUI", publicOnly: true)
        XCTAssertFalse(design.isEmpty)
        XCTAssertFalse(ui.isEmpty)
        let shared = design + ui
        let repeated = Dictionary(grouping: shared, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        XCTAssertEqual(repeated, [], "Declared twice across DaybookDesign and DaybookUI")
        var kit: [String] = []
        for module in ["DaybookKit", "DaybookCore", "DaybookDevices", "DaybookCaptions", "DaybookLink"] {
            kit += try declaredTypes(in: "Sources/\(module)", publicOnly: true)
        }
        XCTAssertEqual(Set(shared).intersection(kit).sorted(), [], "A shared view's name is also a model library's")
    }

    func testNoAppTypeShadowsASharedOneBeyondTheMovesInProgress() throws {
        let shared = Set(try declaredTypes(in: "Sources/DaybookDesign", publicOnly: true) + declaredTypes(in: "Sources/DaybookUI", publicOnly: true))
        var app: Set<String> = []
        for folder in ["Sources/Daybook", "Apps/iOS/DaybookPhone", "Apps/iOS/Shared", "Apps/iOS/DaybookPhoneWidgets"] {
            app.formUnion(try declaredTypes(in: folder, publicOnly: false))
        }
        let shadowing = app.intersection(shared)
        XCTAssertEqual(shadowing.subtracting(Self.movingOver).sorted(), [],
                       "An app declares a type the shared libraries export; use the shared one, or name a typealias to it")
        // A move that's done needs nothing more: its name can come off `movingOver` whenever.
    }
}
