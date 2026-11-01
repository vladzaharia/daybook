import Foundation
import XCTest

/// A type declared in an app shadows the shared library's type of the same name without a word from the
/// compiler, so a half-done move leaves call sites on the app's old copy (as the iPhone's own TimeLabel
/// once hid DaybookKit's). So does a member an app adds in an extension: an environment value, a String
/// or View helper (as the iPhone's own `creaseEdge` once hid DaybookUI's, so the shared page read a key
/// nothing set). These read the sources and hold the shared names apart.
final class SharedNameTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Every app's sources: the Mac, the iPhone, and the iPhone's widgets.
    private static let appFolders = ["Sources/Daybook", "Apps/iOS/DaybookPhone", "Apps/iOS/Shared", "Apps/iOS/DaybookPhoneWidgets"]

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

    /// Members a folder's sources add in extensions, as "Type.member" (`EnvironmentValues.creaseEdge`,
    /// `String.keepingSeparators`). `publicOnly`: only the public ones. Reads members at the extension's
    /// first indent, which is how every file here writes them.
    private func extensionMembers(in path: String, publicOnly: Bool) throws -> [String] {
        let opener = try NSRegularExpression(pattern: #"^(public )?extension ([A-Za-z_][A-Za-z0-9_.]*)"#)
        let member = try NSRegularExpression(
            pattern: #"^    (?:@[A-Za-z_]+(?:\([^)]*\))? +)*((?:(?:public|internal|fileprivate|private|static|class|final|nonisolated|mutating|override) +)*)(?:var|let|func) +`?([A-Za-z_][A-Za-z0-9_]*)"#)
        var names: [String] = []
        for file in swiftFiles(path) {
            var extended: String?
            var publicByDefault = false
            for line in try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines) {
                let range = NSRange(line.startIndex..., in: line)
                if let match = opener.firstMatch(in: line, range: range) {
                    extended = Range(match.range(at: 2), in: line).map { String(line[$0]) }
                    publicByDefault = match.range(at: 1).location != NSNotFound
                    if line.hasSuffix("}") { extended = nil } // `extension Foo: Sendable {}`
                    continue
                }
                // Anything else at the margin (a closing brace, a type, a function) ends the extension.
                if let first = line.first, !first.isWhitespace, !"#/@".contains(first) {
                    extended = nil
                    continue
                }
                guard let type = extended, let match = member.firstMatch(in: line, range: range),
                      let name = Range(match.range(at: 2), in: line).map({ String(line[$0]) }) else { continue }
                let modifiers = Range(match.range(at: 1), in: line).map { String(line[$0]) } ?? ""
                if publicOnly && (modifiers.contains("private") || !(publicByDefault || modifiers.contains("public"))) { continue }
                names.append("\(type).\(name)")
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

        // Within a library a name can be overloaded (`.brand` and `.brand(width:)`); across the two it hides.
        let designMembers = Set(try extensionMembers(in: "Sources/DaybookDesign", publicOnly: true))
        let uiMembers = Set(try extensionMembers(in: "Sources/DaybookUI", publicOnly: true))
        XCTAssertEqual(designMembers.intersection(uiMembers).sorted(), [], "Added twice across DaybookDesign and DaybookUI")
    }

    func testNoAppTypeShadowsASharedOneBeyondTheMovesInProgress() throws {
        let shared = Set(try declaredTypes(in: "Sources/DaybookDesign", publicOnly: true) + declaredTypes(in: "Sources/DaybookUI", publicOnly: true))
        var app: Set<String> = []
        for folder in Self.appFolders {
            app.formUnion(try declaredTypes(in: folder, publicOnly: false))
        }
        let shadowing = app.intersection(shared)
        XCTAssertEqual(shadowing.subtracting(Self.movingOver).sorted(), [],
                       "An app declares a type the shared libraries export; use the shared one, or name a typealias to it")
        // A move that's done needs nothing more: its name can come off `movingOver` whenever.
    }

    func testNoAppMemberShadowsASharedOne() throws {
        let shared = Set(try extensionMembers(in: "Sources/DaybookDesign", publicOnly: true) + extensionMembers(in: "Sources/DaybookUI", publicOnly: true))
        // The reader finds what the libraries add: environment values, String and View helpers.
        for name in ["EnvironmentValues.creaseEdge", "EnvironmentValues.daybookDensity", "EnvironmentValues.readingScale",
                     "String.keepingSeparators", "String.wrappingAsName", "View.daybookFont", "View.daybookSurface"] {
            XCTAssertTrue(shared.contains(name), "\(name) is one of the libraries'")
        }
        var app: Set<String> = []
        for folder in Self.appFolders {
            app.formUnion(try extensionMembers(in: folder, publicOnly: false))
        }
        XCTAssertTrue(app.contains("EnvironmentValues.findQuery"), "The reader finds the apps' members too")
        XCTAssertEqual(app.intersection(shared).sorted(), [],
                       "An app adds a member the shared libraries already add to that type; use the shared one")
    }
}
