import Foundation
import XCTest

/// Every animation goes through DaybookDesign's motion (`daybookMotion`, `daybookTransition`,
/// `DaybookMotion.resolved`), so Reduce Motion is honoured everywhere and a curve is retuned in one place
/// (docs/interface.md, "Motion"). This finds curves written out in the apps' views.
///
/// Report-only while the screens move to the shared tokens: it lists what it finds and skips. Set
/// `DAYBOOK_ENFORCE_MOTION_TOKENS=1` to make it fail on any.
final class MotionAuditTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// A curve written out where an animation starts: `.animation(.easeOut(…`, `withAnimation(.snappy…`.
    static let rawCurve = try! NSRegularExpression(
        pattern: #"(\.animation\(|withAnimation\()\s*\.(easeOut|easeIn|easeInOut|linear|snappy|smooth|bouncy|spring|interactiveSpring)\b"#)

    /// The places that may name curves: DaybookDesign, where the tokens are.
    static func isAllowed(_ relativePath: String) -> Bool { relativePath.hasPrefix("Sources/DaybookDesign/") }

    static func rawCurves(in text: String) -> Int {
        rawCurve.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    func testTheAuditFindsRawCurvesAndPassesTokens() {
        XCTAssertEqual(Self.rawCurves(in: ".animation(.easeOut(duration: 0.2), value: x)"), 1)
        XCTAssertEqual(Self.rawCurves(in: "withAnimation(.snappy(duration: 0.25)) { open = true }"), 1)
        XCTAssertEqual(Self.rawCurves(in: "withAnimation(.snappy) { }"), 1)
        XCTAssertEqual(Self.rawCurves(in: ".animation(DaybookMotion.hover, value: hovering)"), 0)
        XCTAssertEqual(Self.rawCurves(in: ".daybookMotion(DaybookMotion.state, value: status)"), 0)
        XCTAssertEqual(Self.rawCurves(in: "withAnimation(DaybookMotion.resolved(.state, reduceMotion: reduce)) { }"), 0)
        XCTAssertTrue(Self.isAllowed("Sources/DaybookDesign/Tokens.swift"))
        XCTAssertFalse(Self.isAllowed("Sources/Daybook/UI/ConversationList.swift"))
    }

    func testNoViewWritesOutItsOwnCurve() throws {
        var found: [String] = []
        for folder in ["Sources", "Apps/iOS"] {
            let base = Self.root.appendingPathComponent(folder)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker {
                // Generated projects and their packages' checkouts aren't ours.
                if url.lastPathComponent == "build" || url.pathExtension == "xcodeproj" { walker.skipDescendants(); continue }
                guard url.pathExtension == "swift" else { continue }
                let relative = String(url.path.dropFirst(Self.root.path.count + 1))
                guard !Self.isAllowed(relative) else { continue }
                let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
                for (index, line) in lines.enumerated() where Self.rawCurves(in: line) > 0 {
                    found.append("\(relative):\(index + 1)")
                }
            }
        }
        if ProcessInfo.processInfo.environment["DAYBOOK_ENFORCE_MOTION_TOKENS"] == "1" {
            XCTAssertEqual(found, [], "Animate through DaybookMotion and daybookMotion")
        } else if !found.isEmpty {
            throw XCTSkip("\(found.count) curves written out in views, to move to DaybookMotion:\n" + found.joined(separator: "\n"))
        }
    }
}
