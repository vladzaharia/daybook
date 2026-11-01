import DaybookKit
import Foundation

/// What the status sheet says (docs/iphone.md, "Status sheet"): the recorder, your Mac, and sync,
/// one line each when compact; then at most three groups, a card each: recorders, Macs, and (large)
/// this iPhone. Plain values built from plain inputs, so tests read exactly what each state says,
/// and the views only draw them.
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
    /// "Transcribing on Studio Mac · 40%", "Waiting", "Studio Mac couldn’t finish".
    var line: String
    /// Asked for on this iPhone ("Requested from this iPhone").
    var requestedHere: Bool
    var progress: Double?
    var isRunning: Bool
    var failed = false
    /// Its Mac's work is done, and a recording made alongside hasn't arrived ("Waiting for Soundcore
    /// Work audio"): it waits for that recording, not for the Mac.
    var awaitsRecording = false
    /// For a failure: what it means, in plain words ("Something went wrong on Studio Mac. The recording is saved.").
    var detail: String?
    /// For a failure: the Mac's own words, shown only behind Details.
    var details: String?
    /// The Mac doing the work (or that failed), when known.
    var mac: String?
    /// The line without the Mac's name ("Transcribing · 40%", "Couldn’t finish"), for under that Mac's row.
    var brief: String?

    /// The line under a Mac's row in the Macs card: that Mac isn't named again.
    func line(under macName: String?) -> String {
        guard let mac, mac == macName, let brief else { return line }
        return brief
    }
}

/// What the sheet shows, top to bottom; each detent adds to the one before. Below the lines, each
/// group is a heading and one card, and each device is in one card only.
enum StatusSection: Hashable, Sendable {
    /// Record, Import, and Search (the pocket sheet hosts them).
    case quickActions
    /// The three lines.
    case lines
    /// Live listening captions, while a recorder streams.
    case captions
    /// A card per recorder: its status and handoff ("Use on This iPhone" / "Use on Studio Mac"); large
    /// adds its storage, its actions, and the recordings waiting on it. Add Recorder… when there's none.
    case recorders
    /// One card: every paired Mac, the queue under the Mac doing it, and Pair with Your Mac….
    case macs
    /// The audio kept on this iPhone, and Storage.
    case iphone
}

/// What a recorder's card offers at the large detent: only what can be done now, never a disabled button.
enum StatusRecorderAction: Hashable, Sendable {
    case connect
    case record
    case pause
    case importNew(Int)
    /// Connected, but the recorder didn't list its recordings: what's new isn't known (Check for New).
    case checkForNew
    case listenLive
    case stopListening
}

/// A Mac in the Macs card.
struct StatusMacRow: Equatable, Identifiable, Sendable {
    enum ID: Hashable, Sendable {
        /// Paired over Wi‑Fi: the row opens its details.
        case paired(UUID)
        /// Known only by its presence in the library (it syncs, but isn't paired with this iPhone).
        case synced(String)
    }

    var id: ID
    var name: String
    var text: String
    var isConnected: Bool
    /// The transcription queue shows under this row.
    var showsQueue = false
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
        /// What it was last known to be doing, when it isn't live here: "Recording since 10:02, as of 10:14"
        /// (from the Mac that manages it, or its last state here).
        var lastKnown: String?
        var handoff: RecorderHandoff.State = .idle
        var isRecording = false
        var isListeningLive = false
        /// The problem's title, when there is one.
        var problem: String?
        var lastConnected: Date?
        var storageHours: Double?
        var storageIsLow = false
        /// It can start and pause recording (Record on Soundcore).
        var hasRecordControl = false
        /// It can stream what it hears (Listen Live).
        var hasLiveListening = false
        /// It isn't linked and Connect would do something now.
        var canConnect = false
        /// A recording is coming off it right now (not just queued).
        var importRunning = false
        /// Connected, but it didn't list its recordings (it didn't answer, or refused): the new ones shown
        /// are from its remembered list.
        var notListed = false
        /// An import or a Start waits for another app's transfer: "Waiting for the Soundcore app to finish".
        var otherAppWait: String?
    }

    /// A Mac paired over Wi‑Fi.
    struct Mac: Equatable {
        var id: UUID
        var name: String
        /// "Connected", "Recording now", "Last connected 3 days ago".
        var line: String
        var isConnected: Bool
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
    var pairedMacs: [Mac] = []
}

enum StatusSheetModel {
    // MARK: Sections

    /// What each detent shows. Compact: the lines (with Record and Import when the sheet hosts them).
    /// Medium adds live captions while a recorder streams (first: they're what's happening now), the
    /// recorders with handoff, and the Macs with the queue. Large adds this iPhone; the recorder cards
    /// grow their storage, actions, and waiting recordings (`showsManagement`).
    static func sections(for detent: StatusDetent, _ inputs: StatusInputs) -> [StatusSection] {
        var sections: [StatusSection] = inputs.hostsRecordButton ? [.quickActions, .lines] : [.lines]
        guard detent != .compact else { return sections }
        if inputs.hasLiveCaptions { sections.append(.captions) }
        sections += [.recorders, .macs]
        if detent == .large { sections.append(.iphone) }
        return sections
    }

    /// Whether the recorder cards show storage, actions, and waiting recordings.
    static func showsManagement(_ detent: StatusDetent) -> Bool { detent == .large }

    // MARK: A recorder's card

    /// The recorder's actions, in order: Connect, Record or Pause, Import N New, Listen Live or Stop
    /// Listening. A recorder another device manages, or one without Bluetooth, has none here.
    static func actions(for recorder: StatusInputs.Recorder) -> [StatusRecorderAction] {
        guard recorder.isDirect, recorder.managedBy == nil else { return [] }
        var actions: [StatusRecorderAction] = []
        if !recorder.isLinked, recorder.canConnect { actions.append(.connect) }
        if recorder.hasRecordControl, recorder.isLinked, !recorder.importRunning {
            actions.append(recorder.isRecording ? .pause : .record)
        }
        if recorder.newCount > 0, recorder.importing == nil { actions.append(.importNew(recorder.newCount)) }
        if recorder.notListed, recorder.isLinked, recorder.importing == nil { actions.append(.checkForNew) }
        if recorder.hasLiveListening {
            if recorder.isListeningLive {
                actions.append(.stopListening)
            } else if recorder.isRecording, recorder.isLinked, !recorder.importRunning {
                actions.append(.listenLive)
            }
        }
        return actions
    }

    /// "About 2,170 hours left": the recorder's room, on its card at the large detent.
    static func storageLeft(hours: Double) -> String {
        if hours < 1 { return "Less than an hour left" }
        let rounded = StorageFormat.roundedHours(hours)
        return rounded == 1 ? "About 1 hour left" : "About \(rounded.formatted()) hours left"
    }

    // MARK: The Macs card

    /// Every paired Mac, then a Mac the library syncs with that isn't paired here (by its presence).
    /// The queue goes under the Mac that does the work: the connected one, else the one presence names.
    static func macRows(_ inputs: StatusInputs, now: Date = Date()) -> [StatusMacRow] {
        var rows = inputs.pairedMacs.map { StatusMacRow(id: .paired($0.id), name: $0.name, text: $0.line, isConnected: $0.isConnected) }
        if let name = inputs.mac.macName, !rows.contains(where: { $0.name == name }), let text = presenceText(inputs.mac, now: now) {
            rows.append(StatusMacRow(id: .synced(name), name: name, text: text, isConnected: false))
        }
        if let index = rows.firstIndex(where: \.isConnected) ?? rows.firstIndex(where: { $0.name == inputs.mac.macName }) {
            rows[index].showsQueue = true
        }
        return rows
    }

    /// A synced Mac's row, from its presence.
    static func presenceText(_ presence: MacPresence, now: Date = Date()) -> String? {
        switch presence {
        case .connected: return "Connected"
        case .seen(_, let date): return "Last seen \(MacPresence.age(now.timeIntervalSince(date)))"
        case .recording: return "Recording"
        case .notProcessing: return "Not set up to transcribe"
        default: return nil
        }
    }

    // MARK: This iPhone

    /// The audio kept on this iPhone, as Settings › Storage's row says it: downloads and recordings
    /// made here together, so not "downloaded".
    static func audioOnThisIPhone(bytes: UInt64) -> String {
        bytes == 0 ? "No audio on this iPhone" : "\(ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)) of audio"
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
        if let owner = recorder.managedBy {
            return line(recorder.lastKnown.map { "Managed by \(owner) · \($0)" } ?? "Managed by \(owner)", .calm)
        }
        if recorder.isListeningLive { return line("Listening live", .recording) }
        if let wait = recorder.otherAppWait { return line(wait, .working, short: "Waiting…") }
        if let importing = recorder.importing {
            if importing.suspended {
                return line(importing.total == 1 ? "1 recording waits to import" : "\(importing.total) recordings wait to import", .calm)
            }
            return line("Importing \(importing.position) of \(importing.total)", .working, progress: importing.fraction)
        }
        if let problem = recorder.problem, !recorder.isLinked { return line(problem, .attention) }
        switch recorder.state {
        case .connected where recorder.isDirect || recorder.isLinked:
            let state = recorder.isRecording ? "Recording" : "Connected"
            let battery = recorder.batteryLevel.map { recorder.batteryCharging ? "\($0)%, charging" : "\($0)%" }
            let new = recorder.newCount > 0 ? "\(recorder.newCount) new" : nil
            let parts = [state, battery, new].compactMap { $0 }
            // Narrow (the notebook's panel), it keeps what matters: a battery level or new recordings
            // already say it's connected; while recording, the word and the battery.
            let short = recorder.isRecording ? [state, battery].compactMap { $0 } : [battery, new].compactMap { $0 }
            return line(parts.joined(separator: " · "), recorder.isRecording ? .recording : .linked,
                        short: short.isEmpty || short == parts ? nil : short.joined(separator: " · "))
        case .connected:
            return line(recorder.newCount > 0 ? "\(recorder.newCount) new in its folder" : "Watching its folder", .calm)
        case .searching, .connecting, .reconnecting:
            return line(recorder.state == .reconnecting ? "Reconnecting…" : "Connecting…", .working)
        case .unavailable:
            return line(recorder.problem ?? "Bluetooth isn’t available", .attention)
        case .notSetUp:
            return line("Not set up", .calm)
        case .notConnected:
            var parts: [String] = recorder.lastKnown.map { [$0] } ?? []
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
        let waiting = inputs.queue.filter { !$0.isRunning && !$0.failed && !$0.awaitsRecording }.count
        let waitingText = waiting == 0 ? nil : "\(waiting) waiting"
        if let live = inputs.liveProgress.first(where: { !$0.isFinished }) ?? inputs.liveProgress.first(where: { $0.phase == .failed }) {
            if live.phase == .failed {
                return StatusLine(kind: .mac, symbol: "desktopcomputer", title: live.macName, text: "Couldn’t finish", tone: .attention)
            }
            var text = live.activity
            if let fraction = live.fraction, [.transcribing, .identifyingSpeakers, .summarizing, .aligning].contains(live.phase) {
                text += " · \(Int((fraction * 100).rounded(.down)))%"
            }
            return StatusLine(kind: .mac, symbol: "desktopcomputer", title: live.macName, text: text, tone: .working, progress: live.fraction,
                              shortText: text == live.activity ? nil : live.activity)
        }
        if let running = inputs.queue.first(where: \.isRunning) {
            // Coarse progress from the claim that synced.
            let verb = running.line.components(separatedBy: " on ").first ?? "Transcribing"
            let percent = running.progress.map { " · \(Int(($0 * 100).rounded(.down)))%" } ?? ""
            return StatusLine(kind: .mac, symbol: "desktopcomputer", title: inputs.mac.macName ?? "Your Mac", text: verb + percent,
                              tone: .working, progress: running.progress, shortText: percent.isEmpty ? nil : verb)
        }
        switch inputs.mac {
        case .connected(let name):
            // Narrow, the waiting work stays: the teal glyph already says it's connected.
            return StatusLine(kind: .mac, symbol: "desktopcomputer", title: name,
                              text: ["Connected", waitingText].compactMap { $0 }.joined(separator: " · "), tone: .linked,
                              shortText: waitingText)
        case .seen(let name, let date):
            let seen = "Last seen \(MacPresence.age(now.timeIntervalSince(date)))"
            return StatusLine(kind: .mac, symbol: "desktopcomputer", title: name,
                              text: [seen, waitingText].compactMap { $0 }.joined(separator: " · "), tone: .calm)
        case .recording(let name, _):
            return StatusLine(kind: .mac, symbol: "desktopcomputer", title: name,
                              text: ["Recording", waitingText].compactMap { $0 }.joined(separator: " · "), tone: .recording,
                              shortText: waitingText == nil ? nil : "Recording")
        case .notProcessing(let name, _):
            return StatusLine(kind: .mac, symbol: "desktopcomputer", title: name, text: "Not set up to transcribe", tone: .attention)
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
    /// synced claims, then requests waiting (oldest first), then conversations waiting for a recording
    /// made alongside (oldest first), then failures. At most `limit`.
    static func queue(meetings: [Meeting], liveProgress: [UUID: LiveProgress], thisDevice: String,
                      now: Date = Date(), limit: Int = 6) -> [StatusQueueEntry] {
        var running: [StatusQueueEntry] = [], waiting: [(Date, StatusQueueEntry)] = [], failed: [StatusQueueEntry] = []
        var awaiting: [(Date, StatusQueueEntry)] = []
        for meeting in meetings {
            let requestedHere = meeting.openProcessingRequests.contains { $0.requestedBy.id == thisDevice }
            if let live = liveProgress[meeting.id], !live.isFinished {
                running.append(StatusQueueEntry(id: meeting.id, title: meeting.title, line: live.line, requestedHere: requestedHere,
                                                progress: live.fraction, isRunning: true, mac: live.macName, brief: live.brief))
                continue
            }
            switch ProcessingStatus(meeting, now: now) {
            case .processing(let progress) where progress.device?.id == thisDevice:
                // This iPhone's own work (docs/iphone.md, "Processing on this iPhone"), not a Mac's.
                break
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
                                                requestedHere: requestedHere, progress: progress.fraction, isRunning: true,
                                                mac: progress.device?.name, brief: verb + percent))
            case .requested(.device(let request)):
                waiting.append((request.createdAt, StatusQueueEntry(id: meeting.id, title: meeting.title, line: "Waiting",
                                                                    requestedHere: request.requestedBy.id == thisDevice,
                                                                    progress: nil, isRunning: false)))
            case .awaitingRecordings(let recordings):
                awaiting.append((recordings.map(\.since).min() ?? now,
                                 StatusQueueEntry(id: meeting.id, title: meeting.title, line: ProcessingStatus.awaitingLine(recordings),
                                                  requestedHere: false, progress: nil, isRunning: false, awaitsRecording: true)))
            case .failed(let failure):
                // As the page says it: plain words here, the Mac's own behind Details.
                let silent = FriendlyError.isNoSpeech(failure.reason)
                let line = silent ? "No speech in this recording" : failure.device.map { "\($0.name) couldn’t finish" } ?? "Couldn’t finish"
                let detail = silent ? "The audio is saved." : FriendlyError.message(for: failure.reason, device: failure.device?.name)
                failed.append(StatusQueueEntry(id: meeting.id, title: meeting.title, line: line, requestedHere: requestedHere,
                                               progress: nil, isRunning: false, failed: true, detail: detail,
                                               details: failure.reason.isEmpty ? nil : failure.reason,
                                               mac: silent ? nil : failure.device?.name, brief: silent ? nil : "Couldn’t finish"))
            default:
                break
            }
        }
        let ordered = running + waiting.sorted { $0.0 < $1.0 }.map(\.1) + awaiting.sorted { $0.0 < $1.0 }.map(\.1) + failed
        return Array(ordered.prefix(limit))
    }
}
