import AVFoundation
import Combine
import DaybookKit
import Foundation
import Observation

/// The library on the phone: DaybookKit's `LibraryController` (the same edits, revisions, search,
/// `ProcessingStatus`, and `ProcessingRequest` queue the Mac uses), plus what only the phone needs:
/// a staging area for recordings in progress, filing a finished recording, and bringing in audio
/// from Files, the share sheet, and recorders.
@MainActor
@Observable
final class PhoneLibrary {
    /// Everything the library can do. Views may observe it directly (`@ObservedObject`); anything
    /// read through this class (`conversations`) also updates under Observation, including when a
    /// sync pass brings changes.
    let controller: LibraryController
    let rootURL: URL
    /// Bumps whenever the controller publishes a change, so Observation-based views follow it.
    private(set) var revision = 0
    @ObservationIgnored private let installation: String
    @ObservationIgnored private var subscription: AnyCancellable?

    init(rootURL: URL = LibraryLocation.defaultRoot, sync: LibrarySyncController? = nil,
         installation: String = PhoneDevice.installationID()) {
        self.rootURL = rootURL.standardizedFileURL
        self.installation = installation
        controller = LibraryController(rootURL: self.rootURL, sync: sync)
        // objectWillChange fires before the change lands; count it on the next turn.
        subscription = controller.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.revision &+= 1 }
        }
    }

    /// Where recordings are staged until they're filed: one folder per recording, named by its ID.
    var stagingURL: URL { rootURL.appendingPathComponent("Staging", isDirectory: true) }
    /// Where imports and recorder transfers wait while they're copied in.
    var importsURL: URL { rootURL.appendingPathComponent("Staging/Imports", isDirectory: true) }
    /// Where iOS copies a file another app opens in Daybook (`Documents/Inbox`). Once imported, the
    /// library has its own copy, so this one is removed.
    @ObservationIgnored var inboxURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Inbox", isDirectory: true)

    /// Conversations, newest first.
    var conversations: [Meeting] {
        _ = revision
        return controller.meetings.sorted { $0.date > $1.date }
    }

    var installationID: String { installation }

    func reload() async throws {
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try await controller.load()
    }

    // MARK: Filing a recording

    /// How a recording joins a conversation another device leads (multipoint: a Mac asked this
    /// iPhone to record, or recorded along when this iPhone asked). Its timeline belongs to the
    /// conversation's own origin, so the phone's recording is a source to place, not the origin.
    struct Join: Equatable, Sendable {
        /// Where the phone's recording probably starts on the conversation's timeline, from the link's
        /// clock comparison; nil when unknown. Notes typed here read about right by it until the
        /// recording is placed.
        var estimatedOffset: TimeInterval?
        /// The conversation as the device leading it has it, for a conversation not synced here yet.
        var title: String?
        var date: Date?
    }

    /// What filing produced: the conversation, and the Transcribe request it wrote (if any).
    struct Filed: Sendable {
        var meeting: Meeting
        var request: ProcessingRequest?
    }

    /// Files a finished phone recording as a conversation with one phone-microphone track, its notes
    /// and bookmarks, and (when `requestTranscription`) a Transcribe request for a Mac, then removes
    /// its staging folder. Safe to repeat after a failure: the same recording is never filed twice,
    /// and nothing it brings is added twice.
    ///
    /// With `join` (multipoint), or into a conversation that already has other recordings, the
    /// conversation keeps its title, date, and timeline: the phone's track is a source the Mac places
    /// (offset unknown), and its bookmarks and notes stay with that track until it's placed
    /// (`Meeting.addRecordingWork`). The conversation's status and message are left to the device
    /// leading it.
    @discardableResult
    func file(_ recording: PhoneRecording) async throws -> Meeting {
        try await fileRecording(recording).meeting
    }

    @discardableResult
    func fileRecording(_ recording: PhoneRecording, join: Join? = nil, requestTranscription: Bool = true) async throws -> Filed {
        try await reload()
        await controller.acquireLock()
        defer { controller.releaseLock() }
        let id = recording.id
        // Named by this recording's own ID: a second recording into the same conversation is a new track.
        let identity = PhoneDevice.identity(recordingID: recording.recordingID, installation: installation)
        let joining = join != nil || controller.meeting(id)?.tracks.contains(where: { $0.device != identity }) == true
        if controller.meeting(id) == nil {
            // One a Mac leads that hasn't synced here yet is made as that Mac has it (its title and date
            // came with its request), so the two copies agree when they meet; its status stays the
            // Mac's to set.
            controller.add(Meeting(id: id, title: join?.title ?? recording.title, date: join?.date ?? recording.startedAt,
                                   status: joining ? .draft : .imported))
        }
        var track = controller.meeting(id)?.tracks.first { $0.device == identity }
        if track == nil {
            var capture = recording.capture
            var message = recording.warnings.isEmpty ? nil : recording.warnings.joined(separator: "\n")
            if joining, message != nil {
                // The conversation's message is its leader's; the recording's own warnings stay on its track.
                capture.notes = (capture.notes ?? []) + recording.warnings
                message = nil
            }
            var provenance = RecordingProvenance(source: .microphone, device: identity, offset: joining ? nil : 0, duration: recording.duration,
                                                 startedAt: recording.startedAt, capture: capture, message: message)
            provenance.joinsConversation = joining
            let ingested = try await controller.ingest(recording.audioURL, into: id, provenance: provenance)
            track = ingested.track ?? controller.meeting(id)?.tracks.first { $0.device == identity }
        }
        // The staging folder is the only copy until this recording's bytes are in the library.
        guard let track else { throw DaybookError.saveFailed("The recording wasn’t added to its conversation.") }
        let notes = recording.timedNotes.isEmpty ? NoteTimeline.reconcile(previous: [], text: recording.notes, captureTime: nil) : recording.timedNotes
        controller.update(id) { meeting in
            meeting.addRecordingWork(trackID: track.id, notes: notes, bookmarks: recording.highlights, joining: joining,
                                     shift: join?.estimatedOffset ?? 0)
        }
        try await addCapturedPhotos(recording, track: track.id)
        let request = requestTranscription ? controller.requestProcessing(id, mode: .newAudio) : nil
        try await controller.flushDurably()
        try? FileManager.default.removeItem(at: recording.stagingDirectory)
        guard let meeting = controller.meeting(id) else { throw DaybookError.libraryUnavailable }
        return Filed(meeting: meeting, request: request)
    }

    /// Photos taken while recording, anchored to the phone's track so they follow its placement. One
    /// that isn't a readable image is left out rather than holding up the recording.
    private func addCapturedPhotos(_ recording: PhoneRecording, track: UUID) async throws {
        for photo in recording.photos {
            let url = recording.stagingDirectory.appendingPathComponent(photo.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try await controller.addPhoto(from: url, to: recording.id,
                                              timing: PhotoTimingInput(capturedAt: photo.capturedAt, trackID: track, time: photo.time),
                                              origin: .thisIPhone(installation: installation), fileName: "Photo.\(url.pathExtension)")
            } catch PhotoStoreError.unsupportedImage {
                continue
            }
        }
    }

    // MARK: Bringing in audio

    /// Imports audio from Files or the share sheet (Voice Memos, call recordings saved from Notes)
    /// into a new conversation named after the file and dated when it was recorded, if the file says.
    /// The original isn't moved or changed, except the copy iOS left in the inbox, which goes once
    /// it's imported (a failed import keeps it). Returns what was filed; audio already in the library
    /// returns that conversation instead of a copy.
    func importFile(_ url: URL, requestTranscription: Bool) async throws -> Filed {
        let filed = try await importCopy(of: url, requestTranscription: requestTranscription)
        removeInboxCopy(url)
        return filed
    }

    /// Removes `url` if it's a file iOS put in the inbox; anything else is someone else's file.
    func removeInboxCopy(_ url: URL) {
        let inbox = inboxURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let file = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard url.isFileURL, file.count > inbox.count, Array(file.prefix(inbox.count)) == inbox else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func importCopy(of url: URL, requestTranscription: Bool) async throws -> Filed {
        try await reload()
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        // Copy first: a file shared from another app may vanish when its provider says so.
        let staged = try await stage(url)
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        let duration = try await Self.duration(of: staged)
        await controller.acquireLock()
        defer { controller.releaseLock() }
        if let existing = try await controller.existingMeeting(containingAudioAt: staged) {
            return Filed(meeting: existing, request: nil)
        }
        let title = url.deletingPathExtension().lastPathComponent
        let date = Self.recordingDate(of: url) ?? Date()
        let id = controller.newMeeting(title: title.isEmpty ? "Imported recording" : title, date: date)
        _ = try await controller.ingest(staged, into: id, provenance: .file(source: .imported, duration: duration))
        let request = requestTranscription ? controller.requestProcessing(id, mode: .newAudio) : nil
        await controller.flush()
        guard let meeting = controller.meeting(id) else { throw DaybookError.libraryUnavailable }
        return Filed(meeting: meeting, request: request)
    }

    /// A recorder's transferred recording (the device hub's importer): into `attachTo` when that
    /// conversation is here, into the conversation already holding the same bytes, or a new one
    /// named for the recorder and dated at the recording's start.
    func importDeviceRecording(_ url: URL, identity: DeviceRecordingIdentity, attachTo: UUID?, source: AudioSource,
                               requestTranscription: Bool) async throws -> Filed {
        try await reload()
        let duration = try await Self.duration(of: url)
        await controller.acquireLock()
        defer { controller.releaseLock() }
        // Another device's import of it may have arrived through sync meanwhile: keep that one.
        if let held = DeviceLibraryLinks.meeting(holding: identity, in: controller.meetings).flatMap(controller.meeting) { return Filed(meeting: held) }
        var target = attachTo.flatMap { controller.meeting($0) != nil ? $0 : nil }
        if target == nil { target = try await controller.existingMeeting(containingAudioAt: url)?.id }
        let id = target ?? controller.newMeeting(title: Self.deviceTitle(identity, fallback: url), date: Self.deviceStart(identity) ?? Date())
        _ = try await controller.ingest(url, into: id, provenance: .file(source: source, device: identity, duration: duration,
                                                                        recorderClock: DeviceRecordingStart.clock(of: identity)))
        let request = requestTranscription ? controller.requestProcessing(id, mode: .newAudio) : nil
        await controller.flush()
        guard let meeting = controller.meeting(id) else { throw DaybookError.libraryUnavailable }
        return Filed(meeting: meeting, request: request)
    }

    /// Copies a shared file into staging. The coordinated read can wait on its File Provider (iCloud
    /// Drive downloading it, another app writing it), and the copy can be long, so both happen on a
    /// queue of their own, never the main actor.
    private func stage(_ url: URL) async throws -> URL {
        let folder = importsURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let copy = folder.appendingPathComponent(url.lastPathComponent.isEmpty ? "Recording.m4a" : url.lastPathComponent)
        let intent = NSFileAccessIntent.readingIntent(with: url, options: [.withoutChanges])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSFileCoordinator().coordinate(with: [intent], queue: Self.stagingQueue) { error in
                if let error { continuation.resume(throwing: error); return }
                do { try FileManager.default.copyItem(at: intent.url, to: copy); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
        return copy
    }

    private static let stagingQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Daybook imports"
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// The file's length, which also checks that it's audio iOS can read.
    static func duration(of url: URL) async throws -> TimeInterval {
        let seconds = try await AVURLAsset(url: url).load(.duration).seconds
        guard seconds.isFinite, seconds > 0 else { throw LibraryError.invalidAudio(url.lastPathComponent) }
        return seconds
    }

    /// When a shared file was recorded: its creation date, which Voice Memos and Files keep.
    static func recordingDate(of url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate
    }

    /// "Soundcore Work at 10:02 AM", or the file's name.
    static func deviceTitle(_ identity: DeviceRecordingIdentity, fallback url: URL) -> String {
        guard let start = deviceStart(identity) else { return url.deletingPathExtension().lastPathComponent }
        let name = DeviceCatalog.kind(identity.kind)?.name ?? "Recorder"
        return "\(name) at \(start.formatted(date: .omitted, time: .shortened))"
    }

    /// Soundcore recording IDs are their Unix start times.
    static func deviceStart(_ identity: DeviceRecordingIdentity) -> Date? { DeviceRecordingStart.date(of: identity) }

    // MARK: Reading

    /// Processing asked of a Mac for a conversation and not finished yet.
    func openRequests(for meetingID: UUID) -> [ProcessingRequest] {
        controller.meeting(meetingID)?.openProcessingRequests ?? []
    }

    /// The audio file of a conversation's track, for playback and tests.
    func audioURL(for track: RecordingTrack, in meetingID: UUID) async throws -> URL {
        try await MeetingStore(rootURL: rootURL).audioURL(for: track, in: meetingID)
    }
}

extension NoteTimeline {
    /// Nonempty paragraphs, as `NoteTimeline` splits notes.
    static func paragraphs(of text: String) -> [String] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

/// How the library knows a track came from Daybook on this iPhone: the phone is a device to the Mac
/// ("Daybook on iPhone"), so its recordings carry a device identity like a Soundcore's do. The
/// track's `source` stays `.microphone`; no new `AudioSource` case, which older Macs couldn't decode.
enum PhoneDevice {
    static let kind = "daybook.iphone"

    /// A stable, random ID for this installation (not the hardware's).
    static func installationID(defaults: UserDefaults = .standard) -> String {
        let key = "daybook.installationID"
        if let value = defaults.string(forKey: key) { return value }
        let value = UUID().uuidString
        defaults.set(value, forKey: key)
        return value
    }

    static func identity(recordingID: UUID, installation: String) -> DeviceRecordingIdentity {
        DeviceRecordingIdentity(kind: kind, serial: installation, recordingID: recordingID.uuidString)
    }
}
