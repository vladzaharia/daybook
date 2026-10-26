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

    /// How a recording joins a conversation another device leads (multipoint: the Mac asked this
    /// iPhone to record, or the conversation already exists here). Its timeline belongs to the
    /// conversation's own origin, so the phone's recording is a source to place, not the origin.
    struct Join: Equatable, Sendable {
        /// Where the phone's recording probably starts on the conversation's timeline, from the link's
        /// clock comparison; nil when unknown. Notes typed here move by it.
        var estimatedOffset: TimeInterval?
        /// When the conversation began, on this iPhone's clock, for a conversation not synced here yet.
        var conversationStart: Date?
        var title: String?
    }

    /// What filing produced: the conversation, and the Transcribe request it wrote (if any).
    struct Filed: Sendable {
        var meeting: Meeting
        var request: ProcessingRequest?
    }

    /// Files a finished phone recording as a conversation with one phone-microphone track, its notes
    /// and bookmarks, and (when `requestTranscription`) a Transcribe request for a Mac, then removes
    /// its staging folder. Safe to repeat after a failure: the same recording is never filed twice.
    ///
    /// With `join` (multipoint), the conversation keeps its date and timeline: the phone's track is a
    /// source the Mac places (offset unknown), its bookmarks stay on that track so they follow its
    /// placement, and its notes are added at their estimated times.
    @discardableResult
    func file(_ recording: PhoneRecording) async throws -> Meeting {
        try await fileRecording(recording).meeting
    }

    @discardableResult
    func fileRecording(_ recording: PhoneRecording, join: Join? = nil, requestTranscription: Bool = true) async throws -> Filed {
        try await reload()
        await controller.acquireLock()
        defer { controller.releaseLock() }
        let identity = PhoneDevice.identity(recordingID: recording.id, installation: installation)
        let joining = join != nil || controller.meeting(recording.id)?.tracks.contains(where: { $0.device != identity }) == true
        if controller.meeting(recording.id) == nil {
            if let join {
                controller.add(Meeting(id: recording.id, title: join.title ?? recording.title,
                                       date: join.conversationStart ?? recording.startedAt, status: .imported))
            } else {
                controller.add(Meeting(id: recording.id, title: recording.title, date: recording.startedAt, notes: recording.notes,
                                       highlights: recording.highlights, status: .imported,
                                       timedNotes: recording.timedNotes.isEmpty ? nil : recording.timedNotes))
            }
        } else if !joining {
            controller.update(recording.id) { meeting in
                for mark in recording.highlights where !meeting.highlights.contains(where: { $0.id == mark.id }) {
                    meeting.highlights.append(mark)
                }
            }
        }
        var track = controller.meeting(recording.id)?.tracks.first { $0.device == identity }
        if track == nil {
            let warnings = recording.warnings.isEmpty ? nil : recording.warnings.joined(separator: "\n")
            let ingested = try await controller.ingest(recording.audioURL, into: recording.id, provenance: RecordingProvenance(
                source: .microphone, device: identity, offset: joining ? nil : 0, duration: recording.duration, startedAt: recording.startedAt,
                capture: recording.capture, conversationDate: joining ? nil : recording.startedAt, message: warnings))
            track = ingested.track ?? controller.meeting(recording.id)?.tracks.first { $0.device == identity }
        }
        if joining, let track { addJoinedWork(recording, track: track.id, offset: join?.estimatedOffset) }
        if let track { try await addCapturedPhotos(recording, track: track.id) }
        controller.update(recording.id) { $0.status = .imported }
        let request = requestTranscription ? controller.requestProcessing(recording.id, mode: .newAudio) : nil
        try await controller.flushDurably()
        try? FileManager.default.removeItem(at: recording.stagingDirectory)
        guard let meeting = controller.meeting(recording.id) else { throw DaybookError.libraryUnavailable }
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

    /// A joined recording's bookmarks stay on its track (they follow its placement); its notes are
    /// appended at their estimated conversation times, or untimed when the offset isn't known.
    private func addJoinedWork(_ recording: PhoneRecording, track: UUID, offset: TimeInterval?) {
        controller.update(recording.id) { meeting in
            for mark in recording.highlights where !meeting.highlights.contains(where: { $0.id == mark.id }) {
                var placed = mark
                placed.trackID = track
                meeting.highlights.append(placed)
            }
        }
        let added = NoteTimeline.paragraphs(of: recording.notes)
        guard let current = controller.meeting(recording.id), !added.isEmpty else { return }
        let existing = Set(NoteTimeline.paragraphs(of: current.notes))
        let fresh = added.filter { !existing.contains($0) }
        guard !fresh.isEmpty else { return }
        let text = current.notes.isEmpty ? fresh.joined(separator: "\n") : current.notes + "\n" + fresh.joined(separator: "\n")
        let times = Dictionary(recording.timedNotes.compactMap { note in note.time.map { (note.text, $0) } }, uniquingKeysWith: { a, _ in a })
        controller.update(recording.id) { meeting in
            var anchors = meeting.timedNotes ?? NoteTimeline.reconcile(previous: [], text: meeting.notes, captureTime: nil)
            for paragraph in fresh {
                let time = offset.flatMap { offset in times[paragraph].map { max(0, $0 + offset) } }
                anchors.append(TimedNote(time: time, text: paragraph))
            }
            meeting.notes = text
            meeting.timedNotes = anchors
        }
    }

    // MARK: Bringing in audio

    /// Imports audio from Files or the share sheet (Voice Memos, call recordings saved from Notes)
    /// into a new conversation named after the file and dated when it was recorded, if the file says.
    /// The original isn't moved or changed. Returns what was filed; audio already in the library
    /// returns that conversation instead of a copy.
    func importFile(_ url: URL, requestTranscription: Bool) async throws -> Filed {
        try await reload()
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        // Copy first: a file shared from another app may vanish when its provider says so.
        let staged = try stage(url)
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
        _ = try await controller.ingest(url, into: id, provenance: .file(source: source, device: identity, duration: duration))
        let request = requestTranscription ? controller.requestProcessing(id, mode: .newAudio) : nil
        await controller.flush()
        guard let meeting = controller.meeting(id) else { throw DaybookError.libraryUnavailable }
        return Filed(meeting: meeting, request: request)
    }

    private func stage(_ url: URL) throws -> URL {
        let folder = importsURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let copy = folder.appendingPathComponent(url.lastPathComponent.isEmpty ? "Recording.m4a" : url.lastPathComponent)
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { readable in
            do { try FileManager.default.copyItem(at: readable, to: copy) } catch { copyError = error }
        }
        if let error = coordinationError ?? copyError { throw error }
        return copy
    }

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
