import DaybookKit
import Foundation

/// What the status sheet says (docs/iphone.md, "Status sheet"): the recorder, your Mac, and sync,
/// one line each when compact; devices with handoff, the Mac's queue, and live captions at medium;
/// full management when large. Plain values built from plain inputs, so tests read exactly what
/// each state says, and the views only draw them.
enum StatusDetent: String, CaseIterable, Sendable {
    case compact, medium, large
}

/// One line of the compact sheet.
struct StatusLine: Equatable, Identifiable, Sendable {
    enum Kind: String, Sendable { case recorder, mac, sync }

    /// Which ink the line uses (docs/interface.md, "Colour has a job").
    enum Tone: Equatable, Sendable {
        /// Fine; nothing to say beyond the fact. Secondary ink.
        case calm
        /// Work in progress: the brand gradient line when there's a fraction.
        case working
        /// A recorder or Mac connected now: teal.
        case linked
        /// The recorder is recording right now: the red dot.
        case recording
        /// Needs the person: orange.
        case attention
    }

    var kind: Kind
    var symbol: String
    var title: String
    var text: String
    var tone: Tone
    /// 0...1 for work in progress.
    var progress: Double?
    /// A shorter way to say it, when `text` doesn't fit on one line.
    var shortText: String?

    var id: String { kind.rawValue }
    var accessibilityLabel: String { "\(title), \(text)" }
}

/// A conversation in the Mac's processing queue, as the phone knows it.
struct StatusQueueEntry: Equatable, Identifiable, Sendable {
    var id: UUID
    var title: String
    /// "Transcribing on Studio Mac · 40%", "Waiting", "Studio Mac couldn’t finish: …".
    var line: String
    /// Asked for on this iPhone ("Requested from this iPhone").
    var requestedHere: Bool
    var progress: Double?
    var isRunning: Bool
    var failed = false
}

/// What the sheet shows, top to bottom; each detent adds to the one before.
enum StatusSection: Hashable, Sendable {
    /// Record, Import, and Search (the pocket sheet hosts them).
    case quickActions
    /// The three lines.
    case lines
    /// Live listening captions, while a recorder streams.
    case captions
    /// Every recorder, with "Use on This iPhone" / "Use on Studio Mac" and handoff progress.
    case recorders
    /// The Mac: presence and its queue.
    case mac
    /// Import now, record on the recorder, Listen Live.
    case controls
    /// Recordings waiting on a recorder.
    case waiting
    /// The recorder's space and this iPhone's downloaded audio.
    case storage
    /// Macs paired over Wi‑Fi.
    case pairing
}

/// The facts the sheet is built from, gathered by the view from the app model.
struct StatusInputs: Equatable {
    struct Importing: Equatable {
        var position: Int
        var total: Int
        var fraction: Double?
        /// Waiting for the recorder to reconnect.
        var suspended = false
    }

    struct Recorder: Equatable {
        var id: String
        var name: String
        var shortName: String
        /// It has a direct method (Bluetooth): battery, handoff, controls.
        var isDirect: Bool
        var state: ConnectionState
        var isLinked: Bool
        var batteryLevel: Int?
        var batteryCharging = false
        var newCount = 0
        var importing: Importing?
        /// Another device manages it.
        var managedBy: String?
        var handoff: RecorderHandoff.State = .idle
        var isRecording = false
        var isListeningLive = false
        /// The problem's title, when there is one.
        var problem: String?
        var lastConnected: Date?
        var storageHours: Double?
        var storageIsLow = false
    }

    enum SyncTone: Equatable { case upToDate, working, attention, checking }

    var recorders: [Recorder] = []
    var mac: MacPresence = .checking
    /// Live progress over the link, newest first.
    var liveProgress: [LiveProgress] = []
    var queue: [StatusQueueEntry] = []
    var syncLine = "Checking iCloud…"
    var syncTone: SyncTone = .checking
    var hostsRecordButton = false
    var hasLiveCaptions = false
    var pairedMacs = 0
}

enum StatusSheetModel {
    // MARK: Sections

    /// What each detent shows. Compact: the lines (with Record and Import when the sheet hosts them).
    /// Medium adds live captions while a recorder streams (first: they're what's happening now),
    /// devices with handoff, and the Mac with its queue. Large adds full management.
    static func sections(for detent: StatusDetent, _ inputs: StatusInputs) -> [StatusSection] {
        var sections: [StatusSection] = inputs.hostsRecordButton ? [.quickActions, .lines] : [.lines]
        guard detent != .compact else { return sections }
        if inputs.hasLiveCaptions { sections.append(.captions) }
        sections += [.recorders, .mac]
        guard detent == .large else { return sections }
        if inputs.recorders.contains(where: { $0.isDirect && $0.managedBy == nil }) { sections.append(.controls) }
        if inputs.recorders.contains(where: { $0.newCount > 0 && $0.managedBy == nil }) { sections.append(.waiting) }
        sections += [.storage, .pairing]
        return sections
    }

    // MARK: Lines

    static func lines(_ inputs: StatusInputs, now: Date = Date()) -> [StatusLine] {
        [recorderLine(primaryRecorder(inputs.recorders), now: now), macLine(inputs, now: now), syncLine(inputs)]
    }

    /// The recorder the compact line is about: one that's doing something, else the first with Bluetooth.
    static func primaryRecorder(_ recorders: [StatusInputs.Recorder]) -> StatusInputs.Recorder? {
        recorders.first { $0.handoff != .idle || $0.importing != nil || $0.isListeningLive }
            ?? recorders.first { $0.isLinked } ?? recorders.first { $0.isDirect } ?? recorders.first
    }

    static func recorderLine(_ recorder: StatusInputs.Recorder?, now: Date = Date()) -> StatusLine {
        guard let recorder else {
            return StatusLine(kind: .recorder, symbol: "waveform.badge.microphone", title: "Recorder",
                              text: "None added", tone: .calm)
        }
        let symbol = "waveform.badge.microphone"
        func line(_ text: String, _ tone: StatusLine.Tone, progress: Double? = nil, short: String? = nil) -> StatusLine {
            StatusLine(kind: .recorder, symbol: symbol, title: recorder.name, text: text, tone: tone, progress: progress, shortText: short)
        }
        switch recorder.handoff {
        case .idle: break
        case .done:
            return line("On this iPhone now", .linked)
        case .refused(let by, _):
            return line("\(by) didn’t hand it over", .attention)
        default:
            if let headline = RecorderHandoff.Words.headline(recorder.handoff, recorder: recorder.name, here: "this iPhone") {
                return line(Self.handoffLine(recorder.handoff, headline: headline), .working, short: Self.shortHandoff(recorder.handoff))
            }
        }
        if let owner = recorder.managedBy { return line("Managed by \(owner)", .calm) }
        if recorder.isListeningLive { return line("Listening live", .recording) }
        if let importing = recorder.importing {
            if importing.suspended {
                return line(importing.total == 1 ? "1 recording waits to import" : "\(importing.total) recordings wait to import", .calm)
            }
            return line("Importing \(importing.position) of \(importing.total)", .working, progress: importing.fraction)
        }
        if let problem = recorder.problem, !recorder.isLinked { return line(problem, .attention) }
        switch recorder.state {
        case .connected where recorder.isDirect || recorder.isLinked:
            var parts = [recorder.isRecording ? "Recording" : "Connected"]
            if let level = recorder.batteryLevel { parts.append(recorder.batteryCharging ? "\(level)%, charging" : "\(level)%") }
            if recorder.newCount > 0 { parts.append("\(recorder.newCount) new") }
            return line(parts.joined(separator: " · "), recorder.isRecording ? .recording : .linked)
        case .connected:
            return line(recorder.newCount > 0 ? "\(recorder.newCount) new in its folder" : "Watching its folder", .calm)
        case .searching, .connecting, .reconnecting:
            return line(recorder.state == .reconnecting ? "Reconnecting…" : "Connecting…", .working)
        case .unavailable:
            return line(recorder.problem ?? "Bluetooth isn’t available", .attention)
        case .notSetUp:
            return line("Not set up", .calm)
        case .notConnected:
            var parts: [String] = []
            if recorder.newCount > 0 { parts.append("\(recorder.newCount) new") }
            if let last = recorder.lastConnected { parts.append("Last seen \(DeviceDateFormat.lastSeen(last, now: now))") }
            return line(parts.isEmpty ? "Not connected" : parts.joined(separator: " · "), .calm)
        }
    }

    /// A handoff on the recorder's line (its name is the line's title, so it isn't repeated).
    private static func handoffLine(_ state: RecorderHandoff.State, headline: String) -> String {
        switch state {
        case .asking(let owner): return "Asking \(owner) to let go…"
        case .ownerFinishing(let owner, .importing?): return "\(owner) finishes an import, then lets go"
        case .ownerFinishing(let owner, _): return "\(owner) is letting go…"
        case .waitingForSync(let owner, _): return "Waiting for \(owner) to let go…"
        case .connecting: return "Connecting…"
        case .handingOver(let to, _): return "Moving to \(to)…"
        case .offering(let to): return "Asking \(to) to take it…"
        default: return headline
        }
    }

    /// The same, when the line is too narrow for it.
    private static func shortHandoff(_ state: RecorderHandoff.State) -> String? {
        switch state {
        case .asking(let owner): return "Asking \(owner)…"
        case .ownerFinishing(_, .importing?): return "Moving here after an import"
        case .ownerFinishing: return "Moving here…"
        case .waitingForSync(let owner, _): return "Waiting for \(owner)…"
        case .offering(let to): return "Offering to \(to)…"
        default: return nil
        }
    }

    static func macLine(_ inputs: StatusInputs, now: Date = Date()) -> StatusLine {
        let waiting = inputs.queue.filter { !$0.isRunning && !$0.failed }.count
        let waitingText = waiting == 0 ? nil : "\(waiting) waiting"
        if let live = inputs.liveProgress.first(where: { !$0.isFinished }) ?? inputs.liveProgress.first(where: { $0.phase == .failed }) {
            if live.phase == .failed {
                return StatusLine(kind: .mac, symbol: "desktopcomputer", title: live.macName, text: "Couldn’t finish", tone: .attention)
            }
            var text = live.activity
            if let fraction = live.fraction, [.transcribing, .identifyingSpeakers, .summarizing, .aligning].contains(live.phase) {
                text += " · \(Int((fraction * 100).rounded(.down)))%"
            }
            return StatusLine(kind: .mac, symbol: "desktopcomputer", title: live.macName, text: text, tone: .working, progress: live.fraction)
        }
        if let running = inputs.queue.first(where: \.isRunning) {
            // Coarse progress from the claim that synced.
            let verb = running.line.components(separatedBy: " on ").first ?? "Transcribing"
            let percent = running.progress.map { " · \(Int(($0 * 100).rounded(.down)))%" } ?? ""
            return StatusLine(kind: .mac, symbol: "desktopcomputer", title: inputs.mac.macName ?? "Your Mac", text: verb + percent,
                              tone: .working, progress: running.progress)
        }
        switch inputs.mac {
        case .connected(let name):
            return StatusLine(kind: .mac, symbol: "desktopcomputer", title: name,
                              text: ["Connected", waitingText].compactMap { $0 }.joined(separator: " · "), tone: .linked)
        case .seen(let name, let date):
            let seen = "Last seen \(MacPresence.age(now.timeIntervalSince(date)))"
            return StatusLine(kind: .mac, symbol: "desktopcomputer", title: name,
                              text: [seen, waitingText].compactMap { $0 }.joined(separator: " · "), tone: .calm)
        case .olderMac:
            return StatusLine(kind: .mac, symbol: "desktopcomputer", title: "Your Mac", text: "Syncs with an earlier Daybook", tone: .calm)
        case .noMac:
            return StatusLine(kind: .mac, symbol: "desktopcomputer", title: "Your Mac", text: "Hasn’t synced this library yet", tone: .calm)
        case .unavailable:
            return StatusLine(kind: .mac, symbol: "desktopcomputer", title: "Your Mac", text: "Waiting for iCloud", tone: .calm)
        case .checking:
            return StatusLine(kind: .mac, symbol: "desktopcomputer", title: "Your Mac", text: "Looking for it…", tone: .calm)
        }
    }

    static func syncLine(_ inputs: StatusInputs) -> StatusLine {
        let tone: StatusLine.Tone
        switch inputs.syncTone {
        case .upToDate, .checking: tone = .calm
        case .working: tone = .working
        case .attention: tone = .attention
        }
        return StatusLine(kind: .sync, symbol: inputs.syncTone == .attention ? "exclamationmark.icloud" : "icloud",
                          title: "iCloud", text: inputs.syncLine, tone: tone)
    }

    // MARK: The Mac's queue

    /// Conversations a Mac is working on or will, as this iPhone knows: live progress first, then the
    /// synced claims, then requests waiting (oldest first), then failures. At most `limit`.
    static func queue(meetings: [Meeting], liveProgress: [UUID: LiveProgress], thisDevice: String,
                      now: Date = Date(), limit: Int = 6) -> [StatusQueueEntry] {
        var running: [StatusQueueEntry] = [], waiting: [(Date, StatusQueueEntry)] = [], failed: [StatusQueueEntry] = []
        for meeting in meetings {
            let requestedHere = meeting.openProcessingRequests.contains { $0.requestedBy.id == thisDevice }
            if let live = liveProgress[meeting.id], !live.isFinished {
                running.append(StatusQueueEntry(id: meeting.id, title: meeting.title, line: live.line, requestedHere: requestedHere,
                                                progress: live.fraction, isRunning: true))
                continue
            }
            switch ProcessingStatus(meeting, now: now) {
            case .processing(let progress):
                let verb: String
                switch progress.stage {
                case .transcribing: verb = "Transcribing"
                case .identifyingSpeakers: verb = "Identifying speakers"
                case .summarizing: verb = "Summarizing"
                }
                let percent = progress.fraction.map { " · \(Int(($0 * 100).rounded(.down)))%" } ?? ""
                running.append(StatusQueueEntry(id: meeting.id, title: meeting.title,
                                                line: "\(verb) on \(progress.device?.name ?? "your Mac")\(percent)",
                                                requestedHere: requestedHere, progress: progress.fraction, isRunning: true))
            case .requested(.device(let request)):
                waiting.append((request.createdAt, StatusQueueEntry(id: meeting.id, title: meeting.title, line: "Waiting",
                                                                    requestedHere: request.requestedBy.id == thisDevice,
                                                                    progress: nil, isRunning: false)))
            case .failed(let failure):
                let line = failure.device.map { "\($0.name) couldn’t finish: \(failure.reason)" } ?? "Couldn’t finish: \(failure.reason)"
                failed.append(StatusQueueEntry(id: meeting.id, title: meeting.title, line: line, requestedHere: requestedHere,
                                               progress: nil, isRunning: false, failed: true))
            default:
                break
            }
        }
        let ordered = running + waiting.sorted { $0.0 < $1.0 }.map(\.1) + failed
        return Array(ordered.prefix(limit))
    }
}
