import Foundation
import XCTest

/// The apps name the design as DaybookDesign and DaybookUI do (`DaybookPalette`, `DaybookSpacing`, `DaybookMotion`,
/// `DaybookFont`, `ReadingGeometry`), so a view moves between an app and DaybookUI without renaming a token. The
/// apps' own names for them (the Mac's DaybookStyle, TypeStyle, Space, Motion, and Ink; the iPhone's PhoneStyle) were
/// aliases, and one drifted: the iPhone's brand gradient ran the progress direction where the mark runs corner to
/// corner. So did typealiases that let a file skip importing a shared library, some under another name
/// (`CaptionRows` for `SavedCaptionsView`). These read the apps' sources and fail on either coming back.
final class TokenVocabularyTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The Mac, the iPhone, its widgets and Live Activity, the code both compile, and the iPhone's tests.
    private static let appFolders = ["Sources/Daybook", "Apps/iOS"]

    /// The shared libraries, by the module names a typealias would qualify a type with.
    private static let sharedModules = ["DaybookCaptions", "DaybookCore", "DaybookDesign", "DaybookDevices", "DaybookIntelligence",
                                        "DaybookKit", "DaybookLink", "DaybookLive", "DaybookModelStore", "DaybookUI"]

    /// The apps' old names for the tokens, and their modifiers' (`neonGlow` for `daybookGlow`, `motion` for
    /// `daybookMotion`). `DaybookPalette.Ink.body` is the shared name; a bare `Ink.body` is the alias.
    static let aliasUse = try! NSRegularExpression(
        pattern: #"\b(?:DaybookStyle|PhoneStyle|TypeStyle)\.|(?<![\w.])(?:Space|Motion|Ink|Typeface)\.|\.(?:neonGlow|motion)\("#)

    /// A typealias: its access, its name, and the type it names.
    static let typealiasDeclaration = try! NSRegularExpression(
        pattern: #"^[ \t]*((?:(?:public|internal|fileprivate|private)[ \t]+)?)typealias[ \t]+(\w+)(?:<[^>\n]*>)?[ \t]*=[ \t]*([A-Za-z_][\w.]*)"#,
        options: [.anchorsMatchLines])

    /// Text with its line comments and string literals blanked, so prose ("Reduce Motion.") isn't read as code.
    static func code(_ text: String) -> String {
        let comment = try! NSRegularExpression(pattern: #"//[^\n]*"#)
        let string = try! NSRegularExpression(pattern: #""(?:[^"\\\n]|\\.)*""#)
        var code = text
        for regex in [string, comment] {
            code = regex.stringByReplacingMatches(in: code, range: NSRange(code.startIndex..., in: code), withTemplate: "")
        }
        return code
    }

    /// The aliases written in `text`, as the text that matched.
    static func aliases(in text: String) -> [String] {
        let code = code(text)
        return aliasUse.matches(in: code, range: NSRange(code.startIndex..., in: code)).compactMap {
            Range($0.range, in: code).map { String(code[$0]) }
        }
    }

    /// The typealiases in `text` that give a shared type a second name: one qualified with a shared library's module
    /// (`DaybookUI.SheetDismiss`), or naming a type DaybookDesign or DaybookUI declares (`DaybookSpacing`,
    /// `DaybookPalette.Ink`). A private one is the file's own shorthand, which no other file reads, so it's allowed.
    static func sharedTypealiases(in text: String, sharedTypes: Set<String>) -> [String] {
        let code = code(text)
        return typealiasDeclaration.matches(in: code, range: NSRange(code.startIndex..., in: code)).compactMap { match in
            guard let access = Range(match.range(at: 1), in: code).map({ String(code[$0]) }),
                  let name = Range(match.range(at: 2), in: code).map({ String(code[$0]) }),
                  let target = Range(match.range(at: 3), in: code).map({ String(code[$0]) }) else { return nil }
            guard !access.contains("private") else { return nil }
            let head = String(target.prefix { $0 != "." })
            return sharedModules.contains(head) || sharedTypes.contains(head) ? "\(name) = \(target)" : nil
        }
    }

    private func swiftFiles(_ path: String) -> [URL] {
        let folder = Self.root.appendingPathComponent(path)
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return [] }
        var files: [URL] = []
        for case let url as URL in walker {
            // Generated projects and their packages' checkouts aren't ours.
            if url.lastPathComponent == "build" || url.pathExtension == "xcodeproj" { walker.skipDescendants(); continue }
            if url.pathExtension == "swift" { files.append(url) }
        }
        return files
    }

    /// The public types DaybookDesign and DaybookUI declare.
    private func sharedTypes() throws -> Set<String> {
        let regex = try NSRegularExpression(pattern: #"^public (?:final )?(?:struct|enum|class|protocol|actor|typealias) ([A-Za-z_][A-Za-z0-9_]*)"#,
                                            options: [.anchorsMatchLines])
        var names: Set<String> = []
        for folder in ["Sources/DaybookDesign", "Sources/DaybookUI"] {
            for file in swiftFiles(folder) {
                let text = try String(contentsOf: file, encoding: .utf8)
                for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    if let name = Range(match.range(at: 1), in: text).map({ String(text[$0]) }) { names.insert(name) }
                }
            }
        }
        return names
    }

    private func relative(_ url: URL) -> String { String(url.path.dropFirst(Self.root.path.count + 1)) }

    func testTheReaderFindsTheAliasesAndPassesTheSharedNames() {
        XCTAssertEqual(Self.aliases(in: ".foregroundStyle(DaybookStyle.accent)").count, 1)
        XCTAssertEqual(Self.aliases(in: ".padding(PhoneStyle.Space.s4)").count, 1)
        XCTAssertEqual(Self.aliases(in: ".font(TypeStyle.status)").count, 1)
        XCTAssertEqual(Self.aliases(in: "VStack(spacing: Space.s2) { }").count, 1)
        XCTAssertEqual(Self.aliases(in: "withAnimation(Motion.state) { }").count, 1)
        XCTAssertEqual(Self.aliases(in: ".foregroundStyle(Ink.secondary)").count, 1)
        XCTAssertEqual(Self.aliases(in: ".font(Typeface.title(.headline))").count, 1)
        XCTAssertEqual(Self.aliases(in: ".motion(DaybookMotion.hover, value: hovering)").count, 1)
        XCTAssertEqual(Self.aliases(in: ".neonGlow(color, radius: 3)").count, 1)

        XCTAssertEqual(Self.aliases(in: ".foregroundStyle(DaybookPalette.Ink.secondary)"), [])
        XCTAssertEqual(Self.aliases(in: "VStack(spacing: DaybookSpacing.s2) { }.daybookMotion(DaybookMotion.state, value: x)"), [])
        XCTAssertEqual(Self.aliases(in: ".daybookGlow(color, radius: 3).font(DaybookFont.status.font(.window))"), [])
        XCTAssertEqual(Self.aliases(in: "let color = NSColorSpace.sRGB"), [])
        // Prose in comments and strings is not code.
        XCTAssertEqual(Self.aliases(in: "// A curve becomes a fade under Reduce Motion.\nText(\"Low Space.\")"), [])

        let shared: Set<String> = ["DaybookSpacing", "DaybookPalette", "LevelTrail"]
        XCTAssertEqual(Self.sharedTypealiases(in: "typealias Space = DaybookSpacing", sharedTypes: shared), ["Space = DaybookSpacing"])
        XCTAssertEqual(Self.sharedTypealiases(in: "    typealias Ink = DaybookPalette.Ink", sharedTypes: shared), ["Ink = DaybookPalette.Ink"])
        XCTAssertEqual(Self.sharedTypealiases(in: "typealias LevelHistory = DaybookDesign.LevelTrail", sharedTypes: shared).count, 1)
        XCTAssertEqual(Self.sharedTypealiases(in: "typealias ProblemLine<Actions: View> = DaybookDesign.ProblemLine<Actions>",
                                              sharedTypes: shared).count, 1)
        XCTAssertEqual(Self.sharedTypealiases(in: "typealias TimeLabel = DaybookKit.TimeLabel", sharedTypes: shared).count, 1)
        XCTAssertEqual(Self.sharedTypealiases(in: "private typealias Shade = DaybookPalette.Shade", sharedTypes: shared), [])
        XCTAssertEqual(Self.sharedTypealiases(in: "typealias Mode = ProcessingRequest.Mode", sharedTypes: shared), [])
        XCTAssertEqual(Self.sharedTypealiases(in: "typealias Handler = @Sendable (Int) -> Void", sharedTypes: shared), [])
    }

    func testTheAppsWriteTheSharedTokenNames() throws {
        var found: [String] = []
        var read = 0
        for folder in Self.appFolders {
            for file in swiftFiles(folder) {
                read += 1
                let text = try String(contentsOf: file, encoding: .utf8)
                found += Self.aliases(in: text).map { "\(relative(file)): \($0)" }
            }
        }
        XCTAssertGreaterThan(read, 100, "The reader finds the apps' sources")
        XCTAssertEqual(found, [], "Write DaybookPalette, DaybookSpacing, DaybookMotion, DaybookFont, daybookGlow, and daybookMotion")
    }

    func testNoAppGivesASharedTypeASecondName() throws {
        let shared = try sharedTypes()
        XCTAssertTrue(shared.isSuperset(of: ["DaybookPalette", "DaybookSpacing", "SavedCaptionsView", "ReadingGeometry"]),
                      "The reader finds the libraries' types")
        var found: [String] = []
        for folder in Self.appFolders {
            for file in swiftFiles(folder) {
                let text = try String(contentsOf: file, encoding: .utf8)
                found += Self.sharedTypealiases(in: text, sharedTypes: shared).map { "\(relative(file)): \($0)" }
            }
        }
        XCTAssertEqual(found, [], "Import the shared library and write the type's own name")
    }
}
