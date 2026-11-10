import DaybookDesign
import DaybookKit
import DaybookUI
import Foundation

/// What the status sheet says (docs/iphone.md, "Status sheet"): the recorder, your Mac, this iPhone
/// while it has work, and sync, one line each when compact; then a group each, a card each: recorders,
/// Macs, and this iPhone. Plain values built from plain inputs, so tests read exactly what each state
/// says, and the views only draw them, with the overview both apps share (DaybookUI's `StatusOverview`).
enum StatusDetent: String, CaseIterable, Sendable {
    case compact, medium, large

    /// How deep the overview goes at this size: lines, then cards, then cards with what can be done.
    var density: StatusDensity {
        switch self {
        case .compact: return .lines
        case .medium: return .cards
        case .large: return .manage
        }
    }
}

/// What tapping a compact line does: a line that needs the person goes to where it's fixed; the rest
/// show more.
enum StatusLineRoute: Equatable {
    case showMore
    /// More of the sheet, at the group that says what to do (the Macs card, for a Mac).
    case showFix(StatusSection)
    case open(SettingsRoute)
}

/// A conversation in a processing queue, as the phone knows it: a Mac's (the Macs card) or this
/// iPhone's own (the This iPhone card).
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
    /// What the person can choose for its summary here (docs/multipoint.md, "Where summaries run").
    var actions: [SummaryPlacementPlanner.Action] = []
    /// Its summary's countdown runs out then, where `countdownPlace` says ("on Studio Mac", "on this iPhone").
    var countdownUntil: Date?
    var countdownPlace: String?
    /// A failure Try Again asks again for, as the page's box does.
    var retry: ProcessingRequest.Mode?

    /// The line under a Mac's row in the Macs card: that Mac isn't named again.
    func line(under macName: String?) -> String { line(under: macName, at: Date()) }

    /// The same at a moment: a countdown's seconds move with it.
    func line(under macName: String?, at now: Date) -> String {
        if let until = countdownUntil {
            let seconds = max(1, Int(until.timeIntervalSince(now).rounded(.up)))
            // A countdown in its own card (this iPhone's) names no place: its line ticks as it is.
            guard let place = countdownPlace else {
                return line.replacingOccurrences(of: #"in \d+ s"#, with: "in \(seconds) s", options: .regularExpression)
            }
            return mac != nil && mac == macName ? "Summarizing in \(seconds) s" : "Summarizing \(place) in \(seconds) s"
        }
        guard let mac, mac == macName, let brief else { return line }
        return brief
    }

    /// The row both apps draw for it, under `macName`'s row (or at the top of its card, with nil).
    func item(under macName: String?, now: Date = Date()) -> StatusQueueItem {
        var actions = self.actions.map(StatusQueueItem.Action.placement)
        if let retry { actions.insert(.tryAgain(retry), at: 0) }
        return StatusQueueItem(id: id, title: title, line: line(under: macName, at: now),
                               note: requestedHere && !failed ? "Requested from this iPhone" : nil,
                               progress: isRunning ? progress : nil, isProblem: failed, detail: detail, details: details,
                               countdownUntil: countdownUntil, actions: actions)
    }
}

/// What the sheet shows, top to bottom; each detent adds to the one before. Below the lines, each
/// group is a heading and one card, and each device is in one card only.
enum StatusSection: Hashable, Sendable {
    /// Record, Import, and Search (the pocket sheet hosts them).
    case quickActions
    /// The lines: recorder, Mac, this iPhone while it has work, and iCloud.
    case lines
    /// Live listening captions, while a recorder streams.
    case captions
    /// A card per recorder: its status and handoff ("Use on This iPhone" / "Use on Studio Mac"); large
    /// adds its storage, its actions, and the recordings waiting on it. Add Recorder… when there's none.
    case recorders
    /// One card: every paired Mac, the queue under the Mac doing it, and Pair with Your Mac….
    case macs
    /// This iPhone's own queue while it has work, and (large) the audio kept on it, opening Storage.
    case iphone
}

/// What a recorder's card offers at the large detent: what its page offers (`RecorderActions`), only what can be done
/// now, never a disabled button.
typealias StatusRecorderAction = RecorderAction

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
    /// It needs the person: its text in warning ink, with `fix` under it.
    var needsYou = false
    /// What to do, in one sentence: "Finish in Daybook › Settings on Studio Mac."
    var fix: String?
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
        /// The kind's glyph (`DeviceKind.systemImage`).
        var symbol = "recordingtape"
        /// A Record or Pause sent to it hasn't been confirmed yet.
        var recordCommandPending = false
        /// It was last seen recording then, while it isn't connected.
        var recordingAsOf: Date?
        /// Its recordings arrive in a folder.
        var folder: RecorderFacts.Folder?
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
        /// A recording coming over the recorder's own Wi‑Fi, which leaving Daybook starts again over Bluetooth.
        var fastTransfer: FastTransferStage?
    }

    /// A Mac paired over Wi‑Fi.
    struct Mac: Equatable {
        var id: UUID
        var name: String
        /// "Connected", "Recording now", "Last seen today, 9:12 AM".
        var line: String
        var isConnected: Bool
        /// Connected, and it said it doesn't transcribe: it isn't set up yet.
        var notProcessing = false
    }

    enum SyncTone: Equatable { case upToDate, working, attention, checking }

    var recorders: [Recorder] = []
    var mac: MacPresence = .checking
    /// Live progress over the link, newest first.
    var liveProgress: [LiveProgress] = []
    var queue: [StatusQueueEntry] = []
    /// This iPhone's own work (docs/iphone.md, "Processing on this iPhone"): its line, and its queue's rows.
    var phone = QueueStatusWords.Queue()
    var phoneQueue: [StatusQueueEntry] = []
    var syncLine = SyncStatus.connecting.shortText
    /// The sync line when it's too long for its row: "Off" for a reason that keeps iCloud from being used.
    var syncShort: String?
    var syncTone: SyncTone = .checking
    /// iCloud can't be used here (signed out, iCloud Drive off): the crossed-out cloud.
    var syncOff = false
    var hostsRecordButton = false
    var hasLiveCaptions = false
    var pairedMacs: [Mac] = []

    /// This iPhone has work: running, waiting, paused, or a summary counting down to it.
    var phoneHasWork: Bool { !phone.isEmpty || !phoneQueue.isEmpty }
}

enum StatusSheetModel {
    // MARK: Sections

    /// What each detent shows. Compact: the lines (with Record and Import when the sheet hosts them).
    /// Medium adds live captions while a recorder streams (first: they're what's happening now), the
    /// recorders with handoff, the Macs with their queue, and this iPhone while it has work of its own.
    /// Large always adds this iPhone (its storage); the recorder cards grow their storage, actions, and
    /// waiting recordings (`showsManagement`).
    static func sections(for detent: StatusDetent, _ inputs: StatusInputs) -> [StatusSection] {
        var sections: [StatusSection] = inputs.hostsRecordButton ? [.quickActions, .lines] : [.lines]
        guard detent != .compact else { return sections }
        if inputs.hasLiveCaptions { sections.append(.captions) }
        sections += [.recorders, .macs]
        if detent == .large || inputs.phoneHasWork { sections.append(.iphone) }
        return sections
    }

    /// Whether the recorder cards show storage, actions, and waiting recordings.
    static func showsManagement(_ detent: StatusDetent) -> Bool { detent == .large }

    // MARK: A recorder's card

    /// The recorder's actions, the ones its page offers (`RecorderActions`), in order: Connect, Record or Pause,
    /// Import N New, Check for New, Listen Live or Stop Listening. A recorder another device manages, one without
    /// Bluetooth, or one on its way between devices has none here.
    static func actions(for recorder: StatusInputs.Recorder) -> [StatusRecorderAction] {
        RecorderActions.available(recorder.actionFacts)
    }

    /// "About 2,170 hours left": the recorder's room, on its card at the large detent.
    static func storageLeft(hours: Double) -> String {
        if hours < 1 { return "Less than an hour left" }
        let rounded = StorageFormat.roundedHours(hours)
        return rounded == 1 ? "About 1 hour left" : "About \(rounded.formatted()) hours left"
    }

    // MARK: The Macs card

    /// What a Mac that doesn't transcribe yet needs, in one sentence: "Finish in Daybook › Settings on Studio Mac."
    static func notProcessingFix(_ name: String) -> String { "Finish in Daybook › Settings on \(name)." }

    /// Every paired Mac, then a Mac the library syncs with that isn't paired here (by its presence).
    /// The queue goes under the Mac that does the work: the connected one, else the one presence names.
    /// A Mac that isn't set up to transcribe says so in warning ink, with what to do under it.
    static func macRows(_ inputs: StatusInputs, now: Date = Date()) -> [StatusMacRow] {
        let notSetUp: String? = { if case .notProcessing(let name, _) = inputs.mac { return name } else { return nil } }()
        var rows = inputs.pairedMacs.map { mac in
            var row = StatusMacRow(id: .paired(mac.id), name: mac.name, text: mac.line, isConnected: mac.isConnected)
            if mac.notProcessing || mac.name == notSetUp { row.isNotSetUp() }
            return row
        }
        if let name = inputs.mac.macName, !rows.contains(where: { $0.name == name }), let text = presenceText(inputs.mac, now: now) {
            var row = StatusMacRow(id: .synced(name), name: name, text: text, isConnected: false)
            if name == notSetUp { row.isNotSetUp() }
            rows.append(row)
        }
        if let index = rows.firstIndex(where: \.isConnected) ?? rows.firstIndex(where: { $0.name == inputs.mac.macName }) {
            rows[index].showsQueue = true
        }
        return rows
    }

    /// A synced Mac's row, from its presence, dated as every device's absence is ("Last seen today, 9:12 AM").
    static func presenceText(_ presence: MacPresence, now: Date = Date()) -> String? {
        switch presence {
        case .connected: return "Connected"
        case .seen(_, let date): return RecorderStatusWords.lastSeen(date, now: now)
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

    /// "This iPhone  Transcribing · 40% · 1 waiting", "This iPhone  Paused · Continues when iPhone is charging": this
    /// iPhone's own work in the words a Mac's home uses for its own (`QueueStatusWords`). Nil while it has none, as
    /// the Mac's line is.
    static func phoneLine(_ inputs: StatusInputs, now: Date = Date()) -> StatusLineItem? {
        QueueStatusWords.line(inputs.phone, words: .iPhone(), now: now).map(StatusLineItem.init)
    }

    // MARK: Lines

    static let noRecorderID = "recorder"
    static let macID = "mac"
    static let syncID = "sync"

    /// The lines, in order: the recorder, your Mac, this iPhone while it has work, and iCloud. The recorder,
    /// Mac, and iCloud lines always show, fine or not: the compact sheet is the one place that says the three
    /// things a recording here depends on, at a height that doesn't move Record under the thumb.
    static func lines(_ inputs: StatusInputs, now: Date = Date()) -> [StatusLineItem] {
        var lines = [recorderLine(primaryRecorder(inputs.recorders), now: now), macLine(inputs, now: now)]
        if let phone = phoneLine(inputs, now: now) { lines.append(phone) }
        lines.append(syncLine(inputs))
        return lines
    }

    /// The compact lines: every line; at the accessibility sizes, the one that matters most (`mostPressing`), so the
    /// compact sheet stays the Record row and a line and the list above it stays usable. The rest are a tap away.
    static func compactLines(_ lines: [StatusLineItem], accessibilitySize: Bool) -> [StatusLineItem] {
        guard accessibilitySize, let line = mostPressing(lines) else { return lines }
        return [line]
    }

    /// The line that matters most: what needs the person, then what's recording, then work under way or counting
    /// down, then what's connected, then the rest; among equals the first, and "None added" last.
    static func mostPressing(_ lines: [StatusLineItem]) -> StatusLineItem? {
        func rank(_ line: StatusLineItem) -> Int {
            if line.id == noRecorderID { return 0 }
            switch line.tone {
            case .attention: return 5
            case .recording: return 4
            case .working: return 3
            case .linked: return 2
            case .calm: return line.countdownUntil == nil ? 1 : 3
            }
        }
        var best: StatusLineItem?
        for line in lines where best.map({ rank(line) > rank($0) }) ?? true { best = line }
        return best
    }

    /// Where a line leads when it's tapped. A line that needs the person goes to where it's fixed: iCloud's to
    /// Settings › iCloud, a recorder's to its page, a Mac's to the Macs card, which says what to do for a Mac
    /// that isn't set up to transcribe (paired here or not) and lists what it couldn't finish. Every other line
    /// shows more of the sheet.
    static func route(for line: StatusLineItem, _ inputs: StatusInputs) -> StatusLineRoute {
        guard line.tone == .attention else { return .showMore }
        if line.id == syncID { return .open(.icloud) }
        if line.id == macID { return .showFix(.macs) }
        if line.id.hasPrefix("recorder-") { return .open(.device(String(line.id.dropFirst("recorder-".count)))) }
        return .showMore
    }

    /// What VoiceOver says tapping a line does.
    static func hint(for route: StatusLineRoute) -> String {
        switch route {
        case .showMore: return "Shows more"
        case .open(.icloud): return "Opens iCloud settings"
        case .showFix, .open: return "Shows how to fix it"
        }
    }

    /// The recorder the compact line is about: one that's doing something, else the first with Bluetooth.
    static func primaryRecorder(_ recorders: [StatusInputs.Recorder]) -> StatusInputs.Recorder? {
        recorders.first { $0.handoff != .idle || $0.importing != nil || $0.isListeningLive }
            ?? recorders.first { $0.isLinked } ?? recorders.first { $0.isDirect } ?? recorders.first
    }

    /// The recorder's line in the words both apps give a recorder (`RecorderStatusWords`); "None added" with none.
    static func recorderLine(_ recorder: StatusInputs.Recorder?, now: Date = Date()) -> StatusLineItem {
        guard let recorder else {
            return StatusLineItem(id: noRecorderID, symbol: "recordingtape", title: "Recorder", text: "None added", tone: .calm)
        }
        return StatusLineItem(RecorderStatusWords.line(recorder.facts, here: PhoneSummaryPlacement.thisDeviceWords, now: now))
    }

    static func macLine(_ inputs: StatusInputs, now: Date = Date()) -> StatusLineItem {
        func line(_ title: String, _ text: String, _ tone: StatusTone, progress: Double? = nil, short: String? = nil,
                  countdown: Date? = nil) -> StatusLineItem {
            StatusLineItem(id: macID, symbol: "desktopcomputer", title: title, text: text, tone: tone, progress: progress, shortText: short,
                           countdownUntil: countdown)
        }
        let waiting = inputs.queue.filter { !$0.isRunning && !$0.failed && !$0.awaitsRecording }.count
        let waitingText = waiting == 0 ? nil : "\(waiting) waiting"
        if let live = inputs.liveProgress.first(where: { !$0.isFinished }) ?? inputs.liveProgress.first(where: { $0.phase == .failed }) {
            if live.phase == .failed { return line(live.macName, "Couldn’t finish", .attention) }
            if live.isCountingDown {
                // The Mac counts down to summarizing a conversation: "Summarizing in 12 s", ticking. Waiting
                // isn't progress, so it's calm, as the Mac's own line for it is.
                return line(live.macName, live.brief(at: now), .calm, countdown: live.countdownUntil)
            }
            var text = live.activity
            if let fraction = live.fraction, [.transcribing, .identifyingSpeakers, .summarizing, .aligning].contains(live.phase) {
                text += " · \(ProcessingWords.percentText(fraction))"
            }
            return line(live.macName, text, .working, progress: live.fraction, short: text == live.activity ? nil : live.activity)
        }
        // This iPhone's own countdown (to summarizing here) is this iPhone's line, not a Mac's.
        if let running = inputs.queue.first(where: { $0.isRunning && ($0.countdownUntil == nil || $0.mac != nil) }) {
            if let until = running.countdownUntil, let mac = running.mac {
                // Counting down to sending it to that Mac.
                return line(mac, "Summarizing in \(max(1, Int(until.timeIntervalSince(now).rounded(.up)))) s", .calm, countdown: until)
            }
            // Coarse progress from the claim that synced.
            let verb = running.line.components(separatedBy: " on ").first ?? "Transcribing"
            let percent = running.progress.map { " · \(ProcessingWords.percentText($0))" } ?? ""
            return line(running.mac ?? inputs.mac.macName ?? "Your Mac", verb + percent, .working, progress: running.progress,
                        short: percent.isEmpty ? nil : verb)
        }
        switch inputs.mac {
        case .connected(let name):
            // Narrow, the waiting work stays: the teal glyph already says it's connected.
            return line(name, ["Connected", waitingText].compactMap { $0 }.joined(separator: " · "), .linked, short: waitingText)
        case .seen(let name, let date):
            return line(name, [RecorderStatusWords.lastSeen(date, now: now), waitingText].compactMap { $0 }.joined(separator: " · "), .calm,
                        short: waitingText)
        case .recording(let name, _):
            return line(name, ["Recording", waitingText].compactMap { $0 }.joined(separator: " · "), .recording,
                        short: waitingText == nil ? nil : "Recording")
        case .notProcessing(let name, _):
            return line(name, "Not set up to transcribe", .attention, short: "Not set up")
        case .olderMac:
            return line("Your Mac", "Syncs with an earlier Daybook", .calm)
        case .noMac:
            return line("Your Mac", "Hasn’t synced this library yet", .calm)
        case .unavailable:
            // The iCloud line below says why; this one says what the Mac waits on, without promising it'll come.
            return line("Your Mac", "Needs iCloud", .calm)
        case .checking:
            return line("Your Mac", "Looking for it…", .calm)
        }
    }

    static func syncLine(_ inputs: StatusInputs) -> StatusLineItem {
        let tone: StatusTone
        switch inputs.syncTone {
        case .upToDate, .checking: tone = .calm
        case .working: tone = .working
        case .attention: tone = .attention
        }
        let symbol = inputs.syncOff ? "icloud.slash" : inputs.syncTone == .attention ? "exclamationmark.icloud" : "icloud"
        return StatusLineItem(id: syncID, symbol: symbol, title: "iCloud", text: inputs.syncLine, tone: tone, shortText: inputs.syncShort)
    }

    /// iCloud's line when it can't be used, from the reason sync gave: the reason in a few words, as Settings'
    /// iCloud row says it (`SyncStatus.shortText`). Its narrow form is "Off" (`syncShort`).
    static func unavailablePhrase(_ reason: String) -> String {
        switch reason {
        case CloudAvailability.signedOutMessage: return SyncStatus.signedOut.shortText
        case CloudAvailability.iCloudDriveOffMessage: return SyncStatus.iCloudDriveOff.shortText
        case CloudAvailability.unsetMessage: return SyncStatus.unavailableInThisBuild.shortText
        default: return SyncStatus.iCloudUnavailable(details: nil).shortText
        }
    }

    // MARK: The queues

    /// How long a conversation that couldn't finish stays in the status sheet's queues. Its row and page keep
    /// saying it, with Try Again, for as long as it's so.
    static let failureShownFor: TimeInterval = 7 * 86_400

    /// A failure worth listing in a queue: recent, and not "No speech in this recording", which no device can do
    /// anything about (its row and page say it).
    static func listsFailure(_ failure: ProcessingStatus.Failure, meeting: Meeting, now: Date) -> Bool {
        guard !failure.isNoSpeech else { return false }
        let when = failure.request?.outcome?.finishedAt ?? meeting.updatedAt
        return now.timeIntervalSince(when) < failureShownFor
    }

    /// A failure's queue entry: its plain sentence (`FailureWords`, ending "The recording is saved."), the device's
    /// own words behind Details, and Try Again with what it asked for, as the page offers.
    static func failureEntry(_ failure: ProcessingStatus.Failure, meeting: Meeting, thisDevice: String) -> StatusQueueEntry {
        let words = FailureWords(failure, words: .iPhone(id: thisDevice))
        let here = failure.device?.id == thisDevice
        return StatusQueueEntry(id: meeting.id, title: meeting.title,
                                line: here ? "Couldn’t finish" : failure.device.map { "\($0.name) couldn’t finish" } ?? "Couldn’t finish",
                                requestedHere: false, progress: nil, isRunning: false, failed: true, detail: words.message,
                                details: failure.reason.isEmpty ? nil : failure.reason, mac: here ? nil : failure.device?.name,
                                brief: "Couldn’t finish", retry: meeting.tracks.isEmpty ? nil : failure.request?.mode ?? .newAudio)
    }

    /// Conversations a Mac is working on or will, as this iPhone knows: live progress first, then the
    /// synced claims, then requests waiting (oldest first), then conversations waiting for a recording
    /// made alongside (oldest first), then what couldn't finish lately. At most `limit`. This iPhone's own
    /// work is in `phoneWork`.
    ///
    /// Where a summary runs comes first for its conversation (docs/multipoint.md, "Where summaries run"): this
    /// iPhone's countdown to a Mac or wait for one (`planners`), a Mac's countdown, and, with the cloud on offer,
    /// Use the Cloud for a Summarize request still waiting for a Mac.
    static func queue(meetings: [Meeting], liveProgress: [UUID: LiveProgress], thisDevice: String,
                      planners: [UUID: SummaryPlacementPlanner] = [:], runs: [UUID: SummaryPlace] = [:], cloudOffered: Bool = false,
                      now: Date = Date(), limit: Int = 6) -> [StatusQueueEntry] {
        var running: [StatusQueueEntry] = [], waiting: [(Date, StatusQueueEntry)] = [], failed: [StatusQueueEntry] = []
        var awaiting: [(Date, StatusQueueEntry)] = []
        for meeting in meetings {
            let requestedHere = meeting.openProcessingRequests.contains { $0.requestedBy.id == thisDevice }
            // A summary running here or in the cloud is this iPhone's own.
            if runs[meeting.id] != nil { continue }
            if let planner = planners[meeting.id], let line = planner.line(at: now, thisDevice: PhoneSummaryPlacement.thisDeviceWords) {
                switch planner.phase {
                case .countingDown(.thisDevice, _), .started(.cloud), .started(.thisDevice): continue
                default: break
                }
                var entry = StatusQueueEntry(id: meeting.id, title: meeting.title, line: line, requestedHere: false, progress: nil,
                                             isRunning: false, actions: planner.actions, countdownUntil: planner.deadline)
                if case .countingDown(let place, _) = planner.phase {
                    entry.countdownPlace = SummaryPlacementPlanner.where(place, thisDevice: PhoneSummaryPlacement.thisDeviceWords)
                    if case .mac(_, let name) = place { entry.mac = name }
                }
                running.append(entry)
                continue
            }
            if let live = liveProgress[meeting.id], !live.isFinished {
                running.append(StatusQueueEntry(id: meeting.id, title: meeting.title, line: live.line(at: now), requestedHere: requestedHere,
                                                progress: live.isCountingDown ? nil : live.fraction, isRunning: true, mac: live.macName,
                                                brief: live.brief(at: now), actions: live.placementActions, countdownUntil: live.countdownUntil,
                                                countdownPlace: live.isCountingDown ? "on \(live.macName)" : nil))
                continue
            }
            switch ProcessingStatus(meeting, now: now) {
            case .processing(let progress) where progress.device == nil || progress.device?.id == thisDevice:
                // This iPhone's own work (docs/iphone.md, "Processing on this iPhone"): its own card.
                break
            case .processing(let progress):
                let verb = ProcessingWords.verb(progress.stage)
                let percent = progress.fraction.map { " · \(ProcessingWords.percentText($0))" } ?? ""
                running.append(StatusQueueEntry(id: meeting.id, title: meeting.title,
                                                line: "\(verb) on \(progress.device?.name ?? "your Mac")\(percent)",
                                                requestedHere: requestedHere, progress: progress.fraction, isRunning: true,
                                                mac: progress.device?.name, brief: verb + percent))
            case .requested(.device(let request)):
                // A summary waiting for a Mac can go to the cloud instead.
                let cloud = cloudOffered && request.mode == .summaryOnly
                waiting.append((request.createdAt, StatusQueueEntry(id: meeting.id, title: meeting.title,
                                                                    line: cloud ? "Waiting for a Mac to summarize" : "Waiting",
                                                                    requestedHere: request.requestedBy.id == thisDevice,
                                                                    progress: nil, isRunning: false, actions: cloud ? [.useCloud] : [])))
            case .awaitingRecordings(let recordings):
                awaiting.append((recordings.map(\.since).min() ?? now,
                                 StatusQueueEntry(id: meeting.id, title: meeting.title, line: ProcessingStatus.awaitingLine(recordings),
                                                  requestedHere: false, progress: nil, isRunning: false, awaitsRecording: true)))
            case .failed(let failure) where failure.device?.id != thisDevice && listsFailure(failure, meeting: meeting, now: now):
                // As the page says it: plain words here, the Mac's own behind Details, and Try Again.
                failed.append(failureEntry(failure, meeting: meeting, thisDevice: thisDevice))
            default:
                break
            }
        }
        let ordered = running + waiting.sorted { $0.0 < $1.0 }.map(\.1) + awaiting.sorted { $0.0 < $1.0 }.map(\.1) + failed
        return Array(ordered.prefix(limit))
    }

    /// This iPhone's own work (docs/iphone.md, "Processing on this iPhone"): its line's facts, and its card's rows.
    struct PhoneWork: Equatable {
        var line = QueueStatusWords.Queue()
        var entries: [StatusQueueEntry] = []
    }

    /// What this iPhone is doing with its own recordings, from its processor's queue (`local`, `pause`) and where
    /// its summaries run: what runs here, a summary counting down to this iPhone or running here or in the cloud,
    /// what waits its turn, what's paused and until when, and what couldn't finish here lately. In that order, at
    /// most `limit` rows.
    static func phoneWork(meetings: [Meeting], local: (Meeting) -> ProcessingStatus.LocalQueue?, pause: ProcessingWords.PauseReason?,
                          thisDevice: String, planners: [UUID: SummaryPlacementPlanner] = [:], runs: [UUID: SummaryPlace] = [:],
                          now: Date = Date(), limit: Int = 6) -> PhoneWork {
        var work = PhoneWork()
        var running: [StatusQueueEntry] = [], counting: [StatusQueueEntry] = [], waiting: [(Date, StatusQueueEntry)] = []
        var paused: [StatusQueueEntry] = [], failed: [StatusQueueEntry] = []
        let pausedLine = ["Paused", pause.flatMap { ProcessingWords.pausedLine($0) }].compactMap { $0 }.joined(separator: " · ")
        for meeting in meetings {
            func entry(_ line: String, running: Bool = false, progress: Double? = nil) -> StatusQueueEntry {
                StatusQueueEntry(id: meeting.id, title: meeting.title, line: line, requestedHere: false, progress: progress, isRunning: running)
            }
            switch ProcessingStatus(meeting, queue: local(meeting), now: now) {
            case .processing(let progress) where progress.device == nil || progress.device?.id == thisDevice:
                running.append(entry(ProcessingWords.progressLine(progress.stage, fraction: progress.fraction), running: true,
                                     progress: progress.fraction))
                if work.line.running == nil {
                    work.line.running = progress.stage
                    work.line.fraction = progress.fraction
                }
                continue
            case .requested(.queued):
                let request = meeting.openProcessingRequests.first { $0.claim?.device.id == thisDevice }
                waiting.append((request?.createdAt ?? meeting.date, entry(ProcessingWords.waitingHereShort(request?.mode))))
                work.line.waiting += 1
                continue
            case .requested(.paused):
                paused.append(entry(pausedLine))
                work.line.waiting += 1
                continue
            case .failed(let failure) where failure.device?.id == thisDevice && listsFailure(failure, meeting: meeting, now: now):
                failed.append(failureEntry(failure, meeting: meeting, thisDevice: thisDevice))
                continue
            default:
                break
            }
            if case .cloud(let model)? = runs[meeting.id] {
                running.append(entry("Summarizing with \(model.name)", running: true))
                if work.line.cloudModel == nil { work.line.cloudModel = model.name }
            } else if let planner = planners[meeting.id], case .countingDown(.thisDevice, let until) = planner.phase {
                var countdown = entry("Summarizing in \(planner.secondsLeft(at: now) ?? 1) s")
                countdown.actions = planner.actions
                // Under the This iPhone heading, it doesn't say "on this iPhone" again.
                countdown.countdownUntil = until
                countdown.isRunning = true
                counting.append(countdown)
                if work.line.countdown == nil { work.line.countdown = until }
            } else if let planner = planners[meeting.id], case .started(.cloud(let model)) = planner.phase {
                running.append(entry("Summarizing with \(model.name)", running: true))
                if work.line.cloudModel == nil { work.line.cloudModel = model.name }
            }
        }
        // Nothing runs while work waits: the line says what it waits for.
        if work.line.running == nil, work.line.countdown == nil, work.line.cloudModel == nil, work.line.waiting > 0 {
            work.line.pause = pause
        }
        let ordered = running + counting + waiting.sorted { $0.0 < $1.0 }.map(\.1) + paused + failed
        work.entries = Array(ordered.prefix(limit))
        return work
    }
}

extension StatusMacRow {
    /// A Mac that doesn't transcribe yet: it says so, in warning ink, with what to do.
    mutating func isNotSetUp() {
        text = "Not set up to transcribe"
        needsYou = true
        fix = StatusSheetModel.notProcessingFix(name)
    }
}

extension StatusInputs.Recorder {
    /// Its facts as both apps word a recorder (`RecorderStatusWords`).
    var facts: RecorderFacts {
        var facts = RecorderFacts(id: id, name: name, shortName: shortName, symbol: symbol, isDirect: isDirect, state: state, isLinked: isLinked)
        facts.batteryLevel = batteryLevel
        facts.batteryCharging = batteryCharging
        facts.isRecording = isRecording
        facts.recordingAsOf = recordingAsOf
        facts.isListeningLive = isListeningLive
        facts.recordCommandPending = recordCommandPending
        facts.managedBy = managedBy
        facts.lastKnown = lastKnown
        facts.handoff = handoff
        facts.problem = problem
        facts.newCount = newCount
        facts.importing = importing.map {
            RecorderFacts.Importing(position: $0.position, total: $0.total, fraction: $0.fraction, suspended: $0.suspended, running: importRunning)
        }
        facts.fastTransfer = fastTransfer
        facts.lastConnected = lastConnected
        facts.otherAppWait = otherAppWait
        facts.folder = folder
        facts.hasRecordControl = hasRecordControl
        facts.hasLiveListening = hasLiveListening
        facts.canConnect = canConnect
        facts.notListed = notListed
        return facts
    }

    /// The facts the recorder's page reads its actions from (`RecorderActions`), from the card's: the same facts.
    var actionFacts: RecorderFacts { facts }
}
