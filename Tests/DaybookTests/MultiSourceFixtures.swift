import AVFoundation
import Combine
import DaybookCore
@testable import DaybookIntelligence
@testable import DaybookKit
import DaybookTestSupport
import Foundation
import XCTest
@testable import Daybook

/// A recorder with record control that never touches hardware: it connects (or doesn't), confirms
/// commands (or doesn't), and hands over a synthetic recording.
@MainActor
final class FakeRecorder: ObservableObject, RecordControlConnection, ManagedConnection {
    let method = ConnectionMethodKind.direct
    let capabilities: DeviceCapabilities = [.recordControl]
    @Published var state: ConnectionState = .notConnected
    @Published var recordings: [DeviceRecording] = []
    var inventoryUpdatedAt: Date?
    var isRefreshing = false
    @Published var status: DeviceStatus?
    var problem: DeviceProblem?
    var lastConnectedAt: Date?
    var summary = "Fake recorder"
    var isSetUp = true
    var onChange: (() -> Void)?
    @Published var recordCommandPending = false
    var recorderSerial: String? = "FAKE1"
    var managedElsewhere: RecorderOwnership?

    /// Comes into range when asked to connect.
    var reachable = true
    /// Confirms Start and Pause.
    var confirms = true
    /// Confirms Start, but only after Daybook stopped waiting for it.
    var confirmsLate = false
    /// How long after connecting its status and list arrive, as a real recorder's do.
    var listingDelay: Duration = .zero
    /// How long reading its list again takes.
    var refreshDelay: Duration = .milliseconds(30)
    /// Audio handed over for any recording.
    var audio: URL?
    private(set) var commands: [String] = []
    private(set) var transfers: [String] = []
    private var current: UInt32?
    /// Recording by hand while not connected: Daybook learns it from the list after connecting.
    private var unseenSince: Date?
    /// A list the recorder holds that Daybook reads on its next refresh.
    private var unread: [DeviceRecording]?

    func activate() {}
    func connect() {
        commands.append("connect")
        state = .connecting
        Task {
            try? await Task.sleep(for: .milliseconds(30))
            state = reachable ? .connected : .notConnected
            onChange?()
            guard reachable else { return }
            if listingDelay > .zero { try? await Task.sleep(for: listingDelay) }
            if let start = unseenSince {
                unseenSince = nil
                alreadyRecording(since: start)
            } else if status == nil {
                status = DeviceStatus(isRecording: false, serial: "FAKE1", updatedAt: Date())
            }
            inventoryUpdatedAt = Date()
            onChange?()
        }
    }
    func disconnect() { state = .notConnected; onChange?() }
    func refresh() {
        guard state.isConnected else { return }
        isRefreshing = true
        Task {
            try? await Task.sleep(for: refreshDelay)
            if let unread { recordings = unread; self.unread = nil }
            inventoryUpdatedAt = Date()
            isRefreshing = false
            onChange?()
        }
    }

    /// Recording when Daybook connects (the person pressed the button), seen only once its list arrives.
    func recordingUnseen(since start: Date) { unseenSince = start }

    /// The person stopped the recording Daybook started and pressed record again: its status says so at
    /// once; its list, on the next read.
    func personStartsAnother(at start: Date) {
        guard let old = current else { return }
        current = UInt32(start.timeIntervalSince1970)
        status = DeviceStatus(isRecording: true, recordingStartedAt: start, serial: "FAKE1", updatedAt: Date())
        var listed = recordings
        if let index = listed.firstIndex(where: { $0.id == String(old) }) {
            listed[index].isInProgress = false
            listed[index].length = .exact(1)
            listed[index].byteCount = 8_000
        }
        listed.insert(DeviceRecording(id: String(current!), startedAt: start, isInProgress: true), at: 0)
        unread = listed
    }
    func dismissProblem() { problem = nil }
    func forget() { isSetUp = false }

    /// Already recording when Daybook connects, as if the person pressed the button.
    func alreadyRecording(since start: Date) {
        current = UInt32(start.timeIntervalSince1970)
        status = DeviceStatus(isRecording: true, recordingStartedAt: start, serial: "FAKE1", updatedAt: Date())
        recordings = [DeviceRecording(id: String(current!), startedAt: start, isInProgress: true)]
    }

    func startRecording() {
        commands.append("start")
        guard state.isConnected, !recordCommandPending else { return }
        recordCommandPending = true
        Task {
            try? await Task.sleep(for: confirmsLate ? .seconds(2.5) : .milliseconds(30))
            if confirms {
                let start = Date()
                current = UInt32(start.timeIntervalSince1970)
                status = DeviceStatus(isRecording: true, recordingStartedAt: Date(timeIntervalSince1970: Double(current!)), serial: "FAKE1", updatedAt: Date())
                recordings.insert(DeviceRecording(id: String(current!), startedAt: status?.recordingStartedAt, isInProgress: true), at: 0)
            }
            recordCommandPending = false
            onChange?()
        }
    }

    func pauseRecording() {
        commands.append("pause")
        guard state.isConnected, !recordCommandPending else { return }
        recordCommandPending = true
        Task {
            try? await Task.sleep(for: .milliseconds(30))
            if confirms, let current {
                status?.isRecording = false
                status?.recordingStartedAt = nil
                if let index = recordings.firstIndex(where: { $0.id == String(current) }) {
                    recordings[index].isInProgress = false
                    recordings[index].length = .exact(1)
                    recordings[index].byteCount = 8_000
                }
            }
            recordCommandPending = false
            onChange?()
        }
    }

    func transfer(_ recording: DeviceRecording, progress: @escaping @MainActor (TransferPhase, UInt64) -> Void) async throws -> TransferredAudio {
        transfers.append(recording.id)
        guard let audio else { throw DeviceTransferError.rejected("No audio") }
        progress(.finishing, 8_000)
        return TransferredAudio(url: audio, isStaged: false, serial: "FAKE1")
    }

    func automaticImports(links: DeviceLibraryLinks, since: Date, excluding: Set<String>) -> [DeviceRecording] { [] }
}

/// Processing without models: transcripts scripted by each recording's bytes, speakers from one
/// turn, and a summary that records the transcript it was given.
final class FakeInference: MeetingInference, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [String: [RecognizedSegment]] = [:]
    private var _transcribed: [String] = []
    private var _summarized: [String] = []
    private var _blocked: Set<String> = []
    private var _waiting: Set<String> = []
    private var _photosBlocked = false
    private var _readingPhotos = false
    private var voices: [String: [Float]] = [:]
    static let voiceSpace = "test-voice-space"

    /// The recording's one speaker gets this voice embedding (in `voiceSpace`).
    func voice(_ url: URL, _ vector: [Float]) throws {
        let digest = try AudioDigest.sha256(fileURL: url)
        lock.withLock { voices[digest] = vector }
    }

    func blockPhotos(_ blocked: Bool) { lock.withLock { _photosBlocked = blocked } }
    var readingPhotos: Bool { lock.withLock { _readingPhotos } }
    func describeImages(_ requests: [ImageDescriptionRequest], model: ModelReference,
                        progress: @escaping IntelligenceProgressHandler) async throws -> [ImageDescription] {
        lock.withLock { _readingPhotos = true }
        defer { lock.withLock { _readingPhotos = false } }
        while lock.withLock({ _photosBlocked }) { try await Task.sleep(for: .milliseconds(10)) }
        return requests.map { _ in ImageDescription(caption: "Whiteboard", recognizedText: "Planning for launch", sharpness: 0.8) }
    }

    func script(_ url: URL, _ lines: [(Double, String)]) throws {
        let digest = try AudioDigest.sha256(fileURL: url)
        let segments = lines.map { RecognizedSegment(start: $0.0, end: $0.0 + 4, text: " " + $0.1, confidence: 0.9, words: []) }
        lock.withLock { scripts[digest] = segments }
    }
    func block(_ url: URL) throws { let digest = try AudioDigest.sha256(fileURL: url); _ = lock.withLock { _blocked.insert(digest) } }
    func unblock(_ url: URL) throws { let digest = try AudioDigest.sha256(fileURL: url); _ = lock.withLock { _blocked.remove(digest) } }
    func isWaiting(on url: URL) -> Bool { (try? AudioDigest.sha256(fileURL: url)).map { digest in lock.withLock { _waiting.contains(digest) } } ?? false }
    var transcribed: [String] { lock.withLock { _transcribed } }
    var summarized: [String] { lock.withLock { _summarized } }

    func transcribe(url: URL, model: ModelReference, glossary: [String], progress: @escaping IntelligenceProgressHandler) async throws -> RecognitionResult {
        let digest = try AudioDigest.sha256(fileURL: url)
        lock.withLock { _ = _waiting.insert(digest) }
        defer { lock.withLock { _ = _waiting.remove(digest) } }
        // Like the runtime, a blocked transcription ends when its task is cancelled.
        while lock.withLock({ _blocked.contains(digest) }) { try await Task.sleep(for: .milliseconds(10)) }
        try Task.checkCancellation()
        let segments = lock.withLock { () -> [RecognizedSegment] in _transcribed.append(digest); return scripts[digest] ?? [] }
        return RecognitionResult(segments: segments, language: "en", duration: (segments.last?.end ?? 0) + 1)
    }

    func diarize(url: URL, model: ModelReference, options: SpeakerAnalysisOptions, progress: @escaping IntelligenceProgressHandler) async throws -> SpeakerAnalysis {
        let digest = try AudioDigest.sha256(fileURL: url)
        let turns = [SpeakerTurn(speakerID: "A", start: 0, end: 100_000, confidence: 1)]
        guard let voice = lock.withLock({ voices[digest] }) else { return SpeakerAnalysis(turns: turns, embeddings: [:]) }
        return SpeakerAnalysis(turns: turns, embeddings: ["A": voice], embeddingModelID: Self.voiceSpace)
    }

    func summarize(transcript: String, notes: String, template: MeetingKind, glossary: [String], model: ModelReference,
                   templateInstructions: String?, highlightEvidence: String?, progress: @escaping IntelligenceProgressHandler) async throws -> GeneratedMeetingNotes {
        let count = lock.withLock { () -> Int in _summarized.append(transcript); return _summarized.count }
        return GeneratedMeetingNotes(summary: MeetingSummary(kind: .general, title: "Call", overview: "Summary \(count)"),
                                     suggestedTerms: [], rawResponse: "", warnings: [])
    }
}

/// A temporary library, its preferences suite, and helpers shared by the multi-source tests.
@MainActor
struct MultiSourceRig {
    let state: AppState
    let root: URL
    let defaults: UserDefaults
    let suite: String
    let inference = FakeInference()

    static func make(in test: XCTestCase, models: Bool = true) async throws -> MultiSourceRig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookMultiSource-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = test.makeTestSuite("daybook.multisource")
        let defaults = UserDefaults(suiteName: suite)!
        let state = AppState(libraryURL: root, defaults: defaults)
        await state.initialize()
        XCTAssertTrue(state.isReady)
        let rig = MultiSourceRig(state: state, root: root, defaults: defaults, suite: suite)
        state.sources.inference = rig.inference
        state.sources.alignAudio = { _, _, _, _ in nil }
        // Synthetic recordings last a second or two; real ones overlap by minutes.
        state.sources.policy.minimumOverlap = 0.25
        state.sources.recorders.timing = .init(connect: .seconds(2), confirm: .seconds(2), listing: .seconds(2), poll: .milliseconds(10),
                                               inventory: .seconds(1))
        if models {
            state.installedModels = [state.transcriptionModel, state.summaryModel, state.processingPreferences.speakerModelID]
        }
        return rig
    }

    func tearDown() async {
        await state.sources.recorders.settle()
        await state.flush()
        try? FileManager.default.removeItem(at: root)
    }

    /// A short synthetic recording; the frequency and length make its bytes distinct.
    func audio(_ name: String, frequency: Double, seconds: Double = 0.5) throws -> URL {
        let url = root.appendingPathComponent(name)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let frames = AVAudioFrameCount(16_000 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for index in 0..<Int(frames) { buffer.floatChannelData![0][index] = Float(sin(Double(index) * frequency * 2 * .pi / 16_000) * 0.2) }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        return url
    }

    /// A conversation recorded on this Mac at `start`: its microphone track, placed as capture places it.
    func macConversation(_ title: String, at start: Date, seconds: Double, audio url: URL) async throws -> UUID {
        let id = state.newMeeting(title: title, date: start)
        // Imported without models, so nothing starts processing until the test asks.
        let installed = state.installedModels
        state.installedModels = []
        try await state.importFiles([url], source: .microphone, attachTo: id)
        state.installedModels = installed
        state.update(id) { meeting in
            meeting.date = start
            meeting.tracks[0].offset = 0
            meeting.tracks[0].createdAt = start
            meeting.tracks[0].duration = seconds
        }
        await state.flush()
        return id
    }

    func meeting(_ id: UUID) -> Meeting? { state.meetings.first { $0.id == id } }

    /// A Soundcore recording identity: its ID is its start time.
    static func soundcore(_ start: Date) -> DeviceRecordingIdentity {
        DeviceRecordingIdentity(kind: SoundcoreWorkIntegration.id, serial: "FAKE1", recordingID: String(UInt32(start.timeIntervalSince1970)))
    }

    /// Waits until the processing queue is idle.
    func processed() async throws {
        try await waitUntil("processing to finish") { state.processingID == nil && state.queuedIDs.isEmpty }
        await state.flush()
    }

    /// Waits until these conversations are processed, not just until the queue is idle (which it can
    /// be before their work starts): their requests answered, their status settled, and the queue idle.
    func processed(_ ids: UUID..., timeout: TimeInterval = 20) async throws {
        try await waitUntil("processing to finish", timeout: timeout) {
            state.processingID == nil && state.queuedIDs.isEmpty && ids.allSatisfy { id in
                guard let meeting = meeting(id) else { return true }
                let settled = meeting.status == .ready || meeting.status == .failed || state.awaitingModels.contains(id)
                return settled && (meeting.processingRequests ?? []).allSatisfy { $0.outcome != nil }
            }
        }
        await state.flush()
    }
}
