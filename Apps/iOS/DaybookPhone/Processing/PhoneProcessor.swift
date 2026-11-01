import DaybookCore
import DaybookKit
import DaybookLive
import Foundation
import Observation

/// Processing this iPhone's own recordings with its own models (docs/iphone.md, "Processing on this
/// iPhone"): transcription, speakers, voice profiles, the background-audio check, fusion, and speaker
/// labels from the synced profiles. The engine is the Mac's (`InferenceProcessingEngine` through the
/// `ProcessingEngine` seam), and the work runs under the same `ProcessingRequest` claims
/// (`OnDeviceProcessing`), so a Mac and this iPhone never both transcribe a recording.
///
/// - **The summary is placed.** Once a conversation is fused here its summary is due, and the summary
///   placement decides where it runs (`Services.summaryDue`; docs/multipoint.md, "Where summaries run").
///   One placed on this iPhone comes back as its own work (`summarizeHere`), with these same rules.
///
/// - **One at a time, never in a recording's way.** One conversation runs at once. A recording starting
///   pauses it, and nothing starts while one is under way.
/// - **In the background** the work goes on under the system's continued-processing task where iOS
///   allows one (`ContinuedProcessing`), with its progress; otherwise, and when the system ends that
///   task, it pauses and resumes when Daybook is back on the screen. A summary needs the graphics
///   processor, which iOS doesn't give an app in the background, so it waits for the screen.
/// - **Backing off** as live captions do (`LiveLoadPolicy.iPhone`): Serious heat, Low Power Mode, and
///   a battery under 20% unplugged pause it until they pass.
/// - **Claims.** The request is claimed when work starts (or when the recording was filed), renewed
///   with the stage and fraction at each stage and every minute, and kept through a pause, so a Mac
///   leaves it while this iPhone comes back to it; a claim that lapses (the iPhone stayed away longer
///   than the lease) is a Mac's to take, and this iPhone stops as soon as it sees one has.
@MainActor
@Observable
final class PhoneProcessor {
    /// Why work waits instead of running.
    enum Pause: Equatable, Sendable {
        /// A recording is under way.
        case recording
        /// Daybook isn't on the screen and iOS didn't let the work go on (or it's the summary).
        case background
        case heat
        case lowPowerMode
        case lowBattery
    }

    /// The conversation being processed here.
    struct Running: Equatable, Sendable {
        var meetingID: UUID
        var requestID: UUID
        var work: OnDeviceProcessing.Work
        var stage: ProcessingRequest.Stage
        var fraction: Double
    }

    /// What the processor reads about the iPhone.
    struct Conditions: Equatable, Sendable {
        enum Screen: Equatable, Sendable { case active, inactive, background }
        var screen: Screen = .active
        var isRecording = false
        var live = LiveConditions()
    }

    /// What it works with: this iPhone's models, its audio, and what it may run.
    struct Services {
        /// The engine a job runs with: this iPhone's models now. Nil when they aren't all here.
        var engine: @MainActor () -> (any ProcessingEngine)?
        /// The local summarizer, when this iPhone can summarize now.
        var summarizer: @MainActor () -> (any LocalSummarizing)?
        /// What this iPhone's models can do now; all false while processing here is off.
        var capabilities: @MainActor () -> ProcessingCapabilities
        /// Whether a recording was made or brought in on this iPhone.
        var owns: @MainActor () -> @Sendable (RecordingTrack) -> Bool
        /// A recording's audio on this iPhone, fetched again from iCloud if it went back there.
        var audio: @MainActor (RecordingTrack, UUID) async throws -> URL
        /// Lets the models go once a job ends: an iPhone keeps nothing it isn't using.
        var release: @MainActor () async -> Void
        /// After work changed the library, and when a job ends.
        var changed: @MainActor () -> Void = {}
        /// A conversation is transcribed and fused here: where its summary runs is the placement's. `askedFor`
        /// when the person asked for the work (Transcribe Everything Again, Identify Speakers Again), so it starts
        /// at once; otherwise it's due, and may count down. The template the request asked for comes with it.
        var summaryDue: @MainActor (_ meetingID: UUID, _ templateID: String?, _ askedFor: Bool) -> Void = { _, _, _ in }
        /// Just before a job starts: other heavy work (the live speaker pass) gives way.
        var willStart: @MainActor () -> Void = {}
    }

    /// How long a claim lasts and how often it's renewed while the work runs (the Mac's).
    struct Timing: Equatable, Sendable {
        var lease: TimeInterval = ProcessingRequest.defaultLease
        var renewInterval: Duration = .seconds(60)
    }

    private(set) var running: Running?
    /// Why the next conversation waits; nil while nothing does, or work runs.
    private(set) var pause: Pause?
    /// Conversations a pause stopped partway; they go first when work resumes.
    private(set) var paused: Set<UUID> = []
    /// Summarize requests the placement put on this iPhone (`summarizeHere`), until they finish here.
    @ObservationIgnored private(set) var summariesHere: Set<UUID> = []

    let library: LibraryController
    let continued: ContinuedProcessing
    @ObservationIgnored var services: Services
    @ObservationIgnored var timing = Timing()
    @ObservationIgnored var conditions = Conditions() {
        didSet { if conditions != oldValue { conditionsChanged() } }
    }
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    /// Why the running job was stopped from outside (a pause, or another device took it over).
    @ObservationIgnored private var stopping: Stop?
    @ObservationIgnored private var lastRenewal = Date.distantPast
    @ObservationIgnored private var lastRenewedStage: ProcessingRequest.Stage?

    private enum Stop: Equatable { case pause(Pause), lost }
    /// How a job ended.
    enum Outcome: Equatable, Sendable {
        /// Done here, summary and all.
        case completed
        /// Transcribed and fused here: the summary goes to the placement.
        case summaryDue
        /// Transcribed here; the rest (lining recordings up, fusing, and the summary) is a Mac's.
        case handedBack
        case failed(String)
        case paused(Pause)
        /// Another device holds the request now.
        case lost
    }
    /// The last job's outcome, for tests and the interface.
    private(set) var lastOutcome: (meetingID: UUID, outcome: Outcome)?

    init(library: LibraryController, services: Services, continued: ContinuedProcessing) {
        self.library = library
        self.services = services
        self.continued = continued
        continued.onExpire = { [weak self] in self?.continuedTaskExpired() }
    }

    var isBusy: Bool { running != nil }

    /// This iPhone as the claims know it, with what it can do now.
    var device: OnDeviceProcessing.Device {
        OnDeviceProcessing.Device(identity: library.thisDevice, capabilities: services.capabilities(), owns: services.owns(),
                                  summariesHere: summariesHere)
    }

    /// The placement put a conversation's summary on this iPhone, on `request` (which it claimed): it runs
    /// as this iPhone's own work, one conversation at a time, while Daybook is on the screen, and backing off
    /// as the rest does.
    func summarizeHere(_ meetingID: UUID, request: ProcessingRequest) {
        summariesHere.insert(request.id)
        pickUp()
    }

    /// The app's processor, for status lines anywhere in the interface (`ProcessingStatus.phone`).
    /// Reading through it from a view's body observes it like any other observable.
    static weak var current: PhoneProcessor?

    /// This iPhone's queue for one conversation, as `ProcessingStatus` reads it: running here, paused
    /// here, or claimed here and waiting its turn. Nil when this iPhone isn't working on it, so its
    /// status is the library's (a Mac's claim, a request waiting for one). Never "waiting for models":
    /// what this iPhone can't do waits for a Mac.
    func queue(for meeting: Meeting, at now: Date = Date()) -> ProcessingStatus.LocalQueue? {
        let id = meeting.id
        // A Summarize request claimed for the cloud isn't this queue's: the placement says where that runs.
        let claimedHere = meeting.openProcessingRequests.contains {
            $0.isClaimed(by: library.thisDevice, at: now) && ($0.mode != .summaryOnly || summariesHere.contains($0.id))
        }
        guard running?.meetingID == id || paused.contains(id) || claimedHere else { return nil }
        let waiting = running?.meetingID != id && !paused.contains(id)
        return ProcessingStatus.LocalQueue(running: running?.meetingID, fraction: running?.fraction ?? 0,
                                           identifyingSpeakers: running?.stage == .identifyingSpeakers,
                                           queued: waiting ? [id] : [], paused: running?.meetingID == id ? [] : paused,
                                           canProcess: true, stage: running?.stage)
    }

    // MARK: Picking up work

    /// Starts the next conversation this iPhone should process, if nothing runs and nothing stops it:
    /// after a recording is filed, a sync pass, a model download, and when Daybook comes back.
    func pickUp() {
        guard running == nil else { return }
        let device = self.device
        guard device.capabilities.transcribes || device.capabilities.summarizes else { pause = nil; return }
        let now = Date()
        // Paused ones first, then the oldest request.
        let candidates = library.meetings.compactMap { meeting -> (Meeting, ProcessingRequest, OnDeviceProcessing.Work)? in
            guard let next = OnDeviceProcessing.next(in: meeting, device: device, at: now) else { return nil }
            return (meeting, next.request, next.work)
        }.sorted { a, b in
            let pa = paused.contains(a.0.id), pb = paused.contains(b.0.id)
            if pa != pb { return pa }
            return (a.1.createdAt, a.1.id.uuidString) < (b.1.createdAt, b.1.id.uuidString)
        }
        guard let first = candidates.first else { pause = nil; return }
        if let reason = blocking(summarizing: first.2 == .summarize) {
            pause = reason
            return
        }
        pause = nil
        for (meeting, request, work) in candidates {
            if work == .summarize, blocking(summarizing: true) != nil { continue }
            if start(meeting, request: request, work: work) { return }
        }
    }

    /// Why work can't run now; nil when it can. The summary also needs Daybook on the screen.
    func blocking(summarizing: Bool) -> Pause? {
        if conditions.isRecording { return .recording }
        let live = conditions.live
        if live.thermal >= .serious { return .heat }
        if live.lowPowerMode { return .lowPowerMode }
        if !live.isCharging, let battery = live.batteryLevel, battery <= LiveLoadPolicy.iPhone.lowBattery { return .lowBattery }
        switch conditions.screen {
        case .active: return nil
        case .inactive: return summarizing ? .background : nil
        case .background: return summarizing || !continued.isRunning ? .background : nil
        }
    }

    private func start(_ meeting: Meeting, request: ProcessingRequest, work: OnDeviceProcessing.Work) -> Bool {
        guard library.claimProcessingRequest(request.id, in: meeting.id, lease: timing.lease) != nil else { return false }
        services.willStart()
        let stage: ProcessingRequest.Stage = work == .summarize ? .summarizing : .transcribing
        running = Running(meetingID: meeting.id, requestID: request.id, work: work, stage: stage, fraction: 0)
        paused.remove(meeting.id)
        stopping = nil
        if conditions.screen == .active {
            continued.begin(job: request.id, title: Self.title(stage), subtitle: meeting.title)
        }
        renew(force: true)
        startHeartbeat()
        let id = meeting.id
        job = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.run(meetingID: id, requestID: request.id, work: work)
            await self.finish(id, requestID: request.id, outcome: outcome)
        }
        return true
    }

    // MARK: Running

    private func run(meetingID id: UUID, requestID: UUID, work: OnDeviceProcessing.Work) async -> Outcome {
        do {
            try await process(id, requestID: requestID, work: work)
            guard let meeting = library.meeting(id), let request = meeting.processingRequests?.first(where: { $0.id == requestID }) else {
                return .lost
            }
            guard work == .summarize else {
                // Fused here: the placement decides where the summary runs. Otherwise the request goes back
                // for a Mac, which lines the recordings up, fuses, and summarizes.
                return OnDeviceProcessing.fusesHere(meeting) ? .summaryDue : .handedBack
            }
            // The summary placed here.
            guard services.capabilities().summarizes, let summarizer = services.summarizer() else { return .handedBack }
            if let reason = blocking(summarizing: true) { return .paused(reason) }
            try await summarize(id, request: request, with: summarizer)
            return .completed
        } catch {
            if let stopping {
                switch stopping {
                case .pause(let reason): return .paused(reason)
                case .lost: return .lost
                }
            }
            if error is CancellationError { return .paused(.background) }
            return .failed(error.localizedDescription)
        }
    }

    /// Transcription or speakers, then fusion and speaker labels: everything before the summary.
    private func process(_ id: UUID, requestID: UUID, work: OnDeviceProcessing.Work) async throws {
        guard let request = library.meeting(id)?.processingRequests?.first(where: { $0.id == requestID }) else { return }
        let tracks: [UUID], mode: ProcessingRequest.Mode
        switch work {
        case .transcribe(let ids): tracks = ids; mode = request.mode == .fullRetranscription ? .fullRetranscription : .newAudio
        case .identifySpeakers(let ids): tracks = ids; mode = .speakerRefresh
        case .placeSummary: tracks = []; mode = request.mode
        case .summarize: tracks = []; mode = .summaryOnly
        }
        if !tracks.isEmpty {
            guard let engine = services.engine() else { throw PhoneProcessingError.modelsMissing }
            let vocabulary = vocabulary(for: id)
            let matching = SpeakerMatchingConfiguration()
            for (index, trackID) in tracks.enumerated() {
                try Task.checkCancellation()
                guard let meeting = library.meeting(id), let track = meeting.tracks.first(where: { $0.id == trackID }) else { continue }
                let previous = meeting.transcripts.filter { $0.trackID == trackID }.max { $0.createdAt < $1.createdAt }
                // Transcribe asks only for recordings without a transcript: one that has one now (made
                // meanwhile, by this iPhone or a Mac) isn't transcribed again.
                if mode == .newAudio, previous != nil { continue }
                let url = try await services.audio(track, id)
                let share = 1 / Double(tracks.count), base = Double(index) * share
                let output = try await engine.transcribe(
                    TrackProcessingInput(meetingID: id, track: track, audioURL: url, mode: mode, previousTranscript: previous, vocabulary: vocabulary),
                    progress: { [weak self] update in
                        Task { @MainActor in self?.progressed(base + share * min(1, max(0, update.fraction)), message: update.message) }
                    })
                try Task.checkCancellation()
                library.update(id) { $0.apply(output, matching: matching, allowSameSource: previous != nil) }
                services.changed()
            }
        }
        // Fused here only when every recording is transcribed and on the timeline; otherwise a Mac lines
        // them up and fuses (`OnDeviceProcessing.fusesHere`). Summarize Again reads the transcript as it is.
        if mode != .summaryOnly, let meeting = library.meeting(id), OnDeviceProcessing.fusesHere(meeting) {
            await library.realign(id)
            // Speaker labels from the library's profiles (synced from the Mac), so the summary has their
            // names. Only this conversation: the Mac reconciles the rest.
            let others = Set(library.meetings.map(\.id)).subtracting([id])
            await library.reconcileSpeakerProfiles(options: SpeakerProfileOptions(), skipping: others)
            services.changed()
        }
    }

    private func summarize(_ id: UUID, request: ProcessingRequest, with summarizer: any LocalSummarizing) async throws {
        guard let current = library.meeting(id) else { return }
        guard !MeetingEvidence.transcript(current).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DaybookError.noSpeech }
        setStage(.summarizing)
        try await readPhotos(id)
        guard let meeting = library.meeting(id) else { return }
        let template = request.templateID.map { SummaryTemplate.resolved(id: $0, kind: meeting.kind, templates: library.templates) }
            ?? library.resolvedTemplate(for: meeting)
        let started = Date()
        let output = try await summarizer.summarize(meeting, template: template, vocabulary: vocabulary(for: id)) { [weak self] fraction in
            Task { @MainActor in self?.progressed(fraction, message: nil) }
        }
        try Task.checkCancellation()
        // With where it ran ("Summarized on this iPhone"), unless another device's summary arrived meanwhile.
        guard library.applyPlacedSummary(output.summary, to: id, place: .thisDevice, started: started) else { return }
        library.update(id) { $0.errorMessage = output.warnings.isEmpty ? nil : output.warnings.joined(separator: "\n") }
        try? await library.proposeTerms(output.suggestedTerms, for: id)
    }

    /// Photos taken during the recording, read with Apple Vision (their text, what they show, near copies)
    /// before the summary, as the Mac reads them, so the summary can place them by what they show. A
    /// photo that can't be read is left for the summary to place by time.
    private func readPhotos(_ id: UUID) async throws {
        guard let meeting = library.meeting(id), let engine = services.engine() else { return }
        var inputs: [PhotoProcessingInput] = []
        for photo in meeting.visiblePhotos where photo.analysis == nil {
            if let url = try? await library.photoURL(for: photo, in: id), FileManager.default.fileExists(atPath: url.path) {
                inputs.append(PhotoProcessingInput(photo: photo, url: url))
            }
        }
        guard !inputs.isEmpty else { return }
        let read = try await engine.describePhotos(meeting, photos: inputs, progress: { _ in })
        try Task.checkCancellation()
        if !read.analyses.isEmpty { library.update(id) { $0.applyPhotoAnalyses(read.analyses) } }
    }

    private func vocabulary(for id: UUID) -> [String] {
        library.glossary.filter { $0.approved || $0.sourceMeetingIDs.contains(id) }.map(\.term)
    }

    private func finish(_ id: UUID, requestID: UUID, outcome: Outcome) async {
        stopHeartbeat()
        let now = Date()
        // Where the summary goes next, once the models are let go.
        var summaryDue: (templateID: String?, askedFor: Bool)?
        if case .paused = outcome {} else { summariesHere.remove(requestID) }
        switch outcome {
        case .completed:
            library.completeProcessingRequest(requestID, in: id, at: now)
            // Any other open request this work satisfied, as on the Mac.
            if let meeting = library.meeting(id) {
                for request in meeting.openProcessingRequests where request.isSatisfied(by: meeting)
                    && request.isClaimable(by: library.thisDevice, at: now) {
                    library.completeProcessingRequest(request.id, in: id, at: now)
                }
            }
        case .summaryDue:
            // This iPhone's part is done; the summary is the placement's (a countdown, then here, a Mac, or the cloud).
            let request = library.meeting(id)?.processingRequests?.first { $0.id == requestID }
            library.completeProcessingRequest(requestID, in: id, at: now)
            summaryDue = (request?.templateID, request.map { $0.mode != .newAudio } ?? false)
        case .handedBack:
            let request = library.meeting(id)?.processingRequests?.first { $0.id == requestID }
            if let request, request.mode == .fullRetranscription || request.mode == .speakerRefresh {
                // Done here: a Mac carrying out the request would do it all again. It summarizes instead.
                library.completeProcessingRequest(requestID, in: id, at: now)
                library.requestProcessing(id, mode: .summaryOnly, templateID: request.templateID, at: now)
            } else {
                library.releaseProcessingRequest(requestID, in: id, at: now)
            }
        case .failed(let reason):
            library.failProcessingRequest(requestID, in: id, reason: reason, at: now)
        case .paused:
            // The claim stays: this iPhone comes back to it, unless it lapses first and a Mac takes it.
            paused.insert(id)
        case .lost:
            paused.remove(id)
        }
        continued.end(success: outcome == .completed || outcome == .handedBack || outcome == .summaryDue)
        lastOutcome = (id, outcome)
        running = nil
        job = nil
        stopping = nil
        // The transcription models go before a summary model loads.
        await services.release()
        services.changed()
        if let summaryDue { services.summaryDue(id, summaryDue.templateID, summaryDue.askedFor) }
        if case .paused(let reason) = outcome { pause = reason } else { pickUp() }
    }

    private func progressed(_ fraction: Double, message: String?) {
        guard var current = running else { return }
        current.fraction = fraction
        if let message, current.stage != .summarizing {
            let speakers = message.lowercased().contains("speaker")
            current.stage = speakers ? .identifyingSpeakers : .transcribing
        }
        let changedStage = current.stage != running?.stage
        running = current
        continued.report(fraction: fraction, title: changedStage ? Self.title(current.stage) : nil)
        renew(force: false)
    }

    private func setStage(_ stage: ProcessingRequest.Stage) {
        guard var current = running, current.stage != stage else { return }
        current.stage = stage
        current.fraction = 0
        running = current
        continued.report(fraction: 0, title: Self.title(stage))
        renew(force: true)
    }

    /// What the system's progress shows.
    static func title(_ stage: ProcessingRequest.Stage) -> String {
        switch stage {
        case .transcribing: return "Transcribing"
        case .identifyingSpeakers: return "Identifying speakers"
        case .summarizing: return "Summarizing"
        }
    }

    // MARK: Claims

    private func startHeartbeat() {
        heartbeat?.cancel()
        let interval = timing.renewInterval
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                self?.renew(force: true)
            }
        }
    }

    private func stopHeartbeat() {
        heartbeat?.cancel()
        heartbeat = nil
        lastRenewedStage = nil
    }

    /// Renews the claim with the stage and fraction: at every change of stage, and every `renewInterval`.
    /// A renewal refused (another device holds the request) stops the work.
    private func renew(force: Bool) {
        guard let current = running, stopping == nil else { return }
        let interval = Double(timing.renewInterval.components.seconds)
        guard force || current.stage != lastRenewedStage || Date().timeIntervalSince(lastRenewal) >= interval else { return }
        lastRenewal = Date()
        lastRenewedStage = current.stage
        if library.renewProcessingClaim(current.requestID, in: current.meetingID, stage: current.stage, fraction: current.fraction,
                                        lease: timing.lease) == nil {
            stop(.lost)
        } else {
            services.changed()
        }
    }

    /// After a sync pass: work another device now holds, or that finished elsewhere, stops here, and so does
    /// work on a conversation that went (a Mac moved its recording into its own conversation of the meeting).
    func reconcileClaims(at now: Date = Date()) {
        for id in paused where library.meeting(id) == nil { paused.remove(id) }
        guard let current = running, stopping == nil else { pickUp(); return }
        let request = library.meeting(current.meetingID)?.processingRequests?.first { $0.id == current.requestID }
        if request?.isClaimable(by: library.thisDevice, at: now) != true { stop(.lost) }
    }

    // MARK: Pausing

    private func stop(_ reason: Stop) {
        guard running != nil, stopping == nil else { return }
        stopping = reason
        job?.cancel()
    }

    /// Something the work depends on changed: a running job pauses when it can't go on, and work
    /// starts when nothing stops it any more.
    private func conditionsChanged() {
        if let current = running {
            if let reason = blocking(summarizing: current.stage == .summarizing) { stop(.pause(reason)) }
        } else {
            pickUp()
        }
    }

    /// The system ended the background task: the work pauses until Daybook is back.
    private func continuedTaskExpired() {
        guard running != nil, conditions.screen != .active else { return }
        stop(.pause(.background))
    }

    /// The conversation went to the Trash (on this iPhone, or a Mac moved its recording into another
    /// conversation), or its recording was removed: its work stops.
    func cancel(_ meetingID: UUID) {
        if running?.meetingID == meetingID { stop(.lost) }
        paused.remove(meetingID)
    }
}

enum PhoneProcessingError: LocalizedError {
    case modelsMissing

    var errorDescription: String? {
        switch self {
        case .modelsMissing: return "The models for transcribing on this iPhone aren’t downloaded."
        }
    }
}

extension ProcessingStatus {
    /// A conversation's status on this iPhone: the same as everywhere, with this iPhone's own work
    /// (`PhoneProcessor.current`) for the conversations it processes.
    @MainActor static func phone(_ meeting: Meeting, now: Date = Date()) -> ProcessingStatus {
        ProcessingStatus(meeting, queue: PhoneProcessor.current?.queue(for: meeting, at: now), now: now)
    }
}
