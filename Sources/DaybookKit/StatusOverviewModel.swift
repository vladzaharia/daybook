import DaybookCore
import DaybookDevices
import Foundation

// What the status overview says, the same on both apps (docs/interface.md, "Status overview"): a line for each thing
// that exists (each recorder added, each other Daybook, this device while it has work of its own, iCloud when it's a
// problem), the one of them with something to say in the iPhone library's status strip, and the groups the iPhone's
// sheet shows past its lines, a card each: recorders, Macs, and this iPhone. Floating Notes' home and the iPhone's
// sheet draw it (DaybookUI's `StatusOverview`); each app only gathers its facts (`StatusOverviewInputs`): the iPhone's
// `StatusSheetInputs.make`, the Mac's `StatusOverviewInputs.make`. Plain values from plain inputs, so tests read
// exactly what each state says.

/// A conversation in a processing queue, as the iPhone knows it: a Mac's (the Macs card) or this iPhone's own (the
/// This iPhone card).
public struct StatusQueueEntry: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    /// "Transcribing on Studio Mac · 40%", "Waiting", "Studio Mac couldn’t finish".
    public var line: String
    /// Asked for on this iPhone ("Requested from this iPhone").
    public var requestedHere: Bool
    public var progress: Double?
    public var isRunning: Bool
    public var failed: Bool
    /// Its Mac's work is done, and a recording made alongside hasn't arrived ("Waiting for Soundcore
    /// Work audio"): it waits for that recording, not for the Mac.
    public var awaitsRecording: Bool
    /// For a failure: what it means, in plain words ("Something went wrong on Studio Mac. The recording is saved.").
    public var detail: String?
    /// For a failure: the Mac's own words, shown only behind Details.
    public var details: String?
    /// The Mac doing the work (or that failed), when known.
    public var mac: String?
    /// The line without the Mac's name ("Transcribing · 40%", "Couldn’t finish"), for under that Mac's row.
    public var brief: String?
    /// What the person can choose for its summary here (docs/multipoint.md, "Where summaries run").
    public var actions: [SummaryPlacementPlanner.Action]
    /// Its summary's countdown runs out then, where `countdownPlace` says ("on Studio Mac", "on this iPhone").
    public var countdownUntil: Date?
    public var countdownPlace: String?
    /// A failure Try Again asks again for, as the page's box does.
    public var retry: ProcessingRequest.Mode?

    public init(id: UUID, title: String, line: String, requestedHere: Bool, progress: Double?, isRunning: Bool, failed: Bool = false,
                awaitsRecording: Bool = false, detail: String? = nil, details: String? = nil, mac: String? = nil, brief: String? = nil,
                actions: [SummaryPlacementPlanner.Action] = [], countdownUntil: Date? = nil, countdownPlace: String? = nil,
                retry: ProcessingRequest.Mode? = nil) {
        self.id = id; self.title = title; self.line = line; self.requestedHere = requestedHere; self.progress = progress
        self.isRunning = isRunning; self.failed = failed; self.awaitsRecording = awaitsRecording; self.detail = detail
        self.details = details; self.mac = mac; self.brief = brief; self.actions = actions; self.countdownUntil = countdownUntil
        self.countdownPlace = countdownPlace; self.retry = retry
    }

    /// The line under a Mac's row in the Macs card: that Mac isn't named again.
    public func line(under macName: String?) -> String { line(under: macName, at: Date()) }

    /// The same at a moment: a countdown's seconds move with it.
    public func line(under macName: String?, at now: Date) -> String {
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
}

/// What the iPhone's sheet shows, top to bottom. Each group is a heading and one card, and each device is in one card
/// only; a line a card says isn't repeated above it.
public enum StatusSection: Hashable, Sendable {
    /// iCloud's line, while it's a problem: no card says it.
    case lines
    /// Live listening captions, while a recorder streams.
    case captions
    /// A card per recorder added: its status and handoff ("Use on This iPhone" / "Use on Studio Mac"); large adds its
    /// storage, its actions, and the recordings waiting on it.
    case recorders
    /// One card, while there's a Mac or work waiting for one: every Mac, the queue under the Mac doing it, and Pair
    /// with Your Mac… while none is paired.
    case macs
    /// This iPhone: its own queue while it has work, and the audio kept on it, opening Storage.
    case iphone
}

/// What a recorder's card offers at the large detent: what its page offers (`RecorderActions`), only what can be done
/// now, never a disabled button.
public typealias StatusRecorderAction = RecorderAction

/// A Mac in the Macs card.
public struct StatusMacRow: Equatable, Identifiable, Sendable {
    public enum ID: Hashable, Sendable {
        /// Paired over Wi‑Fi: the row opens its details.
        case paired(UUID)
        /// Known only by its presence in the library (it syncs, but isn't paired with this iPhone).
        case synced(String)
    }

    public var id: ID
    public var name: String
    public var text: String
    public var isConnected: Bool
    /// The transcription queue shows under this row.
    public var showsQueue: Bool
    /// It needs the person: its text in warning ink, with `fix` under it.
    public var needsYou: Bool
    /// What to do, in one sentence: "Finish in Daybook › Settings on Studio Mac."
    public var fix: String?

    public init(id: ID, name: String, text: String, isConnected: Bool, showsQueue: Bool = false, needsYou: Bool = false, fix: String? = nil) {
        self.id = id; self.name = name; self.text = text; self.isConnected = isConnected; self.showsQueue = showsQueue
        self.needsYou = needsYou; self.fix = fix
    }
}

/// The facts the overview is built from, gathered by each app from its own model: the recording with the recorders and
/// the other Daybooks that can record along (at rest too), the Macs as an iPhone knows them, this device's own work,
/// and iCloud. Each app fills what it has; what it hasn't says nothing.
public struct StatusOverviewInputs: Equatable {
    /// A Mac paired with an iPhone over Wi‑Fi.
    public struct Mac: Equatable {
        public var id: UUID
        public var name: String
        /// "Connected", "Recording now", "Last seen today, 9:12 AM".
        public var line: String
        public var isConnected: Bool
        /// Connected, and it said it doesn't transcribe: it isn't set up yet.
        public var notProcessing: Bool
        /// Recording, by the link or its presence in the library.
        public var isRecording: Bool
        /// Something keeps it from connecting that its page fixes (Pair Again, Local Network).
        public var problem: Bool

        public init(id: UUID, name: String, line: String, isConnected: Bool, notProcessing: Bool = false, isRecording: Bool = false,
                    problem: Bool = false) {
            self.id = id; self.name = name; self.line = line; self.isConnected = isConnected; self.notProcessing = notProcessing
            self.isRecording = isRecording; self.problem = problem
        }
    }

    public enum SyncTone: Equatable, Sendable { case upToDate, working, attention, checking }

    /// How this device calls itself: "this Mac", "this iPhone", and its glyph.
    public var words: DeviceWords
    /// The recording, and the devices that can record along whether one runs or not: every recorder added (`recorders`),
    /// and the other Daybooks this device links with directly, a Mac's iPhones (`peers`). An iPhone's Macs are `mac` and
    /// `pairedMacs`.
    public var recording = RecordingStatusInputs()
    /// The library's Mac, as an iPhone knows it by the link and sync presence.
    public var mac: MacPresence = .checking
    /// A Mac's live progress over the link, newest first.
    public var liveProgress: [LiveProgress] = []
    /// Conversations a Mac is working on or will, as an iPhone knows them (the Macs card).
    public var queue: [StatusQueueEntry] = []
    /// This device's own work: its line's facts (docs/iphone.md, "Processing on this iPhone"; a Mac's queue), and on an
    /// iPhone its card's rows.
    public var local = QueueStatusWords.Queue()
    public var localQueue: [StatusQueueEntry] = []
    /// iCloud: where sync stands in Settings' words, and its tone; a line only while it needs the person.
    public var syncLine = SyncStatus.connecting.shortText
    /// The sync line when it's too long for its row: "Off" for a reason that keeps iCloud from being used.
    public var syncShort: String?
    public var syncTone: SyncTone = .checking
    /// iCloud can't be used here (signed out, iCloud Drive off): the crossed-out cloud.
    public var syncOff = false
    public var hasLiveCaptions = false
    /// The Macs paired with an iPhone over Wi‑Fi.
    public var pairedMacs: [Mac] = []

    public init(words: DeviceWords) {
        self.words = words
        recording.here = words.here
    }

    /// This device has work: running, waiting, paused, or a summary counting down to it.
    public var hasLocalWork: Bool { !local.isEmpty || !localQueue.isEmpty }
}

public enum StatusOverviewModel {
    // MARK: Sections

    /// What the iPhone's sheet shows, at either size, only of what exists: iCloud's line while it's a problem (no card
    /// says it), live captions while a recorder streams (first: they're what's happening now), a card per recorder added
    /// with its handoff, the Macs with their queue while there's a Mac or work for one, and this iPhone, its work and
    /// the audio kept on it. Large grows the recorder cards' storage, actions, and waiting recordings.
    public static func sections(_ inputs: StatusOverviewInputs, now: Date = Date()) -> [StatusSection] {
        var sections: [StatusSection] = []
        if syncLine(inputs) != nil { sections.append(.lines) }
        if inputs.hasLiveCaptions { sections.append(.captions) }
        if !inputs.recording.recorders.isEmpty { sections.append(.recorders) }
        if !macRows(inputs, now: now).isEmpty || !inputs.queue.isEmpty { sections.append(.macs) }
        sections.append(.iphone)
        return sections
    }

    // MARK: A recorder's card

    /// The recorder's actions, the ones its page offers (`RecorderActions`), in order: Connect, Record or Pause,
    /// Import N New, Check for New, Listen Live or Stop Listening. A recorder another device manages, one without
    /// Bluetooth, or one on its way between devices has none here.
    public static func actions(for recorder: RecorderFacts) -> [StatusRecorderAction] {
        RecorderActions.available(recorder)
    }

    /// "About 2,170 hours left": the recorder's room, on its card at the large detent.
    public static func storageLeft(hours: Double) -> String {
        if hours < 1 { return "Less than an hour left" }
        let rounded = StorageFormat.roundedHours(hours)
        return rounded == 1 ? "About 1 hour left" : "About \(rounded.formatted()) hours left"
    }

    // MARK: The Macs card

    /// What a Mac that doesn't transcribe yet needs, in one sentence: "Finish in Daybook › Settings on Studio Mac."
    public static func notProcessingFix(_ name: String) -> String { "Finish in Daybook › Settings on \(name)." }

    /// Every paired Mac, then a Mac the library synced with in the last 30 days that isn't paired here (by its
    /// presence). The queue goes under the Mac that does the work: the connected one, else the one presence names.
    /// A Mac that isn't set up to transcribe says so in warning ink, with what to do under it.
    public static func macRows(_ inputs: StatusOverviewInputs, now: Date = Date()) -> [StatusMacRow] {
        let notSetUp: String? = { if case .notProcessing(let name, _) = inputs.mac { return name } else { return nil } }()
        var rows = inputs.pairedMacs.map { mac in
            var row = StatusMacRow(id: .paired(mac.id), name: mac.name, text: mac.line, isConnected: mac.isConnected)
            if mac.notProcessing || mac.name == notSetUp { row.isNotSetUp() }
            return row
        }
        if let name = inputs.mac.macName, !rows.contains(where: { $0.name == name }), isRecent(inputs.mac, now: now),
           let text = presenceText(inputs.mac, now: now) {
            var row = StatusMacRow(id: .synced(name), name: name, text: text, isConnected: false)
            if name == notSetUp { row.isNotSetUp() }
            rows.append(row)
        }
        if let index = rows.firstIndex(where: \.isConnected) ?? rows.firstIndex(where: { $0.name == inputs.mac.macName }) {
            rows[index].showsQueue = true
        }
        return rows
    }

    /// A Mac the library last synced with longer ago than this has no line or row, unless it's paired here.
    public static let macShownFor: TimeInterval = 30 * 86_400

    /// The Mac presence names synced in the last 30 days (`macShownFor`), or is here now.
    public static func isRecent(_ presence: MacPresence, now: Date = Date()) -> Bool {
        switch presence {
        case .seen(_, let date), .notProcessing(_, let date): return now.timeIntervalSince(date) < macShownFor
        case .connected, .recording, .olderMac: return true
        case .checking, .unavailable, .noMac: return false
        }
    }

    /// A synced Mac's row, from its presence, dated as every device's absence is ("Last seen today, 9:12 AM").
    public static func presenceText(_ presence: MacPresence, now: Date = Date()) -> String? {
        switch presence {
        case .connected: return "Connected"
        case .seen(_, let date): return RecorderStatusWords.lastSeen(date, now: now)
        case .recording: return "Recording"
        case .notProcessing: return "Not set up to transcribe"
        default: return nil
        }
    }

    // MARK: Lines

    public static let macID = "mac"
    public static let syncID = "sync"

    /// The lines, one for each thing that exists, in order: each recorder added, each Mac (`macLines`), each other
    /// Daybook this device links with (a Mac's iPhones), this device while it has work of its own, and iCloud when it's
    /// a problem. Nothing added and nothing wrong, no lines.
    public static func lines(_ inputs: StatusOverviewInputs, now: Date = Date()) -> [StatusLineWords] {
        var lines = inputs.recording.recorders.map { recorderLine($0, here: inputs.words.here, now: now) }
        lines += macLines(inputs, now: now)
        lines += inputs.recording.peers.map { PeerStatusWords.line(PeerFacts($0), now: now) }
        if let local = localLine(inputs, now: now) { lines.append(local) }
        if let sync = syncLine(inputs) { lines.append(sync) }
        return lines
    }

    /// The iPhone library's status strip: the one line with something to say, in order what needs the person, then
    /// what's recording elsewhere, then what's working or counting down; among equals the first. Otherwise nothing: a
    /// recorder that's connected, a Mac that's idle, and a queue paused until it can continue say nothing there.
    public static func strip(_ lines: [StatusLineWords]) -> StatusLineWords? {
        func rank(_ line: StatusLineWords) -> Int {
            switch line.tone {
            case .attention: return 3
            case .recording: return 2
            case .working: return 1
            case .calm: return line.countdownUntil == nil ? 0 : 1
            case .linked: return 0
            }
        }
        var best: StatusLineWords?
        for line in lines where rank(line) > (best.map(rank) ?? 0) { best = line }
        return best
    }

    /// A recorder's line in the words both apps give a recorder (`RecorderStatusWords`), `here` being how this device
    /// calls itself ("this iPhone").
    public static func recorderLine(_ recorder: RecorderFacts, here: String, now: Date = Date()) -> StatusLineWords {
        RecorderStatusWords.line(recorder, here: here, now: now)
    }

    /// "This iPhone  Transcribing · 40% · 1 waiting", "This Mac  Paused · Continues when iPhone is charging": this
    /// device's own work in the one line both apps use for a device's queue (`QueueStatusWords`). Nil while it has none.
    public static func localLine(_ inputs: StatusOverviewInputs, now: Date = Date()) -> StatusLineWords? {
        QueueStatusWords.line(inputs.local, words: inputs.words, now: now)
    }

    /// A line per Mac: the one doing or counting down to this iPhone's work, or else the library's by its presence
    /// (`macLine`), then every other Mac paired here, whatever sync says.
    public static func macLines(_ inputs: StatusOverviewInputs, now: Date = Date()) -> [StatusLineWords] {
        var lines = macLine(inputs, now: now).map { [$0] } ?? []
        for mac in inputs.pairedMacs where !lines.contains(where: { $0.title == mac.name }) {
            lines.append(pairedLine(mac))
        }
        return lines
    }

    public static func pairedID(_ mac: StatusOverviewInputs.Mac) -> String { "mac-\(mac.id.uuidString)" }

    /// A paired Mac's line, from the link: "Connected" in teal, "Recording now" with the red dot, "Not set up to
    /// transcribe" or what keeps it from connecting in warning ink, else when it was last seen.
    public static func pairedLine(_ mac: StatusOverviewInputs.Mac) -> StatusLineWords {
        let tone: StatusLineWords.Tone = mac.notProcessing || mac.problem ? .attention
            : mac.isRecording ? .recording : mac.isConnected ? .linked : .calm
        return StatusLineWords(id: pairedID(mac), symbol: "desktopcomputer", title: mac.name,
                               text: mac.notProcessing ? "Not set up to transcribe" : mac.line, tone: tone,
                               shortText: mac.notProcessing ? "Not set up" : nil)
    }

    /// The Mac doing this iPhone's work (live over the link, or by a synced claim) or counting down to it, else the
    /// library's Mac by its presence: connected, recording, not set up, or seen in the last 30 days. Nil when no Mac
    /// is known: none has synced the library, iCloud can't be used, or it's still looking.
    public static func macLine(_ inputs: StatusOverviewInputs, now: Date = Date()) -> StatusLineWords? {
        func line(_ title: String, _ text: String, _ tone: StatusLineWords.Tone, progress: Double? = nil, short: String? = nil,
                  countdown: Date? = nil) -> StatusLineWords {
            StatusLineWords(id: macID, symbol: "desktopcomputer", title: title, text: text, tone: tone, progress: progress, shortText: short,
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
            guard isRecent(inputs.mac, now: now) else { return nil }
            return line(name, [RecorderStatusWords.lastSeen(date, now: now), waitingText].compactMap { $0 }.joined(separator: " · "), .calm,
                        short: waitingText)
        case .recording(let name, _):
            return line(name, ["Recording", waitingText].compactMap { $0 }.joined(separator: " · "), .recording,
                        short: waitingText == nil ? nil : "Recording")
        case .notProcessing(let name, _):
            guard isRecent(inputs.mac, now: now) else { return nil }
            return line(name, "Not set up to transcribe", .attention, short: "Not set up")
        case .olderMac:
            return line("Your Mac", "Syncs with an earlier Daybook", .calm)
        case .noMac, .unavailable, .checking:
            // No Mac known, nothing to say about one: iCloud's own line says when it can't be used.
            return nil
        }
    }

    /// iCloud's line, only while it's a problem: signed out, off, full, a pass that failed, the library's key not
    /// here, sync paused. Up to date, syncing, and checking say nothing.
    public static func syncLine(_ inputs: StatusOverviewInputs) -> StatusLineWords? {
        guard inputs.syncTone == .attention else { return nil }
        return StatusLineWords(id: syncID, symbol: inputs.syncOff ? "icloud.slash" : "exclamationmark.icloud", title: "iCloud",
                               text: inputs.syncLine, tone: .attention, shortText: inputs.syncShort)
    }

    // MARK: The queues

    /// How long a conversation that couldn't finish stays in the status sheet's queues. Its row and page keep
    /// saying it, with Try Again, for as long as it's so.
    public static let failureShownFor: TimeInterval = 7 * 86_400

    /// A failure worth listing in a queue: recent, and not "No speech in this recording", which no device can do
    /// anything about (its row and page say it).
    public static func listsFailure(_ failure: ProcessingStatus.Failure, meeting: Meeting, now: Date) -> Bool {
        guard !failure.isNoSpeech else { return false }
        let when = failure.request?.outcome?.finishedAt ?? meeting.updatedAt
        return now.timeIntervalSince(when) < failureShownFor
    }

    /// A failure's queue entry: its plain sentence (`FailureWords`, ending "The recording is saved."), the device's
    /// own words behind Details, and Try Again with what it asked for, as the page offers.
    public static func failureEntry(_ failure: ProcessingStatus.Failure, meeting: Meeting, words: DeviceWords) -> StatusQueueEntry {
        let here = failure.device?.id == words.thisDeviceID
        return StatusQueueEntry(id: meeting.id, title: meeting.title,
                                line: here ? "Couldn’t finish" : failure.device.map { "\($0.name) couldn’t finish" } ?? "Couldn’t finish",
                                requestedHere: false, progress: nil, isRunning: false, failed: true, detail: FailureWords(failure, words: words).message,
                                details: failure.reason.isEmpty ? nil : failure.reason, mac: here ? nil : failure.device?.name,
                                brief: "Couldn’t finish", retry: meeting.tracks.isEmpty ? nil : failure.request?.mode ?? .newAudio)
    }

    /// Conversations a Mac is working on or will, as an iPhone knows (`words`: its own, with its sync ID): live progress
    /// first, then the synced claims, then requests waiting (oldest first), then conversations waiting for a recording
    /// made alongside (oldest first), then what couldn't finish lately. At most `limit`. This device's own work is in
    /// `localWork`.
    ///
    /// Where a summary runs comes first for its conversation (docs/multipoint.md, "Where summaries run"): this
    /// iPhone's countdown to a Mac or wait for one (`planners`), a Mac's countdown, and, with the cloud on offer,
    /// Use the Cloud for a Summarize request still waiting for a Mac.
    public static func queue(meetings: [Meeting], liveProgress: [UUID: LiveProgress], words: DeviceWords,
                             planners: [UUID: SummaryPlacementPlanner] = [:], runs: [UUID: SummaryPlace] = [:], cloudOffered: Bool = false,
                             now: Date = Date(), limit: Int = 6) -> [StatusQueueEntry] {
        let thisDevice = words.thisDeviceID
        var running: [StatusQueueEntry] = [], waiting: [(Date, StatusQueueEntry)] = [], failed: [StatusQueueEntry] = []
        var awaiting: [(Date, StatusQueueEntry)] = []
        for meeting in meetings {
            let requestedHere = meeting.openProcessingRequests.contains { $0.requestedBy.id == thisDevice }
            // A summary running here or in the cloud is this device's own.
            if runs[meeting.id] != nil { continue }
            if let planner = planners[meeting.id], let line = planner.line(at: now, thisDevice: words.here) {
                switch planner.phase {
                case .countingDown(.thisDevice, _), .started(.cloud), .started(.thisDevice): continue
                default: break
                }
                var entry = StatusQueueEntry(id: meeting.id, title: meeting.title, line: line, requestedHere: false, progress: nil,
                                             isRunning: false, actions: planner.actions, countdownUntil: planner.deadline)
                if case .countingDown(let place, _) = planner.phase {
                    entry.countdownPlace = SummaryPlacementPlanner.where(place, thisDevice: words.here)
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
                // This device's own work (docs/iphone.md, "Processing on this iPhone"): its own card.
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
                failed.append(failureEntry(failure, meeting: meeting, words: words))
            default:
                break
            }
        }
        let ordered = running + waiting.sorted { $0.0 < $1.0 }.map(\.1) + awaiting.sorted { $0.0 < $1.0 }.map(\.1) + failed
        return Array(ordered.prefix(limit))
    }

    /// This device's own work (docs/iphone.md, "Processing on this iPhone"): its line's facts, and its card's rows.
    public struct LocalWork: Equatable {
        public var line = QueueStatusWords.Queue()
        public var entries: [StatusQueueEntry] = []
        public init(line: QueueStatusWords.Queue = QueueStatusWords.Queue(), entries: [StatusQueueEntry] = []) {
            self.line = line; self.entries = entries
        }
    }

    /// What an iPhone is doing with its own recordings (`words`: its own, with its sync ID), from its processor's queue
    /// (`local`, `pause`) and where its summaries run: what runs here, a summary counting down to this device or running
    /// here or in the cloud, what waits its turn, what's paused and until when, and what couldn't finish here lately.
    /// In that order, at most `limit` rows. A Mac's own queue is its own (`QueueStatusWords.Queue`).
    public static func localWork(meetings: [Meeting], local: (Meeting) -> ProcessingStatus.LocalQueue?, pause: ProcessingWords.PauseReason?,
                                 words: DeviceWords, planners: [UUID: SummaryPlacementPlanner] = [:], runs: [UUID: SummaryPlace] = [:],
                                 now: Date = Date(), limit: Int = 6) -> LocalWork {
        let thisDevice = words.thisDeviceID
        var work = LocalWork()
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
                failed.append(failureEntry(failure, meeting: meeting, words: words))
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
    public mutating func isNotSetUp() {
        text = "Not set up to transcribe"
        needsYou = true
        fix = StatusOverviewModel.notProcessingFix(name)
    }
}
