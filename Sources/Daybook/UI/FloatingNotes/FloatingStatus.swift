import DaybookCore
import DaybookDesign
import DaybookDevices
import DaybookKit
import DaybookUI
import Foundation

// What Floating Notes says about the recording and everything around it (docs/interface.md, "Floating Notes"): the
// status bar's phase and chips, and the home's status lines. The recording's words are the ones the iPhone's
// recorder says too (DaybookUI's `RecordingStatusWords`); recorders, iPhones, and this Mac's queue read as they do
// everywhere else (`RecorderStatusWords`, `PeerStatusWords`, `QueueStatusWords`). Plain values from plain inputs,
// so tests read exactly what each state says and the views only draw it.

/// The facts the panel's status is built from, gathered from the app (`FloatingStatusInputs.make`).
struct FloatingStatusInputs: Equatable {
    /// The focused conversation's processing.
    enum Work: Equatable {
        case transcribing(Double?)
        case identifyingSpeakers
        case summarizing
        /// On another device: its name, the step, and how far.
        case elsewhere(device: String, stage: ProcessingRequest.Stage, fraction: Double?)
        case waiting
        /// Asked for on `device`, waiting for a Mac to take it.
        case requested(device: String)
        /// Waiting for models, and how this Mac's downloads stand (nil: none is under way, owed, or stopped).
        case models(ModelDownloadState?)
        case paused
        /// Couldn't finish, in the words both apps use for the failure.
        case failed(FailureWords)
        case ready(summary: Bool)
        /// Transcribed, its summary waiting for this Mac's summary model (transcript first): what it waits for, in the
        /// page's words ("Waiting to summarize after the download · 38%").
        case transcriptReady(waiting: String)
        /// Done with this Mac's audio; a recording made alongside it hasn't arrived ("Waiting for iPhone audio").
        case awaiting(String)
        /// Its summary starts on this Mac at `until`, unless the person chooses the cloud first (`cloud`: on offer).
        case summaryCountdown(until: Date, cloud: Bool)
        /// Summarizing in the cloud, with this model.
        case summarizingWith(String)
    }

    /// This Mac's queue, for the home.
    struct Queue: Equatable {
        typealias Stage = ProcessingRequest.Stage
        var running: Stage?
        var fraction: Double = 0
        /// The running job's summary counts down to this Mac until then.
        var countdown: Date?
        /// The running job's summary is in the cloud, with this model.
        var cloudModel: String?
        var waiting = 0
        var awaitingModels = 0
        /// How this Mac's model downloads stand.
        var models: ModelDownloadState?
        var isEmpty: Bool { running == nil && waiting == 0 && awaitingModels == 0 && models == nil }
    }

    /// The recording, its recorders, and the iPhones: what both recorders say.
    var recording = RecordingStatusInputs()
    var work: Work?
    var queue = Queue()
    var syncProblem: String?

    var phase: RecordingStatusInputs.Phase {
        get { recording.phase }
        set { recording.phase = newValue }
    }
}

enum FloatingStatus {
    // MARK: Phase

    static func phase(_ inputs: FloatingStatusInputs) -> RecorderPhase? { RecordingStatusWords.phase(inputs.recording) }

    /// The words under "Recording stopped": why, when the recorder knows a reason of its own; otherwise only what's
    /// left, since the title already says it stopped. `reason` is `AppState.unexpectedStops`' sentence; none means
    /// nothing reached the conversation.
    @MainActor
    static func stoppedMessage(_ reason: String?) -> String {
        guard let reason else { return "Everything up to then is saved." }
        return reason == RecordingController.unexpectedStopSentence ? "What was recorded is saved." : reason
    }

    // MARK: Chips

    /// What a status bar includes. The home's full layout lists devices and the queue as lines, so its bar leaves
    /// them out.
    enum ChipKind: CaseIterable { case call, devices, work, queue, sync }

    /// The status bar's chips, in order: the call (while recording), recorders, iPhones, the shown conversation's
    /// processing (once it isn't recording), this Mac's queue, then sync when it's a problem.
    static func chips(_ inputs: FloatingStatusInputs, including kinds: Set<ChipKind> = Set(ChipKind.allCases),
                      now: Date = Date()) -> [RecorderChip] {
        var chips: [RecorderChip] = []
        let recording = inputs.phase == .recording
        if kinds.contains(.devices) {
            chips = RecordingStatusWords.chips(inputs.recording, includesCall: kinds.contains(.call), now: now)
        } else if recording, kinds.contains(.call), let call = RecordingStatusWords.callChip(inputs.recording.call) {
            chips = [call]
        }
        if kinds.contains(.work), !recording, let work = inputs.work.flatMap({ workChip($0, now: now) }) { chips.append(work) }
        if kinds.contains(.queue), !recording, let queue = queueChip(inputs.queue, now: now) { chips.append(queue) }
        if kinds.contains(.sync), let problem = inputs.syncProblem {
            chips.append(RecorderChip(target: .sync, symbol: "exclamationmark.icloud", label: "Not syncing", tone: .attention, detail: problem))
        }
        return chips
    }

    static func workChip(_ work: FloatingStatusInputs.Work, now: Date = Date()) -> RecorderChip? {
        func chip(_ symbol: String, _ label: String, short: String? = nil, _ tone: StatusTone, progress: Double? = nil, detail: String? = nil,
                  countdown: Date? = nil) -> RecorderChip {
            RecorderChip(target: .processing, symbol: symbol, label: label, shortLabel: short, tone: tone, progress: progress, detail: detail ?? label,
                         countdownUntil: countdown)
        }
        switch work {
        case .transcribing(let fraction):
            return chip("quote.bubble", ProcessingWords.progressLine(.transcribing, fraction: fraction), short: fraction.map(ProcessingWords.percentText),
                        .working, progress: fraction)
        case .identifyingSpeakers: return chip("person.2.wave.2", ProcessingWords.progressLine(.identifyingSpeakers, fraction: nil), short: "Speakers…", .working)
        case .summarizing: return chip("text.alignleft", ProcessingWords.progressLine(.summarizing, fraction: nil), short: "Summary…", .working)
        case .elsewhere(let device, let stage, let fraction):
            return chip("desktopcomputer", ProcessingWords.elsewhere(stage, device: device, fraction: fraction),
                        short: fraction.map(ProcessingWords.percentText), .working, progress: fraction)
        case .waiting: return chip("clock", ProcessingWords.waitingHereShort(), short: "Waiting", .calm)
        // Asked for on another device (an iPhone), and waiting for a Mac to take it.
        case .requested(let device): return chip("clock", "Requested from \(device)", short: "Waiting", .calm)
        // A wait, not a problem: the download it waits for in the one phrase every surface uses ("Downloading models ·
        // 40%", over the whole set). Only a download that stopped needs the person.
        case .models(nil): return chip("arrow.down.circle", "Waiting for models", short: "Models", .calm)
        case .models(let models?):
            let text = ProcessingWords.modelDownloadLine(models), short = ProcessingWords.modelDownloadShort(models)
            switch models {
            case .downloading:
                let detail = ProcessingWords.modelDownloadDetail(models).map { "\(text) · \($0)" }
                return chip("arrow.down.circle", text, short: short, .working, progress: models.fraction, detail: detail)
            case .waitingForWiFi: return chip("wifi", text, short: short, .calm)
            case .failed: return chip("exclamationmark.triangle.fill", text, short: short, .attention)
            }
        case .paused: return chip("pause.circle", "Transcription paused", short: "Paused", .calm)
        case .failed(let words): return chip("exclamationmark.triangle.fill", "Couldn’t finish", .attention, detail: words.message)
        case .ready(let summary): return chip("checkmark.circle.fill", summary ? "Summary ready" : "Transcript ready", short: "Ready", .linked)
        // The transcript reads now; the summary follows the summary model, as the menu's first line says.
        case .transcriptReady(let waiting):
            return chip("checkmark.circle.fill", "Transcript ready", short: "Ready", .linked, detail: "Transcript ready · \(waiting)")
        case .awaiting(let line): return chip("clock", line, short: "Waiting", .calm)
        // Where its summary runs (docs/multipoint.md, "Where summaries run"): Use the Cloud and Start Now are in its menu.
        case .summaryCountdown(let until, _):
            let seconds = SummaryPlacementWords.secondsLeft(until: until, at: now)
            return chip("clock", SummaryPlacementWords.countdown(seconds: seconds), short: SummaryPlacementWords.seconds(seconds), .calm,
                        detail: SummaryPlacementWords.countdown(on: AppState.thisDeviceWords, seconds: seconds), countdown: until)
        case .summarizingWith(let model):
            return chip("cloud", SummaryPlacementWords.inCloud(model), short: "Summary…", .working)
        }
    }

    static func queueChip(_ queue: FloatingStatusInputs.Queue, now: Date = Date()) -> RecorderChip? {
        guard let line = queueWords(queue, now: now) else { return nil }
        return RecorderChip(target: .queue, symbol: line.symbol, label: line.text, shortLabel: line.shortText, tone: tone(line.tone),
                            progress: line.progress, detail: line.text, countdownUntil: line.countdownUntil)
    }

    // MARK: Meters

    static func meters(_ inputs: FloatingStatusInputs) -> [RecorderMeter] { RecordingStatusWords.meters(inputs.recording) }

    // MARK: Lines

    /// The home's status lines, like the iPhone's status sheet: each recorder, each iPhone, then this Mac's queue
    /// while there's work, then sync when it's a problem. Their words move with `now` (a countdown, "Last seen").
    static func lines(_ inputs: FloatingStatusInputs, now: Date = Date()) -> [StatusLineWords] {
        var lines = inputs.recording.recorders.map { RecorderStatusWords.line($0, here: AppState.thisDeviceWords, now: now) }
        lines += inputs.recording.peers.map { PeerStatusWords.line(peerFacts($0), now: now) }
        if let queue = queueWords(inputs.queue, now: now) { lines.append(queue) }
        if inputs.syncProblem != nil {
            lines.append(StatusLineWords(id: "sync", symbol: "exclamationmark.icloud", title: "iCloud", text: "Not syncing", tone: .attention))
        }
        return lines
    }

    /// This Mac's queue in the one line both apps use for a device's queue.
    static func queueWords(_ queue: FloatingStatusInputs.Queue, now: Date = Date()) -> StatusLineWords? {
        guard !queue.isEmpty else { return nil }
        let words = QueueStatusWords.Queue(running: queue.running, fraction: queue.running == nil ? nil : queue.fraction, countdown: queue.countdown,
                                           cloudModel: queue.cloudModel, waiting: queue.waiting, awaitingModels: queue.awaitingModels,
                                           models: queue.models)
        return QueueStatusWords.line(words, words: .mac(), now: now)
    }

    /// A line as the shared status line draws it, at a moment.
    static func item(_ line: StatusLineWords, at now: Date) -> StatusLineItem {
        // The short words move with a countdown as the whole ones do.
        var short = line
        short.text = line.shortText ?? line.text
        return StatusLineItem(id: line.id, symbol: line.symbol, title: line.title, text: line.text(at: now), tone: tone(line.tone),
                              progress: line.progress, shortText: line.shortText == nil ? nil : short.text(at: now))
    }

    static func tone(_ tone: StatusLineWords.Tone) -> StatusTone {
        switch tone {
        case .calm: return .calm
        case .working: return .working
        case .linked: return .linked
        case .recording: return .recording
        case .attention: return .attention
        }
    }

    private static func peerFacts(_ peer: RecordingStatusInputs.Peer) -> PeerFacts {
        let activity: PeerFacts.Activity
        switch peer.activity {
        case .idle: activity = .idle
        case .recording: activity = .recording
        case .paused: activity = .paused
        }
        return PeerFacts(id: peer.id, name: peer.name, kind: peer.kind == .iPhone ? .iPhone : .mac, isConnected: peer.isConnected,
                         activity: activity, lastSeen: peer.lastConnected)
    }
}
