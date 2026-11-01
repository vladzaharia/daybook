import DaybookCore
import DaybookDesign
import DaybookDevices
import DaybookKit
import Foundation

// What Floating Notes says about the recording and everything around it (docs/interface.md,
// "Floating Notes"): the status bar's phase and chips, and the home's status lines. Plain values
// from plain inputs, as the iPhone's status sheet does it
// (`StatusSheetModel`), so tests read exactly what each state says and the views only draw it.

/// The facts the panel's status is built from, gathered from the app (`FloatingStatusInputs.make`).
struct FloatingStatusInputs: Equatable {
    enum Phase: Equatable {
        case idle, starting, recording, saving
        /// After a Stop seen in the panel.
        case saved
        /// The recording itself stopped short; nothing reached the conversation.
        case stopped
    }

    /// The call track, while recording.
    enum CallAudio: Equatable {
        /// Computer audio isn't part of this recording (turned off in Settings).
        case off
        /// Captured, but silent for the last few seconds.
        case quiet
        case detected
        /// It should be captured and isn't.
        case missing
    }

    struct Importing: Equatable {
        var position: Int
        var total: Int
        var fraction: Double?
        /// Waiting for the recorder to come back.
        var suspended = false
    }

    /// A recorder with a direct connection (Soundcore over Bluetooth).
    struct Recorder: Equatable {
        var id: String
        var name: String
        /// "Soundcore", for a chip.
        var shortName: String
        var symbol: String
        var state: ConnectionState
        var isLinked = false
        var battery: Int?
        var charging = false
        /// The recorder says it's recording.
        var isRecording = false
        /// Its link to this recording (multipoint), while there is one.
        var along: CompanionRecording.State?
        /// Another device manages it: "Alex’s iPhone".
        var managedBy: String?
        var managedByPhone = false
        var handoff: RecorderHandoff.State = .idle
        /// The handoff in the recorder's words.
        var handoffLine: String?
        var problem: String?
        var newCount = 0
        var importing: Importing?
        var lastConnected: Date?
    }

    /// A paired iPhone running Daybook.
    struct Phone: Equatable {
        enum Activity: Equatable { case idle, recording, paused }
        var id: String
        var name: String
        var isConnected = false
        var activity: Activity = .idle
        /// Its link to this recording (multipoint): recording along, or leading it.
        var along: CompanionRecording.State?
        var lastConnected: Date?
    }

    /// The focused conversation's processing.
    enum Work: Equatable {
        case transcribing(Double?)
        case identifyingSpeakers
        case summarizing
        /// On another Mac: its name, the verb, and how far.
        case elsewhere(device: String, verb: String, fraction: Double?)
        case waiting
        /// Asked for on `device`, waiting for a Mac to take it.
        case requested(device: String)
        case models
        case paused
        case failed(String)
        case ready(summary: Bool)
        /// Done with this Mac's audio; a recording made alongside it hasn't arrived ("Waiting for iPhone audio").
        case awaiting(String)
        /// Its summary starts on this Mac at `until`, unless the person chooses the cloud first (`cloud`: on offer).
        case summaryCountdown(until: Date, cloud: Bool)
        /// Summarizing in the cloud, with this model.
        case summarizingWith(String)
    }

    /// This Mac's queue, for the home.
    struct Queue: Equatable {
        enum Stage: Equatable { case transcribing, identifyingSpeakers, summarizing }
        var running: Stage?
        var fraction: Double = 0
        /// The running job's summary counts down to this Mac until then.
        var countdown: Date?
        /// The running job's summary is in the cloud, with this model.
        var cloudModel: String?
        var waiting = 0
        var awaitingModels = 0
        var isEmpty: Bool { running == nil && waiting == 0 && awaitingModels == 0 }
    }

    var phase: Phase = .idle
    var duration: TimeInterval?
    var inputDevice: String?
    var microphoneSilent = false
    var call: CallAudio = .off
    var recorders: [Recorder] = []
    var phones: [Phone] = []
    var work: Work?
    var queue = Queue()
    var syncProblem: String?
}

/// One item in the status bar: a glyph and a short label that open a menu with the whole sentence.
struct FloatingChip: Identifiable, Equatable {
    enum Target: Equatable {
        /// `processing` is the shown conversation's work; `queue` is this Mac's, whichever conversation it's on.
        case call, recorder(String), phone(String), processing, queue, sync
    }

    var target: Target
    var symbol: String
    /// The label when there's room.
    var label: String
    /// A shorter label for a narrow panel; nil leaves only the glyph.
    var shortLabel: String?
    var tone: StatusTone
    /// The red recording dot after the glyph: this device is recording too.
    var showsDot = false
    /// Work in progress: the gradient line along the chip's foot.
    var progress: Double?
    /// The whole status in a sentence: the menu's first line, the tooltip, and VoiceOver.
    var detail: String
    /// Its short label says as much with its glyph (a paused iPhone's "Paused"), so it shortens
    /// before the other chips give up their names.
    var shortensFirst = false
    /// Keeps its words longest as the bar narrows: what's happening to the conversation, and
    /// anything that needs the person.
    var isProminent: Bool { target == .processing || target == .queue || tone == .attention }

    var id: String {
        switch target {
        case .call: return "call"
        case .recorder(let id): return "recorder-\(id)"
        case .phone(let id): return "phone-\(id)"
        case .processing: return "processing"
        case .queue: return "queue"
        case .sync: return "sync"
        }
    }
}

/// The status bar's leading item: the recording's phase and what it records from.
struct FloatingPhase: Equatable {
    var phase: RecordingPhaseLabel.Phase
    var title: String
    var detail: String?
    var detailIsWarning = false
}

enum FloatingStatus {
    static let microphoneSilentHelp = "Check that your microphone isn’t muted or unplugged."
    static let callMissingHelp = "Call audio isn’t being recorded. Allow Daybook in Privacy & Security › Screen & System Audio Recording."

    // MARK: Phase

    static func phase(_ inputs: FloatingStatusInputs) -> FloatingPhase? {
        switch inputs.phase {
        case .idle: return nil
        case .starting: return FloatingPhase(phase: .starting, title: "Starting")
        case .recording:
            if inputs.microphoneSilent { return FloatingPhase(phase: .recording, title: "Recording", detail: "Microphone silent", detailIsWarning: true) }
            return FloatingPhase(phase: .recording, title: "Recording", detail: inputs.inputDevice)
        case .saving: return FloatingPhase(phase: .saving, title: "Saving…")
        case .saved: return FloatingPhase(phase: .saved, title: "Saved", detail: inputs.duration.map(TimeLabel.short))
        case .stopped: return FloatingPhase(phase: .stopped, title: "Stopped")
        }
    }

    // MARK: Chips

    /// What a status bar includes. The home's full layout lists devices and the queue as lines, so
    /// its bar leaves them out.
    enum ChipKind: CaseIterable { case call, devices, work, queue, sync }

    /// The status bar's chips, in order: the call (while recording), recorders, iPhones, the shown
    /// conversation's processing (once it isn't recording), this Mac's queue, then sync when it's a
    /// problem.
    static func chips(_ inputs: FloatingStatusInputs, including kinds: Set<ChipKind> = Set(ChipKind.allCases),
                      now: Date = Date()) -> [FloatingChip] {
        var chips: [FloatingChip] = []
        let recording = inputs.phase == .recording
        if recording, kinds.contains(.call), let call = callChip(inputs.call) { chips.append(call) }
        if kinds.contains(.devices) {
            chips += inputs.recorders.compactMap { recorderChip($0, recording: recording, now: now) }
            chips += inputs.phones.compactMap { phoneChip($0, recording: recording) }
        }
        if kinds.contains(.work), !recording, let work = inputs.work.flatMap({ workChip($0, now: now) }) { chips.append(work) }
        if kinds.contains(.queue), !recording, let queue = queueChip(inputs.queue, now: now) { chips.append(queue) }
        if kinds.contains(.sync), let problem = inputs.syncProblem {
            chips.append(FloatingChip(target: .sync, symbol: "exclamationmark.icloud", label: "Not syncing", tone: .attention, detail: problem))
        }
        return chips
    }

    static func callChip(_ call: FloatingStatusInputs.CallAudio) -> FloatingChip? {
        switch call {
        case .off: return nil
        case .detected:
            return FloatingChip(target: .call, symbol: "waveform", label: "Call", shortLabel: "Call", tone: .linked, detail: "Call audio detected")
        case .quiet:
            return FloatingChip(target: .call, symbol: "waveform", label: "Call", shortLabel: "Call", tone: .calm,
                                detail: "No call audio in the last few seconds")
        case .missing:
            return FloatingChip(target: .call, symbol: "speaker.slash.fill", label: "No call audio", shortLabel: "Call", tone: .attention,
                                detail: callMissingHelp)
        }
    }

    static func recorderChip(_ recorder: FloatingStatusInputs.Recorder, recording: Bool, now: Date = Date()) -> FloatingChip? {
        func chip(_ label: String, short: String? = nil, _ tone: StatusTone, dot: Bool = false, progress: Double? = nil, detail: String) -> FloatingChip {
            FloatingChip(target: .recorder(recorder.id), symbol: recorder.symbol, label: label, shortLabel: short, tone: tone,
                         showsDot: dot, progress: progress, detail: detail)
        }
        let name = recorder.name
        switch recorder.handoff {
        case .idle: break
        case .done: return chip("On this Mac", .linked, detail: recorder.handoffLine ?? "\(name) is on this Mac now")
        case .refused: return chip("Not handed over", .attention, detail: recorder.handoffLine ?? "\(name) wasn’t handed over")
        default: return chip("Moving…", .working, detail: recorder.handoffLine ?? "Moving \(name)…")
        }
        if let owner = recorder.managedBy {
            return chip("\(recorder.shortName) on \(owner)", short: recorder.managedByPhone ? "On iPhone" : "On Mac", .calm,
                        detail: "\(name) · Managed by \(owner)")
        }
        if recording, let along = recorder.along, [.unavailable, .failed].contains(along) {
            return chip("Not recording", .attention, detail: "\(name) didn’t start recording. Start it on the recorder to record along.")
        }
        if recording, recorder.along == .starting {
            return chip("Starting…", .working, detail: "Starting \(name)…")
        }
        if let problem = recorder.problem, !recorder.isLinked { return chip(problem, .attention, detail: "\(name) · \(problem)") }
        switch recorder.state {
        case .connected:
            let recordingAlong = recorder.isRecording || [.recording, .alreadyRecording].contains(recorder.along)
            var parts = [name, recordingAlong ? (recording ? "Recording along" : "Recording") : "Connected"]
            let battery = recorder.battery.map { "\($0)%" }
            if let battery { parts.append(recorder.charging ? "\(battery), charging" : battery) }
            if recorder.newCount > 0 { parts.append("\(recorder.newCount) new") }
            if let importing = recorder.importing, !importing.suspended {
                return chip("Importing \(importing.position) of \(importing.total)", short: "\(importing.position)/\(importing.total)", .working,
                            progress: importing.fraction, detail: "\(name) · Importing \(importing.position) of \(importing.total)")
            }
            // Short, it keeps its name: a battery level alone doesn't say whose it is.
            return chip(battery.map { "\(recorder.shortName) · \($0)" } ?? recorder.shortName, short: recorder.shortName, .linked, dot: recordingAlong,
                        detail: parts.joined(separator: " · "))
        case .searching, .connecting, .reconnecting:
            return chip(recorder.state == .reconnecting ? "Reconnecting…" : "Connecting…", .working, detail: "\(name) · Connecting…")
        case .unavailable:
            return chip("Unavailable", .attention, detail: "\(name) · \(recorder.problem ?? "Bluetooth isn’t available")")
        case .notConnected:
            let seen = recorder.lastConnected.map { " · Last seen \(DeviceDateFormat.lastSeen($0, now: now))" } ?? ""
            return chip("Not connected", .calm, detail: "\(name) · Not connected\(seen)")
        case .notSetUp:
            return nil
        }
    }

    static func phoneChip(_ phone: FloatingStatusInputs.Phone, recording: Bool) -> FloatingChip? {
        func chip(_ label: String, short: String? = "iPhone", _ tone: StatusTone, dot: Bool = false, shortensFirst: Bool = false,
                  detail: String) -> FloatingChip {
            FloatingChip(target: .phone(phone.id), symbol: "iphone", label: label, shortLabel: short, tone: tone, showsDot: dot, detail: detail,
                         shortensFirst: shortensFirst)
        }
        let name = phone.name
        if recording, let along = phone.along {
            switch along {
            case .recording, .alreadyRecording, .stopping:
                // The chip is where a recording along shows, so a pause names the phone. Short,
                // "Paused" by the phone's glyph still says it, so it gives way first.
                if phone.activity == .paused {
                    return chip("\(name) paused", short: "Paused", .attention, shortensFirst: true, detail: "\(name) paused. This Mac keeps recording.")
                }
                return chip(name, .linked, dot: true, detail: "\(name) is recording too")
            case .starting:
                return chip("Starting…", short: nil, .working, detail: "Asking \(name) to record too…")
            case .unavailable, .failed:
                return chip("Not recording", short: nil, .attention, detail: "\(name) didn’t start recording")
            case .stopped, .stopFailed, .attached:
                break
            }
        }
        guard phone.isConnected else { return nil }
        switch phone.activity {
        case .recording: return chip(name, .linked, dot: true, detail: "\(name) is recording")
        case .paused: return chip("\(name) paused", short: "Paused", .calm, shortensFirst: true, detail: "\(name) paused its recording")
        case .idle: return chip(name, short: nil, .linked, detail: "\(name) · Connected")
        }
    }

    static func workChip(_ work: FloatingStatusInputs.Work, now: Date = Date()) -> FloatingChip? {
        func chip(_ symbol: String, _ label: String, short: String? = nil, _ tone: StatusTone, progress: Double? = nil, detail: String? = nil) -> FloatingChip {
            FloatingChip(target: .processing, symbol: symbol, label: label, shortLabel: short, tone: tone, progress: progress, detail: detail ?? label)
        }
        switch work {
        case .transcribing(let fraction):
            let percent = fraction.map { " · \(Int(($0 * 100).rounded(.down)))%" } ?? ""
            return chip("quote.bubble", "Transcribing\(percent)", short: fraction.map { "\(Int(($0 * 100).rounded(.down)))%" }, .working,
                        progress: fraction)
        case .identifyingSpeakers: return chip("person.2.wave.2", "Identifying speakers…", short: "Speakers…", .working)
        case .summarizing: return chip("text.alignleft", "Summarizing…", short: "Summary…", .working)
        case .elsewhere(let device, let verb, let fraction):
            let percent = fraction.map { " · \(Int(($0 * 100).rounded(.down)))%" } ?? ""
            return chip("desktopcomputer", "\(verb) on \(device)\(percent)", short: fraction.map { "\(Int(($0 * 100).rounded(.down)))%" }, .working,
                        progress: fraction)
        case .waiting: return chip("clock", "Waiting to transcribe", short: "Waiting", .calm)
        // Asked for on another device (an iPhone), and waiting for a Mac to take it.
        case .requested(let device): return chip("clock", "Requested from \(device)", short: "Waiting", .calm)
        case .models:
            return chip("arrow.down.circle", "Waiting for models", short: "Models", .attention)
        case .paused: return chip("pause.circle", "Transcription paused", short: "Paused", .calm)
        case .failed(let reason): return chip("exclamationmark.triangle.fill", "Couldn’t finish", .attention, detail: reason.isEmpty ? "Couldn’t finish" : reason)
        case .ready(let summary): return chip("checkmark.circle.fill", summary ? "Summary ready" : "Transcript ready", short: "Ready", .linked)
        case .awaiting(let line): return chip("clock", line, short: "Waiting", .calm)
        // Where its summary runs (docs/multipoint.md, "Where summaries run"): Use the Cloud and Start Now are in its menu.
        case .summaryCountdown(let until, _):
            let seconds = max(1, Int(until.timeIntervalSince(now).rounded(.up)))
            return chip("clock", "Summarizing in \(seconds) s", short: "\(seconds) s", .calm,
                        detail: "Summarizing on \(AppState.thisDeviceWords) in \(seconds) s")
        case .summarizingWith(let model):
            return chip("cloud", "Summarizing with \(model)", short: "Summary…", .working)
        }
    }

    static func queueChip(_ queue: FloatingStatusInputs.Queue, now: Date = Date()) -> FloatingChip? {
        guard let line = queueLine(queue, now: now) else { return nil }
        return FloatingChip(target: .queue, symbol: "desktopcomputer", label: line.text, shortLabel: line.shortText, tone: line.tone,
                            progress: line.progress, detail: line.text)
    }

    // MARK: Lines

    /// The home's status lines, like the iPhone's status sheet: each recorder, each iPhone, then
    /// this Mac's queue while there's work, then sync when it's a problem.
    static func lines(_ inputs: FloatingStatusInputs, now: Date = Date()) -> [StatusLineItem] {
        var lines = inputs.recorders.compactMap { recorderLine($0, now: now) }
        lines += inputs.phones.map { phoneLine($0, now: now) }
        if let queue = queueLine(inputs.queue, now: now) { lines.append(queue) }
        if inputs.syncProblem != nil {
            lines.append(StatusLineItem(id: "sync", symbol: "exclamationmark.icloud", title: "iCloud", text: "Not syncing", tone: .attention))
        }
        return lines
    }

    static func recorderLine(_ recorder: FloatingStatusInputs.Recorder, now: Date = Date()) -> StatusLineItem? {
        func line(_ text: String, _ tone: StatusTone, progress: Double? = nil, short: String? = nil) -> StatusLineItem {
            StatusLineItem(id: "recorder-\(recorder.id)", symbol: recorder.symbol, title: recorder.name, text: text, tone: tone,
                           progress: progress, shortText: short)
        }
        switch recorder.handoff {
        case .idle: break
        case .done: return line("On this Mac now", .linked)
        case .refused(let by, _): return line("\(by) didn’t hand it over", .attention)
        default: return line(recorder.handoffLine ?? "Moving…", .working, short: "Moving…")
        }
        if let owner = recorder.managedBy { return line("Managed by \(owner)", .calm) }
        if let importing = recorder.importing {
            if importing.suspended {
                return line(importing.total == 1 ? "1 recording waits to import" : "\(importing.total) recordings wait to import", .calm)
            }
            return line("Importing \(importing.position) of \(importing.total)", .working, progress: importing.fraction)
        }
        if let problem = recorder.problem, !recorder.isLinked { return line(problem, .attention) }
        switch recorder.state {
        case .connected:
            var parts = [recorder.isRecording ? "Recording" : "Connected"]
            if let level = recorder.battery { parts.append(recorder.charging ? "\(level)%, charging" : "\(level)%") }
            if recorder.newCount > 0 { parts.append("\(recorder.newCount) new") }
            return line(parts.joined(separator: " · "), recorder.isRecording ? .recording : .linked)
        case .searching, .connecting, .reconnecting:
            return line(recorder.state == .reconnecting ? "Reconnecting…" : "Connecting…", .working)
        case .unavailable:
            return line(recorder.problem ?? "Bluetooth isn’t available", .attention)
        case .notSetUp:
            return nil
        case .notConnected:
            var parts: [String] = []
            if recorder.newCount > 0 { parts.append("\(recorder.newCount) new") }
            if let last = recorder.lastConnected { parts.append("Last seen \(DeviceDateFormat.lastSeen(last, now: now))") }
            return line(parts.isEmpty ? "Not connected" : parts.joined(separator: " · "), .calm, short: parts.isEmpty ? nil : "Not connected")
        }
    }

    static func phoneLine(_ phone: FloatingStatusInputs.Phone, now: Date = Date()) -> StatusLineItem {
        func line(_ text: String, _ tone: StatusTone, short: String? = nil) -> StatusLineItem {
            StatusLineItem(id: "phone-\(phone.id)", symbol: "iphone", title: phone.name, text: text, tone: tone, shortText: short)
        }
        guard phone.isConnected else {
            let seen = phone.lastConnected.map { " · Last seen \(DeviceDateFormat.lastSeen($0, now: now))" } ?? ""
            return line("Not connected\(seen)", .calm, short: "Not connected")
        }
        switch phone.activity {
        case .recording: return line("Recording", .recording)
        case .paused: return line("Paused", .calm)
        case .idle: return line("Connected", .linked)
        }
    }

    static func queueLine(_ queue: FloatingStatusInputs.Queue, now: Date = Date()) -> StatusLineItem? {
        guard !queue.isEmpty else { return nil }
        func line(_ text: String, _ tone: StatusTone, progress: Double? = nil, short: String? = nil) -> StatusLineItem {
            StatusLineItem(id: "queue", symbol: "desktopcomputer", title: "This Mac", text: text, tone: tone, progress: progress, shortText: short)
        }
        let waiting = queue.waiting > 0 ? " · \(queue.waiting) waiting" : ""
        if let until = queue.countdown {
            let seconds = max(1, Int(until.timeIntervalSince(now).rounded(.up)))
            return line("Summarizing in \(seconds) s\(waiting)", .calm, short: "Summarizing in \(seconds) s")
        }
        if let model = queue.cloudModel { return line("Summarizing with \(model)\(waiting)", .working, short: "Summarizing…") }
        switch queue.running {
        case .transcribing?:
            let percent = Int((queue.fraction * 100).rounded(.down))
            return line("Transcribing · \(percent)%\(waiting)", .working, progress: queue.fraction, short: "Transcribing · \(percent)%")
        case .identifyingSpeakers?: return line("Identifying speakers…\(waiting)", .working, short: "Identifying speakers…")
        case .summarizing?: return line("Summarizing…\(waiting)", .working, short: "Summarizing…")
        case nil:
            if queue.waiting > 0 { return line("\(queue.waiting) waiting to transcribe", .calm, short: "\(queue.waiting) waiting") }
            return line("Waiting for models", .attention)
        }
    }
}
