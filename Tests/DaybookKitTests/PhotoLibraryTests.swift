import CoreGraphics
import DaybookCore
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import DaybookKit

@MainActor
final class PhotoLibraryTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoLibraryTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func jpeg(type: UTType = .jpeg, located: Bool = false) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        var exif: [CFString: Any] = [
            kCGImagePropertyExifDateTimeOriginal: "2026:10:24 14:03:12",
            kCGImagePropertyExifOffsetTimeOriginal: "+02:00",
            kCGImagePropertyExifSubsecTimeOriginal: "045"
        ]
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: 6]
        if located {
            exif[kCGImagePropertyExifLensModel] = "iPhone back camera 6.86mm f/1.78"
            exif[kCGImagePropertyExifUserComment] = "Dana’s kitchen"
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 37.3349, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 122.009, kCGImagePropertyGPSLongitudeRef: "W"
            ]
            properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 17 Pro",
                                                          kCGImagePropertyTIFFSoftware: "26.1"]
        }
        properties[kCGImagePropertyExifDictionary] = exif
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func properties(_ url: URL) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    func testImportPreservesOriginalMetadataAndRestoresAnExistingPhoto() async throws {
        let library = LibraryController(rootURL: root.appendingPathComponent("Library"), sync: nil)
        try await library.load()
        let id = library.newMeeting(title: "Planning")
        let bytes = try jpeg()
        await library.acquireLock()
        defer { library.releaseLock() }
        let photo = try await library.addPhoto(data: bytes, to: id, fileName: "../../outside.jpg")
        XCTAssertEqual(photo.pixelWidth, 40, "EXIF rotation is reflected in the displayed dimensions")
        XCTAssertEqual(photo.pixelHeight, 80)
        XCTAssertEqual(photo.capturedAtSource, .metadata)
        let expected = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-24T12:03:12Z"))
        XCTAssertEqual(photo.capturedAt.timeIntervalSince(expected), 0.045, accuracy: 0.001)
        let url = try await library.photoURL(for: photo, in: id)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        library.removePhoto(photo.id, in: id)
        let restored = try await library.addPhoto(data: bytes, to: id)
        XCTAssertEqual(restored.id, photo.id)
        XCTAssertFalse(restored.isRemoved)
        await library.flush()
        let reopened = LibraryController(rootURL: library.rootURL, sync: nil)
        try await reopened.load()
        XCTAssertEqual(reopened.meeting(id)?.visiblePhotos.map(\.id), [photo.id])
    }

    func testExportWritesPhotosAndKeepsExistingSiblingFolders() throws {
        let source = root.appendingPathComponent("original.jpg")
        let bytes = try jpeg()
        try bytes.write(to: source)
        let photo = MeetingPhoto(relativePath: "Originals/Photos/a.jpg", fileName: "a.jpg", sha256: "", capturedAt: Date(), caption: "Board [draft]")
        var meeting = Meeting(title: "Plan (draft)")
        meeting.photos = [photo]
        meeting.summary = MeetingSummary(overview: "Plan", sections: [.init(heading: "Decisions", body: "Use the board.", photoIDs: [photo.id])])
        let existing = root.appendingPathComponent("Plan (draft) Photos")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let unrelated = existing.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unrelated)
        let result = try MeetingExport.write(meeting, to: root, name: "Plan (draft)") { _ in source }
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "keep")
        let copied = try XCTUnwrap(result.photos).appendingPathComponent("Photo 01.jpg")
        XCTAssertEqual(PhotoMetadata.read(try Data(contentsOf: copied)), PhotoMetadata.read(bytes), "the same picture, taken at the same moment")
        let markdown = try String(contentsOf: result.markdown, encoding: .utf8)
        XCTAssertTrue(markdown.contains("![Board \\[draft\\]](Plan%20%28draft%29%20Photos"), markdown)
        XCTAssertTrue(markdown.contains("Photo%2001.jpg)"))
        XCTAssertThrowsError(try MeetingExport.write(meeting, to: root, name: "../escape") { _ in source })
    }

    /// A shared photo carries no location, camera, or maker metadata and no original file name; the
    /// library's original stays byte for byte.
    func testExportedPhotosLeaveLocationAndCameraDetailsBehind() throws {
        var formats = [(UTType.jpeg, "jpg"), (UTType.png, "png")]
        if (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(UTType.heic.identifier) { formats.append((.heic, "heic")) }
        for (type, ext) in formats {
            let folder = root.appendingPathComponent(ext)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let source = folder.appendingPathComponent("IMG_0412.\(ext)")
            let bytes = try jpeg(type: type, located: true)
            try bytes.write(to: source)
            XCTAssertNotNil(try properties(source)[kCGImagePropertyGPSDictionary], "the fixture has a location")
            let captioned = MeetingPhoto(relativePath: "Originals/Photos/a.\(ext)", fileName: "IMG_0412.\(ext)", sha256: "",
                                         capturedAt: Date(), caption: "Whiteboard")
            let plain = MeetingPhoto(relativePath: "Originals/Photos/b.\(ext)", fileName: "Passport scan.\(ext)", sha256: "", capturedAt: Date())
            var meeting = Meeting(title: "Plan")
            meeting.photos = [captioned, plain]

            let result = try MeetingExport.write(meeting, to: folder, name: "Plan") { _ in source }

            XCTAssertEqual(try Data(contentsOf: source), bytes, "the original is untouched")
            let exported = try XCTUnwrap(result.photos)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: exported.path).sorted(), ["Photo 01.\(ext)", "Photo 02.\(ext)"])
            let written = try properties(exported.appendingPathComponent("Photo 01.\(ext)"))
            XCTAssertNil(written[kCGImagePropertyGPSDictionary], ext)
            XCTAssertNil(written[kCGImagePropertyMakerAppleDictionary], ext)
            let tiff = written[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            XCTAssertNil(tiff[kCGImagePropertyTIFFMake], ext)
            XCTAssertNil(tiff[kCGImagePropertyTIFFModel], ext)
            XCTAssertNil(tiff[kCGImagePropertyTIFFSoftware], ext)
            let exif = written[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            XCTAssertNil(exif[kCGImagePropertyExifLensModel], ext)
            XCTAssertNil(exif[kCGImagePropertyExifUserComment], ext)
            XCTAssertEqual(written[kCGImagePropertyOrientation] as? Int, 6, "still upright")
            XCTAssertEqual(PhotoMetadata.read(exported.appendingPathComponent("Photo 01.\(ext)")).capturedAt,
                           PhotoMetadata.read(source).capturedAt, "still dated")
            let markdown = try String(contentsOf: result.markdown, encoding: .utf8)
            XCTAssertFalse(markdown.contains("IMG_0412"), markdown)
            XCTAssertFalse(markdown.contains("Passport"), markdown)
            XCTAssertTrue(markdown.contains("**Photo:** Photo 02") || markdown.contains("Photo 02 ·"), markdown)
        }
    }

    func testAPhotoThatIsNotAnImageIsLeftOutOfTheExport() throws {
        let source = root.appendingPathComponent("broken.jpg")
        try Data("not an image".utf8).write(to: source)
        var meeting = Meeting(title: "Plan")
        meeting.photos = [MeetingPhoto(relativePath: "Originals/Photos/a.jpg", fileName: "a.jpg", sha256: "", capturedAt: Date(), caption: "Board")]
        let result = try MeetingExport.write(meeting, to: root, name: "Plan") { _ in source }
        XCTAssertNil(result.photos)
        XCTAssertTrue(try String(contentsOf: result.markdown, encoding: .utf8).contains("Board"))
    }

    func testExportWithoutLocalPhotosKeepsCaptionsAndDoesNotLeaveAnEmptyFolder() throws {
        let photo = MeetingPhoto(relativePath: "Originals/Photos/a.jpg", fileName: "a.jpg", sha256: "", capturedAt: Date(), caption: "Whiteboard")
        var meeting = Meeting(title: "Plan")
        meeting.photos = [photo]
        let result = try MeetingExport.write(meeting, to: root, name: "Plan") { _ in nil }
        XCTAssertNil(result.photos)
        XCTAssertTrue(try String(contentsOf: result.markdown, encoding: .utf8).contains("Whiteboard"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Plan Photos").path))
    }

    func testInvalidTimeZoneOffsetsAreNotNormalizedIntoAnotherTime() {
        XCTAssertNil(PhotoMetadata.timeZone(offset: "+02:99"))
        XCTAssertNil(PhotoMetadata.timeZone(offset: "+24:00"))
        XCTAssertEqual(PhotoMetadata.timeZone(offset: "-0530")?.secondsFromGMT(), -19_800)
    }
}
