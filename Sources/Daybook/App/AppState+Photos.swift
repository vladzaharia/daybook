import AppKit
import DaybookCore
import DaybookIntelligence
import DaybookKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Photos on the Mac (docs/architecture.md, "Photos"): adding them (files, drops, paste, Continuity
// Camera), deleting with Undo, and reading them (Apple Vision, or the chosen photo model) before a
// summary is written, or on their own when they arrive after it.

extension AppState {
    /// This Mac, as the device that added a photo.
    var photoOrigin: PhotoOrigin { PhotoOrigin(kind: PhotoOrigin.macKind, name: Host.current().localizedName) }

    /// The photo-caption model a job uses: the chosen one when it's on this Mac and isn't Apple Vision,
    /// which reads every photo anyway. Nil leaves captions to Vision.
    var photoModel: ModelReference? {
        guard let key = modelSelections[.imageDescription], key != PhotoReading.visionModel.id, installedModels.contains(key) else { return nil }
        return ModelReference(key, revision: installedRevisions[key])
    }

    /// Where a photo added now falls: while this Mac records the conversation, its moment in the
    /// recording (the capture clock is the timeline, as for bookmarks), unless the file says it was
    /// taken before the recording began; otherwise the file's own capture date decides.
    func photoTiming(for id: UUID, capturedAt fileDate: Date?, now: Date = Date()) -> PhotoTimingInput {
        guard recordingID == id, let started = recordingStartedAt else { return .fromFile }
        let moment = fileDate ?? now
        guard moment >= started.addingTimeInterval(-5), moment <= now.addingTimeInterval(5) else { return .fromFile }
        let elapsed = max(0, recorder.elapsedTime - now.timeIntervalSince(moment))
        return PhotoTimingInput(capturedAt: moment, time: elapsed)
    }

    /// Files dropped or chosen: each image becomes a photo of the conversation. Images in another
    /// format (TIFF, GIF) are kept as PNG; HEIC, JPEG, and PNG are kept as they are.
    func addPhotos(_ urls: [URL], to id: UUID) {
        guard library.isLoaded, !urls.isEmpty else { return }
        Task {
            var failures: [String] = []
            var added = 0
            await library.acquireLock()
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do {
                    let metadata = await Task.detached { PhotoMetadata.read(url) }.value
                    let timing = photoTiming(for: id, capturedAt: metadata.capturedAt)
                    if PhotoFormat.detect(fileURL: url) != nil {
                        try await library.addPhoto(from: url, to: id, timing: timing, origin: photoOrigin)
                    } else if let png = await Task.detached(operation: { Self.pngData(contentsOf: url) }).value {
                        try await library.addPhoto(data: png, to: id, fileName: url.deletingPathExtension().lastPathComponent + ".png",
                                                   timing: timing, origin: photoOrigin)
                    } else {
                        throw PhotoStoreError.unsupportedImage(url.lastPathComponent)
                    }
                    added += 1
                } catch { failures.append(error.localizedDescription) }
            }
            library.releaseLock()
            if let failure = failures.first { errorMessage = failures.count == 1 ? failure : "\(failures.count) files weren’t added. \(failure)" }
            if added > 0 { readPhotosWhenIdle(id) }
        }
    }

    /// Images from the pasteboard, a drop, or Continuity Camera ("Take Photo" on an iPhone).
    func addPhotos(_ providers: [NSItemProvider], to id: UUID) {
        guard library.isLoaded, !providers.isEmpty else { return }
        Task {
            var failures: [String] = []
            var added = 0
            for provider in providers {
                do {
                    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier), let url = try await Self.fileURL(from: provider) {
                        addPhotos([url], to: id)
                        continue
                    }
                    guard let data = try await Self.imageData(from: provider) else { continue }
                    let metadata = await Task.detached { PhotoMetadata.read(data) }.value
                    let timing = photoTiming(for: id, capturedAt: metadata.capturedAt)
                    // A capture from the iPhone's camera has no file date: the moment it arrived is its moment.
                    let moment = timing.capturedAt == nil && metadata.capturedAt == nil ? PhotoTimingInput(capturedAt: Date()) : timing
                    await library.acquireLock()
                    defer { library.releaseLock() }
                    try await library.addPhoto(data: data, to: id, fileName: provider.suggestedName.map { $0 + "." + (PhotoFormat.detect(data)?.fileExtension ?? "png") },
                                               timing: moment, origin: photoOrigin)
                    added += 1
                } catch { failures.append(error.localizedDescription) }
            }
            if let failure = failures.first { errorMessage = failure }
            if added > 0 { readPhotosWhenIdle(id) }
        }
    }

    /// Edit › Paste Photo: the pasteboard's image files, or its image (a screenshot, a copied photo).
    func pastePhoto(into id: UUID) {
        let pasteboard = NSPasteboard.general
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true,
                                                                               .urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL] ?? []
        if !files.isEmpty { addPhotos(files, to: id); return }
        for type in [UTType.heic, .jpeg, .png, .tiff] {
            guard let data = pasteboard.data(forType: NSPasteboard.PasteboardType(type.identifier)) else { continue }
            let provider = NSItemProvider(item: data as NSData, typeIdentifier: type.identifier)
            addPhotos([provider], to: id)
            return
        }
        notice = "There’s no image to paste."
    }

    /// Add Photo…: an open panel for images.
    func chooseAddPhoto(to id: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        addPhotos(panel.urls, to: id)
    }

    /// Deletes a photo; Undo (⌘Z) puts it back, and Version History keeps the change.
    func deletePhoto(_ photoID: UUID, in id: UUID, undoManager: UndoManager?) {
        library.removePhoto(photoID, in: id)
        undoManager?.registerUndo(withTarget: self) { state in
            state.library.restorePhoto(photoID, in: id)
            undoManager?.registerUndo(withTarget: state) { again in again.deletePhoto(photoID, in: id, undoManager: undoManager) }
        }
        undoManager?.setActionName("Delete Photo")
    }

    /// Where a photo's original is on this Mac.
    func photoURL(_ photo: MeetingPhoto, in id: UUID) -> URL {
        library.rootURL.appendingPathComponent("Meetings/\(id.uuidString)/\(photo.relativePath)")
    }

    /// Copy: the photo as an export writes it (named "Photo 03", without its location or camera
    /// details), for this Mac only. The library's original never reaches the pasteboard; Show in
    /// Finder still reveals it. Returns the copied file.
    @discardableResult
    func copyPhoto(_ photo: MeetingPhoto, in id: UUID, to pasteboard: some LocalPasteboardWriting = NSPasteboard.general) async -> URL? {
        guard let meeting = meetings.first(where: { $0.id == id }) else { return nil }
        let name = MeetingExport.photoNames(meeting)[photo.id] ?? "Photo"
        switch await PhotoCopy.copy(photoURL(photo, in: id), name: name, to: pasteboard) {
        case .copied(let file): return file
        case .unreadable: notice = "This photo couldn’t be copied."; return nil
        case .superseded: return nil
        }
    }

    // MARK: Reading photos

    /// Returns how many photos it read. A photo that couldn't be read waits before it's tried again
    /// (`photoBackoff`), and is left out until then; the others are read.
    @discardableResult
    func readPhotos(_ id: UUID, engine: any ProcessingEngine, progress: @escaping ProcessingProgressHandler) async throws -> Int {
        guard let meeting = meetings.first(where: { $0.id == id }) else { return 0 }
        let inputs = meeting.visiblePhotos.compactMap { photo -> PhotoProcessingInput? in
            let url = photoURL(photo, in: id)
            guard photoBackoff.mayRead(photo.id), FileManager.default.fileExists(atPath: url.path) else { return nil }
            return PhotoProcessingInput(photo: photo, url: url)
        }
        guard !inputs.isEmpty else { return 0 }
        let output = try await engine.describePhotos(meeting, photos: inputs, progress: progress)
        try Task.checkCancellation()
        for (photoID, reason) in output.failures { photoBackoff.failed(photoID, reason: reason) }
        for photoID in output.analyses.keys { photoBackoff.read(photoID) }
        update(id) { $0.applyPhotoAnalyses(output.analyses) }
        post(output.notices)
        if !output.failures.isEmpty { schedulePhotoRetry() }
        return output.analyses.count
    }

    /// Whether a photo still needs reading now: it has no reading (or the chosen caption model's),
    /// and it isn't waiting after a failure.
    func needsPhotoReading(_ photo: MeetingPhoto) -> Bool {
        InferenceProcessingEngine.needsReading(photo, captionModel: photoModel) && photoBackoff.mayRead(photo.id)
    }

    /// After a sync pass, or once a failed photo's wait is over: conversations with photos that were
    /// never read, and may be now, queue a reading. Nothing else is read again.
    func requeueUnreadPhotos() {
        for meeting in meetings where meeting.visiblePhotos.contains(where: { $0.analysis == nil && photoBackoff.mayRead($0.id) }) {
            readPhotosWhenIdle(meeting.id)
        }
    }

    /// Wakes when the soonest failed photo may be tried again.
    func schedulePhotoRetry() {
        photoRetry?.cancel()
        let waiting = meetings.flatMap { meeting in meeting.visiblePhotos.filter { $0.analysis == nil }.map(\.id) }
        guard let next = photoBackoff.nextRetry(among: waiting) else { return }
        photoRetry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow))) } catch { return }
            self?.requeueUnreadPhotos()
        }
    }

    /// Photos that arrive after a conversation was summarized (added here, or synced from the iPhone)
    /// are read on their own, without summarizing again, and placed in the summary by the same rule
    /// (`PhotoPlacement.arrange`): under the section closest to when each was taken, if it plainly
    /// belongs. Waits for the queue: a job reads its own conversation's photos.
    func readPhotosWhenIdle(_ id: UUID) {
        pendingPhotoReadings.insert(id)
        readNextPhotosWhenIdle()
    }

    func readNextPhotosWhenIdle() {
        guard library.isLoaded, !library.isApplyingSync, processingTask == nil, processingQueue.isEmpty,
              downloadingID == nil, readingPhotoID == nil else { return }
        guard let id = pendingPhotoReadings.sorted(by: { $0.uuidString < $1.uuidString }).first(where: { $0 != recordingID }) else { return }
        pendingPhotoReadings.remove(id)
        guard let meeting = meetings.first(where: { $0.id == id }), meeting.visiblePhotos.contains(where: needsPhotoReading) else {
            readNextPhotosWhenIdle()
            return
        }
        let configuration = InferenceProcessingEngine.Configuration(
            transcriptionModel: "", summaryModel: "", detectSpeakers: false, speakerModel: "", speakerOptions: .init(), fingerprint: "photos",
            speakerMatchThreshold: 0, speakerMatchMargin: 0, photoModel: photoModel)
        let engine = InferenceProcessingEngine(inference: sources.inference ?? runtime, configuration: configuration)
        readingPhotoID = id
        Task {
            defer {
                readingPhotoID = nil
                runQueue()
                startPendingDownload()
                readNextPhotosWhenIdle()
            }
            // The models run one at a time: while another reading or a download holds them, try again shortly.
            for attempt in 0..<6 {
                guard processingID != id, recordingID != id else { return }
                do {
                    // Only what was just read moves; a summary is never emptied because reading couldn't run.
                    if try await readPhotos(id, engine: engine, progress: { _ in }) > 0 { placePhotosInSummary(id) }
                    return
                } catch LocalIntelligenceError.busy {
                    try? await Task.sleep(for: .seconds(2 << min(attempt, 4)))
                } catch {
                    // A photo that can't be read is a notice; the next job reads it again.
                    return
                }
            }
        }
    }

    /// Places photos in the current summary without rewriting it. Placement isn't prose, so it isn't
    /// a Version History entry; the person's own choices (Remove from Summary) stand.
    func placePhotosInSummary(_ id: UUID) {
        update(id) { meeting in
            guard let summary = meeting.summary else { return }
            let arranged = PhotoPlacement.arrange(summary, in: meeting)
            if arranged != summary { meeting.summary = arranged }
        }
    }

    // MARK: Pasteboard and providers

    /// The image types a drop, paste, or Continuity Camera import can carry.
    static let photoTypes: [UTType] = [.fileURL, .heic, .jpeg, .png, .tiff, .image]

    private static func fileURL(from provider: NSItemProvider) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: url) }
            }
        }
    }

    /// The provider's original bytes when they're HEIC, JPEG, or PNG; any other image as PNG.
    private static func imageData(from provider: NSItemProvider) async throws -> Data? {
        for type in [UTType.heic, .jpeg, .png] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            if let data = try await loadData(provider, type: type), PhotoFormat.detect(data) != nil { return data }
        }
        for type in [UTType.tiff, .image] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            if let data = try await loadData(provider, type: type) {
                return PhotoFormat.detect(data) != nil ? data : await Task.detached { pngData(data) }.value
            }
        }
        return nil
    }

    private static func loadData(_ provider: NSItemProvider, type: UTType) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: data) }
            }
        }
    }

    nonisolated static func pngData(contentsOf url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return pngData(source)
    }

    nonisolated static func pngData(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return pngData(source)
    }

    /// The first image, as PNG, with its metadata (the capture date) carried over.
    nonisolated private static func pngData(_ source: CGImageSource) -> Data? {
        guard CGImageSourceGetCount(source) > 0 else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImageFromSource(destination, source, 0, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}

/// What Copy puts on the pasteboard for a photo: a copy re-encoded as an export would be
/// (`ExportPhoto`: only its orientation and capture time, no GPS, maker notes, camera, or lens), in a
/// folder of its own under the temporary directory. Only the newest copy is kept, so a quick second
/// Copy wins even if the first finishes later.
@MainActor
enum PhotoCopy {
    /// Where copies are written (tests use their own).
    static var folder = FileManager.default.temporaryDirectory.appendingPathComponent("Daybook Copied Photos", isDirectory: true)

    enum Outcome: Equatable {
        case copied(URL)
        /// The original isn't an image this Mac can read and write.
        case unreadable
        /// A later Copy replaced this one before it was written.
        case superseded
    }

    private static var latest: UUID?

    /// Writes the copy off the main actor, then puts it on `pasteboard`.
    static func copy(_ original: URL, name: String, to pasteboard: some LocalPasteboardWriting) async -> Outcome {
        let token = UUID()
        latest = token
        let destination = folder.appendingPathComponent(token.uuidString, isDirectory: true)
        let written = await Task.detached(priority: .userInitiated) { () -> URL? in
            let files = FileManager.default
            guard (try? files.createDirectory(at: destination, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])) != nil else { return nil }
            guard let file = ExportPhoto.write(original, to: destination, name: name) else {
                try? files.removeItem(at: destination)
                return nil
            }
            return destination.appendingPathComponent(file)
        }.value
        guard latest == token else {
            try? FileManager.default.removeItem(at: destination)
            return .superseded
        }
        guard let written else { return .unreadable }
        let earlier = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for copy in earlier where copy.lastPathComponent != token.uuidString { try? FileManager.default.removeItem(at: copy) }
        LocalPasteboard.copy([written as NSURL], to: pasteboard)
        return .copied(written)
    }
}
