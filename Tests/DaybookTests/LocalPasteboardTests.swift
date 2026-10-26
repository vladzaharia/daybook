import AppKit
import XCTest
@testable import Daybook

/// Copied conversation text stays on this Mac instead of reaching Universal Clipboard.
final class LocalPasteboardTests: XCTestCase {
    private final class Recorder: LocalPasteboardWriting {
        var options: [NSPasteboard.ContentsOptions] = []
        var strings: [String] = []
        var objects = 0
        func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int { self.options.append(options); return 1 }
        func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool { strings.append(string); return true }
        func writeObjects(_ objects: [NSPasteboardWriting]) -> Bool { self.objects += objects.count; return true }
    }

    func testCopiesAreForThisMacOnly() {
        let recorder = Recorder()
        LocalPasteboard.copy("We agreed on Friday.", to: recorder)
        LocalPasteboard.copy([URL(fileURLWithPath: "/tmp/Photo 01.heic") as NSURL], to: recorder)
        XCTAssertEqual(recorder.options, [.currentHostOnly, .currentHostOnly])
        XCTAssertEqual(recorder.strings, ["We agreed on Friday."])
        XCTAssertEqual(recorder.objects, 1)
    }

    func testTheTextArrivesOnAPasteboard() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        LocalPasteboard.copy("Ship it", to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "Ship it")
    }
}
