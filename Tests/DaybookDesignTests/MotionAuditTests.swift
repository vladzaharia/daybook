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

    private static let curveNames = "easeOut|easeIn|easeInOut|linear|snappy|smooth|bouncy|spring|interactiveSpring|timingCurve|default"

    /// Where an animation is chosen: the calls whose arguments are read for curves.
    static let animationCall = try! NSRegularExpression(
        pattern: #"(?:\.animation|\bwithAnimation|\.motion|\.daybookMotion|\bDaybookMotion\.resolved)\("#)
    /// A curve by its implicit member, anywhere in those arguments: first, after `nil :`, or in either
    /// arm of a ternary. A token's member (`Motion.hover`, `DaybookMotion.state`) isn't one.
    static let implicitCurve = try! NSRegularExpression(pattern: #"(?<![\w.])\.(?:"# + curveNames + #")\b"#)
    /// A curve named on its type, wherever it's written.
    static let typedCurve = try! NSRegularExpression(pattern: #"\bAnimation\.(?:"# + curveNames + #")\b"#)
    /// No animation on purpose: allowed, as `nil` would be.
    static let noAnimation = try! NSRegularExpression(pattern: #"\.linear\(duration:\s*0(?:\.0+)?\)"#)

    /// The places that may name curves: DaybookDesign, where the tokens are.
    static func isAllowed(_ relativePath: String) -> Bool { relativePath.hasPrefix("Sources/DaybookDesign/") }

    /// The line (from 1) of each raw curve in `text`, once each however the calls nest.
    static func rawCurveLines(in text: String) -> [Int] {
        let source = text as NSString
        let whole = NSRange(location: 0, length: source.length)
        var offsets = Set<Int>()
        func collect(_ regex: NSRegularExpression, in range: NSRange) {
            for match in regex.matches(in: text, range: range) {
                let rest = NSRange(location: match.range.location, length: whole.length - match.range.location)
                guard noAnimation.firstMatch(in: text, options: .anchored, range: rest) == nil else { continue }
                offsets.insert(match.range.location)
            }
        }
        for call in animationCall.matches(in: text, range: whole) {
            let start = call.range.location + call.range.length
            collect(implicitCurve, in: NSRange(location: start, length: argumentsEnd(source, from: start) - start))
        }
        collect(typedCurve, in: whole)

        let newline = UInt16(UnicodeScalar("\n").value)
        var lines: [Int] = [], line = 1, index = 0
        for offset in offsets.sorted() {
            while index < offset {
                if source.character(at: index) == newline { line += 1 }
                index += 1
            }
            lines.append(line)
        }
        return lines
    }

    static func rawCurves(in text: String) -> Int { rawCurveLines(in: text).count }

    /// Where a call's arguments end: its matching `)`, from just past its `(`, or the end of the text.
    private static func argumentsEnd(_ source: NSString, from start: Int) -> Int {
        let open = UInt16(UnicodeScalar("(").value), close = UInt16(UnicodeScalar(")").value)
        var depth = 1, index = start
        while index < source.length {
            let unit = source.character(at: index)
            if unit == open { depth += 1 }
            if unit == close {
                depth -= 1
                if depth == 0 { break }
            }
            index += 1
        }
        return index
    }

    func testTheAuditFindsRawCurvesAndPassesTokens() {
        XCTAssertEqual(Self.rawCurves(in: ".animation(.easeOut(duration: 0.2), value: x)"), 1)
        XCTAssertEqual(Self.rawCurves(in: "withAnimation(.snappy(duration: 0.25)) { open = true }"), 1)
        XCTAssertEqual(Self.rawCurves(in: "withAnimation(.snappy) { }"), 1)
        XCTAssertEqual(Self.rawCurves(in: ".animation(.default, value: x)"), 1)
        // A Reduce Motion fallback, and a curve in either arm of a ternary.
        XCTAssertEqual(Self.rawCurves(in: ".animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: problem)"), 1)
        XCTAssertEqual(Self.rawCurves(in: "withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { open.toggle() }"), 1)
        XCTAssertEqual(Self.rawCurves(in: "withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.3)) { step = next }"), 2)
        XCTAssertEqual(Self.rawCurves(in: ".animation(hovering ? Motion.hover : .easeOut(duration: 0.2), value: hovering)"), 1)
        XCTAssertEqual(Self.rawCurves(in: ".animation(reduceMotion ? .easeOut(duration: 0.15) : Motion.page.delay(0.04), value: shown)"), 1)
        // A token's modifier given a curve of its own.
        XCTAssertEqual(Self.rawCurves(in: ".motion(.snappy(duration: 0.3), value: recorder.isPaused)"), 1)
        XCTAssertEqual(Self.rawCurves(in: ".daybookMotion(.easeOut(duration: 0.2), value: shown)"), 1)
        XCTAssertEqual(Self.rawCurves(in: "withAnimation(DaybookMotion.resolved(.snappy, reduceMotion: reduce)) { }"), 1)
        // Arguments over several lines, a curve inside a transition, and one named on its type.
        XCTAssertEqual(Self.rawCurveLines(in: "Text(x)\n    .animation(\n        reduceMotion ? nil : .easeOut(duration: 0.2),\n        value: x)"), [3])
        XCTAssertEqual(Self.rawCurves(in: ".transition(.move(edge: .bottom).animation(.spring(response: 0.3)))"), 1)
        XCTAssertEqual(Self.rawCurves(in: "let fade = Animation.easeOut(duration: 0.2)"), 1)

        XCTAssertEqual(Self.rawCurves(in: ".animation(DaybookMotion.hover, value: hovering)"), 0)
        XCTAssertEqual(Self.rawCurves(in: ".daybookMotion(DaybookMotion.state, value: status)"), 0)
        XCTAssertEqual(Self.rawCurves(in: "withAnimation(DaybookMotion.resolved(.state, reduceMotion: reduce)) { }"), 0)
        XCTAssertEqual(Self.rawCurves(in: ".animation(reduceMotion ? nil : PhoneStyle.Motion.state, value: detent)"), 0)
        XCTAssertEqual(Self.rawCurves(in: ".motion(isReady ? Motion.state : .linear(duration: 0), value: ids)"), 0)
        XCTAssertEqual(Self.rawCurves(in: ".animation(nil, value: x)"), 0)
        // Outside an animation call's arguments, `.linear` is something else.
        XCTAssertEqual(Self.rawCurves(in: "image.interpolation(.linear)"), 0)
        XCTAssertEqual(Self.rawCurves(in: "withAnimation(Motion.state) { scale = .linear }"), 0)

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
                for line in Self.rawCurveLines(in: try String(contentsOf: url, encoding: .utf8)) {
                    found.append("\(relative):\(line)")
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
