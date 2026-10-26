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

    private func jpeg() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:10:24 14:03:12",
                kCGImagePropertyExifOffsetTimeOriginal: "+02:00",
                kCGImagePropertyExifSubsecTimeOriginal: "045"
            ]
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
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

    func testExportCopiesOriginalsAndKeepsExistingSiblingFolders() throws {
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
        XCTAssertEqual(try Data(contentsOf: copied), bytes)
        let markdown = try String(contentsOf: result.markdown, encoding: .utf8)
        XCTAssertTrue(markdown.contains("![Board \\[draft\\]](Plan%20%28draft%29%20Photos"), markdown)
        XCTAssertTrue(markdown.contains("Photo%2001.jpg)"))
        XCTAssertThrowsError(try MeetingExport.write(meeting, to: root, name: "../escape") { _ in source })
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
