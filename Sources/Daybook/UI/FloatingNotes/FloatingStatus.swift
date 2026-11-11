import DaybookCore
import DaybookDesign
import DaybookDevices
import DaybookKit
import DaybookUI
import Foundation

// What Floating Notes says about the recording and everything around it (docs/interface.md, "Floating Notes"): the
// status bar's phase and chips, and the home's status lines. The recording's words are the ones the iPhone's
// recorder says too (DaybookUI's `RecordingStatusWords`); the home's lines are the status overview both apps draw
// (DaybookKit's `StatusOverviewModel`, the iPhone's status sheet's lines), and the shown conversation's chip says what
// its list row does (`ConversationStatusPresentation.row`). Plain values from plain inputs, so tests read exactly what
// each state says and the views only draw it.

/// The facts the panel's status is built from (`FloatingStatusInputs.make`): the overview both apps draw, gathered on
/// this Mac (`StatusOverviewInputs.make`: the recording with its recorders and iPhones, this Mac's queue, iCloud), and
/// the conversation the panel shows.
struct FloatingStatusInputs: Equatable {
    /// The shown conversation once it isn't recording, in the words both apps use for it: its processing, and what its
    /// list row says about it.
    struct Conversation: Equatable {
        var status: ProcessingStatus
        /// What its row says (`ConversationStatusPresentation.row`): the chip's words, figure, and countdown.
        var row: ConversationRowStatus?
        /// Its work is done: its summary is ready (true), or its transcript (false). Nil while neither is.
        var ready: Bool?
        /// What its summary waits for once the transcript is ready, as the page says it ("Waiting to summarize after the
        /// download · 38%").
        var summaryWaits: String?
    }

    var overview = StatusOverviewInputs(words: .mac())
    var conversation: Conversation?
    /// What needs the person about sync, in a sentence for the chip's menu (the overview's line says "Not syncing").
    var syncProblem: String?

    /// The recording, its recorders, and the iPhones: what both recorders say.
    var recording: RecordingStatusInputs {
        get { overview.recording }
        set { overview.recording = newValue }
    }

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
        if kinds.contains(.work), !recording,
           let work = inputs.conversation.flatMap({ workChip($0, words: inputs.overview.words, models: inputs.overview.local.models, now: now) }) {
            chips.append(work)
        }
        if kinds.contains(.queue), !recording, let queue = queueChip(inputs.overview, now: now) { chips.append(queue) }
        if kinds.contains(.sync), let problem = inputs.syncProblem {
            chips.append(RecorderChip(target: .sync, symbol: "exclamationmark.icloud", label: "Not syncing", tone: .attention, detail: problem))
        }
        return chips
    }

    /// The shown conversation's chip: what its list row says (`ConversationStatusPresentation.row`), with the step's
    /// glyph, the download it waits for (`models`, this Mac's), a failure's sentence in its menu, or, once the work is
    /// done, what's ready. A recording not transcribed yet has none: nothing is happening to it.
    static func workChip(_ conversation: FloatingStatusInputs.Conversation, words: DeviceWords, models: ModelDownloadState?,
                         now: Date = Date()) -> RecorderChip? {
        func chip(_ symbol: String, _ label: String, short: String? = nil, _ tone: StatusTone, progress: Double? = nil, detail: String? = nil,
                  countdown: Date? = nil) -> RecorderChip {
            RecorderChip(target: .processing, symbol: symbol, label: label, shortLabel: short, tone: tone, progress: progress, detail: detail ?? label,
                         countdownUntil: countdown)
        }
        guard let row = conversation.row, let text = row.text else {
            // The transcript reads now; the summary follows the summary model, as the menu's first line says.
            guard let summary = conversation.ready else { return nil }
            if summary { return chip("checkmark.circle.fill", "Summary ready", short: "Ready", .linked) }
            return chip("checkmark.circle.fill", "Transcript ready", short: "Ready", .linked,
                        detail: conversation.summaryWaits.map { "Transcript ready · \($0)" })
        }
        switch row.kind {
        case .processing:
            guard case .processing(let progress) = conversation.status else {
                // Not this Mac's queue at work: where its summary runs said so, in the cloud with its model named.
                return chip("cloud", text, short: "Summary…", .working)
            }
            let elsewhere = progress.device.map { $0.id != words.thisDeviceID } ?? false
            let symbol: String
            let short: String?
            switch progress.stage {
            case .transcribing: (symbol, short) = ("quote.bubble", nil)
            case .identifyingSpeakers: (symbol, short) = ("person.2.wave.2", "Speakers…")
            case .summarizing: (symbol, short) = ("text.alignleft", "Summary…")
            }
            return chip(elsewhere ? "desktopcomputer" : symbol, text, short: progress.fraction.map(ProcessingWords.percentText) ?? (elsewhere ? nil : short),
                        .working, progress: progress.fraction)
        case .waiting:
            // Where its summary runs (docs/multipoint.md, "Where summaries run"): Use the Cloud and Start Now are in its menu.
            if let until = row.countdownUntil {
                let seconds = SummaryPlacementWords.secondsLeft(until: until, at: now)
                return chip("clock", text, short: SummaryPlacementWords.seconds(seconds), .calm,
                            detail: SummaryPlacementWords.countdown(on: words.here, seconds: seconds), countdown: until)
            }
            return chip("clock", text, short: "Waiting", .calm)
        case .waitingForModels:
            // A wait, not a problem: the download it waits for in the one phrase every surface uses ("Downloading models ·
            // 40%", over the whole set). Only a download that stopped needs the person.
            guard let models else { return chip("arrow.down.circle", text, short: "Models", .calm) }
            let line = ProcessingWords.modelDownloadLine(models), short = ProcessingWords.modelDownloadShort(models)
            switch models {
            case .downloading:
                let detail = ProcessingWords.modelDownloadDetail(models).map { "\(line) · \($0)" }
                return chip("arrow.down.circle", line, short: short, .working, progress: models.fraction, detail: detail)
            case .waitingForWiFi: return chip("wifi", line, short: short, .calm)
            case .failed: return chip("exclamationmark.triangle.fill", line, short: short, .attention)
            }
        case .paused:
            return chip("pause.circle", text, short: "Paused", .calm)
        case .failed:
            // Couldn't finish, in the words both apps use for the failure.
            guard case .failed(let failure) = conversation.status else { return chip("exclamationmark.triangle.fill", text, .attention) }
            return chip("exclamationmark.triangle.fill", text, .attention, detail: FailureWords(failure, words: words).message)
        case .notTranscribed, .recording, .playing, .justFinished:
            return nil
        }
    }

    /// This Mac's queue, in the line the home and the iPhone's sheet use for a device's own work.
    static func queueChip(_ overview: StatusOverviewInputs, now: Date = Date()) -> RecorderChip? {
        guard let line = StatusOverviewModel.localLine(overview, now: now) else { return nil }
        return RecorderChip(target: .queue, symbol: line.symbol, label: line.text, shortLabel: line.shortText, tone: StatusTone(line.tone),
                            progress: line.progress, detail: line.text, countdownUntil: line.countdownUntil)
    }

    // MARK: Meters

    static func meters(_ inputs: FloatingStatusInputs) -> [RecorderMeter] { RecordingStatusWords.meters(inputs.recording) }
}
