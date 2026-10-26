import DaybookCore
import Foundation

/// How a photo joins a conversation: when it was taken and, if a recording was running, where in it.
public struct PhotoTimingInput: Sendable, Equatable {
    /// The camera's moment. Nil reads the file's capture date, or uses the moment it's added.
    public var capturedAt: Date?
    /// Taken during a recording: seconds into it (`trackID`), or on the timeline's own clock (no `trackID`).
    public var trackID: UUID?
    public var time: TimeInterval?

    public init(capturedAt: Date? = nil, trackID: UUID? = nil, time: TimeInterval? = nil) {
        self.capturedAt = capturedAt; self.trackID = trackID; self.time = time
    }

    /// A photo from a file or the photo library: its own capture date decides.
    public static let fromFile = PhotoTimingInput()
}

extension LibraryController {
    /// Copies an image into a conversation as a photo, with the moment it was taken (the camera's,
    /// the file's capture date, or now) and where it falls in a recording that was running. The
    /// original isn't moved or changed; the same bytes already in the conversation return that photo
    /// (put back if it was deleted). Recorded in Version History. Callers hold the lock
    /// (`acquireLock()`), as for `ingest`, or use `importPhotos`.
    @discardableResult
    public func addPhoto(from url: URL, to id: UUID, timing: PhotoTimingInput = .fromFile, origin: PhotoOrigin? = nil,
                         fileName: String? = nil, now: Date = Date()) async throws -> MeetingPhoto {
        guard let meeting = meeting(id) else { throw DaybookError.libraryUnavailable }
        let metadata = await Task.detached { PhotoMetadata.read(url) }.value
        guard let width = metadata.pixelWidth, let height = metadata.pixelHeight, width > 0, height > 0 else {
            throw PhotoStoreError.unsupportedImage(fileName ?? url.lastPathComponent)
        }
        let capturedAt: Date, source: PhotoCaptureDateSource
        if let moment = timing.capturedAt { (capturedAt, source) = (moment, .camera) }
        else if let moment = metadata.capturedAt { (capturedAt, source) = (moment, .metadata) }
        else { (capturedAt, source) = (now, .added) }
        let store = try MeetingStore(rootURL: rootURL)
        let size = metadata.pixelWidth.flatMap { width in metadata.pixelHeight.map { (width, $0) } }
        let stored = try await store.storePhoto(from: url, in: meeting, fileName: fileName, capturedAt: capturedAt, capturedAtSource: source,
                                                trackID: timing.trackID, time: timing.time, origin: origin, pixelSize: size)
        update(id) { current in
            if let existing = current.photo(stored.id) {
                if existing.isRemoved { current.restorePhoto(existing.id) }
            } else {
                current.addPhoto(stored)
            }
        }
        return self.meeting(id)?.photo(stored.id) ?? stored
    }

    /// Image bytes (a paste, a camera capture, the photo library) as a photo. Written to a temporary
    /// file first, then stored like any other.
    @discardableResult
    public func addPhoto(data: Data, to id: UUID, fileName: String? = nil, timing: PhotoTimingInput = .fromFile,
                         origin: PhotoOrigin? = nil) async throws -> MeetingPhoto {
        guard let format = PhotoFormat.detect(data) else { throw PhotoStoreError.unsupportedImage(fileName ?? "The image") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Daybook Photos \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = fileName ?? "Photo.\(format.fileExtension)"
        // Provider-suggested names are display metadata, never paths for the temporary file.
        let url = folder.appendingPathComponent("original.\(format.fileExtension)")
        try await Task.detached { try data.write(to: url, options: .atomic) }.value
        return try await addPhoto(from: url, to: id, timing: timing, origin: origin, fileName: name)
    }

    /// Files dropped, pasted, or chosen: each image becomes a photo, in order. Takes the library's lock.
    /// Returns what was added and the files that weren't images it keeps.
    public func importPhotos(_ urls: [URL], into id: UUID, timing: PhotoTimingInput = .fromFile,
                             origin: PhotoOrigin? = nil) async -> (photos: [MeetingPhoto], failures: [String]) {
        await acquireLock()
        defer { releaseLock() }
        var added: [MeetingPhoto] = [], failures: [String] = []
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do { added.append(try await addPhoto(from: url, to: id, timing: timing, origin: origin)) }
            catch { failures.append(error.localizedDescription) }
        }
        return (added, failures)
    }

    /// Deletes a photo. Its file and record stay, so Undo and Version History can put it back.
    public func removePhoto(_ photoID: UUID, in id: UUID) {
        update(id) { $0.removePhoto(photoID) }
    }

    /// Puts a deleted photo back.
    public func restorePhoto(_ photoID: UUID, in id: UUID) {
        update(id) { $0.restorePhoto(photoID) }
    }

    public func setPhotoCaption(_ photoID: UUID, caption: String, in id: UUID) {
        update(id) { $0.setPhotoCaption(photoID, caption: caption) }
    }

    /// Remove from Summary, or let summaries use the photo again.
    public func setPhotoHiddenFromSummary(_ photoID: UUID, hidden: Bool, in id: UUID) {
        update(id) { $0.setPhotoHiddenFromSummary(photoID, hidden: hidden) }
    }

    /// Where a photo's original is in the library. On an iPhone it may not be there yet; the sync
    /// controller's `fetchPhoto` brings it.
    public func photoURL(for photo: MeetingPhoto, in id: UUID) async throws -> URL {
        try await MeetingStore(rootURL: rootURL).photoURL(for: photo, in: id)
    }

    /// Whether a photo's original is in this library now.
    public func hasLocalPhoto(_ photo: MeetingPhoto, in id: UUID) -> Bool {
        let url = rootURL.appendingPathComponent("Meetings/\(id.uuidString)/\(photo.relativePath)")
        return FileManager.default.fileExists(atPath: url.path)
    }
}
