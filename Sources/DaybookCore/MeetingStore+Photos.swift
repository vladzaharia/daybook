import Foundation

/// The image formats Daybook keeps as photo originals, recognised by their bytes rather than a name.
public enum PhotoFormat: String, Sendable, CaseIterable {
    case heic, jpeg, png

    public var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    /// The uniform type identifier.
    public var contentType: String {
        switch self {
        case .heic: return "public.heic"
        case .jpeg: return "public.jpeg"
        case .png: return "public.png"
        }
    }

    /// The format of an image file's first bytes: JPEG and PNG signatures, or an ISO base media file
    /// whose brand is HEIF's (`heic`, `heix`, `mif1`, …). Nil for anything else.
    public static func detect(_ header: Data) -> PhotoFormat? {
        let bytes = [UInt8](header.prefix(16))
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF { return .jpeg }
        if bytes.count >= 8, bytes[0..<8] == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] { return .png }
        if bytes.count >= 12, String(decoding: bytes[4..<8], as: UTF8.self) == "ftyp" {
            let brand = String(decoding: bytes[8..<12], as: UTF8.self)
            if ["heic", "heix", "heim", "heis", "hevc", "hevx", "mif1", "msf1"].contains(brand) { return .heic }
        }
        return nil
    }

    public static func detect(fileURL: URL) -> PhotoFormat? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 16)).flatMap(detect)
    }
}

public enum PhotoStoreError: LocalizedError {
    case unsupportedImage(String)
    public var errorDescription: String? {
        switch self {
        case .unsupportedImage(let name): return "\(name) isn’t a HEIC, JPEG, or PNG image."
        }
    }
}

extension MeetingStore {
    /// Copies an image into a conversation's folder as an original (`Originals/Photos/<id>.<ext>`),
    /// hashing the copy. The source is never moved or changed. The same bytes already in the
    /// conversation return that photo instead of a second copy. The caller adds the returned photo
    /// to the conversation (`Meeting.addPhoto`) and saves it.
    public func storePhoto(from sourceURL: URL, in meeting: Meeting, id: UUID = UUID(), fileName: String? = nil,
                           capturedAt: Date, capturedAtSource: PhotoCaptureDateSource, trackID: UUID? = nil,
                           time: TimeInterval? = nil, origin: PhotoOrigin? = nil,
                           pixelSize: (width: Int, height: Int)? = nil) throws -> MeetingPhoto {
        let fm = FileManager.default
        let name = fileName ?? sourceURL.lastPathComponent
        let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) > 0, let format = PhotoFormat.detect(fileURL: sourceURL) else {
            throw PhotoStoreError.unsupportedImage(name)
        }
        if let time, !time.isFinite || time < 0 { throw LibraryError.invalidHighlight }
        let directory = try meetingDirectory(for: meeting.id)
        let folder = directory.appendingPathComponent(MeetingPhoto.folder, isDirectory: true)
        try LocalFiles.requireContained(folder, in: directory)
        try LocalFiles.directory(folder)
        let staged = folder.appendingPathComponent(".import-\(UUID().uuidString)")
        try fm.copyItem(at: sourceURL, to: staged)
        defer { try? fm.removeItem(at: staged) }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
        let digest = try AudioDigest.sha256(fileURL: staged)
        if let existing = (meeting.photos ?? []).first(where: { $0.sha256 == digest }),
           let url = try? LocalFiles.relativeURL(existing.relativePath, in: directory),
           fm.fileExists(atPath: url.path) {
            return existing
        }
        let relativePath = MeetingPhoto.relativePath(id: id, extension: format.fileExtension)
        let destination = try LocalFiles.relativeURL(relativePath, in: directory)
        guard !fm.fileExists(atPath: destination.path) else { throw LibraryError.unsafePath(relativePath) }
        try fm.moveItem(at: staged, to: destination)
        return MeetingPhoto(id: id, relativePath: relativePath, fileName: name, sha256: digest, contentType: format.contentType,
                            byteCount: values.fileSize, pixelWidth: pixelSize?.width, pixelHeight: pixelSize?.height,
                            capturedAt: capturedAt, capturedAtSource: capturedAtSource, trackID: trackID, time: time, origin: origin)
    }

    /// Where a photo's original is in the library.
    public func photoURL(for photo: MeetingPhoto, in meetingID: UUID) throws -> URL {
        try LocalFiles.relativeURL(photo.relativePath, in: try meetingDirectory(for: meetingID))
    }
}
