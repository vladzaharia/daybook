import AppKit
import DaybookCore
import DaybookTestSupport
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Daybook

/// Copied conversation text stays on this Mac instead of reaching Universal Clipboard, and a copied
/// photo is a copy without its location or camera details, never the library's original.
final class LocalPasteboardTests: XCTestCase {
    private final class Recorder: LocalPasteboardWriting {
        var options: [NSPasteboard.ContentsOptions] = []
        var strings: [String] = []
        var written: [NSPasteboardWriting] = []
        var objects: Int { written.count }
        func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int { self.options.append(options); return 1 }
        func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool { strings.append(string); return true }
        func writeObjects(_ objects: [NSPasteboardWriting]) -> Bool { written += objects; return true }
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

    @MainActor
    func testCopyingAPhotoCopiesItWithoutItsLocationOrCamera() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookPhotoCopy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let copies = PhotoCopy.folder
        PhotoCopy.folder = root.appendingPathComponent("Copied", isDirectory: true)
        defer { PhotoCopy.folder = copies; try? FileManager.default.removeItem(at: root) }
        let state = AppState(libraryURL: root.appendingPathComponent("Library", isDirectory: true), defaults: makeTestDefaults())
        await state.initialize()
        let id = state.newMeeting(title: "Site visit")
        await state.library.acquireLock()
        let photo = try await state.library.addPhoto(data: try Self.locatedJPEG(), to: id, fileName: "IMG_0412.jpg")
        state.library.releaseLock()
        let original = state.photoURL(photo, in: id)
        let originalBytes = try Data(contentsOf: original)
        XCTAssertNotNil(try Self.properties(original)[kCGImagePropertyGPSDictionary], "the library keeps the original as it arrived")

        let recorder = Recorder()
        let copied = await state.copyPhoto(photo, in: id, to: recorder)

        let file = try XCTUnwrap(copied)
        XCTAssertEqual(recorder.options, [.currentHostOnly])
        XCTAssertEqual(recorder.written.compactMap { ($0 as? NSURL) as URL? }, [file], "the copy, not the library's original")
        XCTAssertNotEqual(file.standardizedFileURL, original.standardizedFileURL)
        XCTAssertEqual(file.lastPathComponent, "Photo 01.jpg")
        let written = try Self.properties(file)
        XCTAssertNil(written[kCGImagePropertyGPSDictionary])
        let tiff = written[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        XCTAssertNil(tiff[kCGImagePropertyTIFFMake])
        XCTAssertNil(tiff[kCGImagePropertyTIFFModel])
        XCTAssertNil((written[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifLensModel])
        XCTAssertEqual(try Data(contentsOf: original), originalBytes, "the original is untouched")

        // Copying again replaces the earlier copy rather than piling them up.
        let copiedAgain = await state.copyPhoto(photo, in: id, to: recorder)
        let again = try XCTUnwrap(copiedAgain)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: again.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: PhotoCopy.folder.path).count, 1)
    }

    /// A JPEG with a location, the camera, and its lens, as an iPhone writes them.
    private static func locatedJPEG() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:24 14:03:12",
                                             kCGImagePropertyExifLensModel: "iPhone back camera 6.86mm f/1.78"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.3349, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 122.009, kCGImagePropertyGPSLongitudeRef: "W"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 17 Pro"]
        ]
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private static func properties(_ url: URL) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }
}
