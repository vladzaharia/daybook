import AVFoundation
import DaybookCaptions
import DaybookKit
import Foundation
import Observation

/// Live captions for the recording in progress, from a DaybookCaptions captioner fed by the
/// recorder's tap: the segments (tentative text replaced in place, final text kept) and saving them
/// to `LiveCaptionStore`, phone-local and never synced. They're feedback that the audio is being
/// heard and something to read until a Mac's transcript arrives; they're never the transcript.
///
/// The recording never depends on them: the captioner runs on its own tasks and drops audio when
/// it falls behind; a captioner that fails only changes `state`.
@MainActor
@Observable
final class LiveCaptionsController {
    private(set) var state: LiveCaptionState = .off
    private(set) var segments: [LiveCaptionSegment] = []
    private(set) var meetingID: UUID?
    private(set) var localeIdentifier = Locale.current.identifier

    let store: LiveCaptionStore
    /// Makes the captioner for a recording; nil when captions are off or can't run in this build.
    @ObservationIgnored var makeCaptioner: () -> (any LiveCaptioning)?
    @ObservationIgnored private var captioner: (any LiveCaptioning)?
    @ObservationIgnored private var listeners: [Task<Void, Never>] = []
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var saving: Task<Void, Never>?
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var createdAt = Date()

    /// While listening, what's heard is written this often, so a crash keeps most of it.
    static let saveInterval: Duration = .seconds(10)

    init(store: LiveCaptionStore, makeCaptioner: @escaping () -> (any LiveCaptioning)?) {
        self.store = store
        self.makeCaptioner = makeCaptioner
    }

    /// The most recent segments, oldest first, for the recording screen.
    func recent(_ count: Int) -> [LiveCaptionSegment] { Array(segments.suffix(count)) }

    /// Whether the recording screen shows captions. When they can't run here (a language without
    /// captions, no Speech support) the screen stays quiet and Settings says why.
    var isShowing: Bool {
        switch state {
        case .off, .unavailable, .finished: return false
        default: return true
        }
    }

    /// Recording into this conversation now.
    var activeMeetingID: UUID? { captioner == nil ? nil : meetingID }

    // MARK: A recording

    /// Before the recorder starts: makes the captioner and returns the tap to give the recorder.
    func prepare(meetingID: UUID) -> (@Sendable (AVAudioPCMBuffer, TimeInterval) -> Void)? {
        reset()
        guard let captioner = makeCaptioner() else { return nil }
        self.captioner = captioner
        self.meetingID = meetingID
        createdAt = Date()
        state = .preparing
        let current = generation
        listeners = [
            Task { [weak self] in
                for await snapshot in captioner.updates {
                    guard let self, self.generation == current else { return }
                    self.segments = snapshot
                    self.dirty = true
                }
            },
            Task { [weak self] in
                for await state in captioner.states {
                    guard let self, self.generation == current else { return }
                    self.state = state
                    if state == .listening { self.startSaving() }
                }
            },
        ]
        // The recorder's host time (seconds) becomes the buffer's time on the recording's timeline.
        return { [captioner] buffer, host in
            captioner.append(buffer, at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: host)))
        }
    }

    /// The recorder is running: listen in `locale`. Returns once the captioner has started (or said why not).
    func start(locale: Locale) async {
        guard let captioner else { return }
        localeIdentifier = locale.identifier
        await captioner.start(locale: locale, sourceFormat: nil)
    }

    /// The recording stopped: finish captioning, keep what stands as heard, and save.
    func finish() async {
        guard let captioner else { return }
        let current = generation
        await captioner.finish()
        for listener in listeners { await listener.value }
        guard generation == current else { return }
        self.captioner = nil
        listeners = []
        saving?.cancel()
        saving = nil
        for index in segments.indices where segments[index].isTentative { segments[index].isTentative = false }
        save()
        state = .off
    }

    /// The recording was filed: the captions belong to its phone track.
    func attach(trackID: UUID, meetingID: UUID) {
        guard var captions = store.captions(for: meetingID) else { return }
        captions.trackID = trackID
        captions.updatedAt = Date()
        try? store.save(captions)
    }

    /// Captions for conversations that went to the Trash go with them.
    func prune(trashed: Set<UUID>) {
        let files = (try? FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), trashed.contains(id), id != activeMeetingID else { continue }
            store.remove(id)
        }
    }

    private func reset() {
        generation = UUID()
        listeners.forEach { $0.cancel() }
        listeners = []
        saving?.cancel()
        saving = nil
        captioner = nil
        segments = []
        meetingID = nil
        dirty = false
        state = .off
    }

    private func startSaving() {
        guard saving == nil else { return }
        saving = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.saveInterval)
                guard !Task.isCancelled, let self else { return }
                if self.dirty { self.save() }
            }
        }
    }

    private func save() {
        guard let meetingID, !segments.isEmpty else { return }
        let captions = LiveCaptions(meetingID: meetingID, trackID: store.captions(for: meetingID)?.trackID,
                                    localeIdentifier: localeIdentifier, segments: segments, createdAt: createdAt, updatedAt: Date())
        do { try store.save(captions); dirty = false } catch {}
    }
}
