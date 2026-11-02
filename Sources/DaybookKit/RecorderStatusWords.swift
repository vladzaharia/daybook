import DaybookCore
import DaybookDevices
import DaybookLink
import Foundation

// What a recorder's status reads, in one place for both apps (docs/devices.md): the status line (Floating Notes'
// home, the iPhone's status sheet and Recorders card, Settings › Devices, a window's subtitle), a device page's
// byline, a status-bar chip, and the menu bar's item. One set of facts (`RecorderFacts`), one recency verb ("Last
// seen"), one battery format (`BatteryFormat.label`), Listen Live as "Listening live" in the recording tone, and the
// recorder kind's own glyph. A Mac seen from an iPhone and an iPhone seen from a Mac read alike too
// (`PeerStatusWords`).

/// A status line's words and ink, before either app draws it (DaybookDesign's `StatusLineItem` on both).
public struct StatusLineWords: Equatable, Identifiable, Sendable {
    /// Which ink the line uses (docs/interface.md, "Colour has a job").
    public enum Tone: Equatable, Sendable {
        /// Fine; nothing to say beyond the fact.
        case calm
        /// Work in progress: the gradient line when there's a fraction.
        case working
        /// Connected now: teal.
        case linked
        /// Recording right now: the red dot.
        case recording
        /// Needs the person: orange.
        case attention
    }

    public var id: String
    public var symbol: String
    public var title: String
    public var text: String
    public var tone: Tone
    /// 0...1 for work in progress.
    public var progress: Double?
    /// A shorter way to say it, when `text` doesn't fit on one line.
    public var shortText: String?
    /// A countdown runs out then: `text(at:)` moves with it.
    public var countdownUntil: Date?

    public init(id: String, symbol: String, title: String, text: String, tone: Tone, progress: Double? = nil, shortText: String? = nil,
                countdownUntil: Date? = nil) {
        self.id = id; self.symbol = symbol; self.title = title; self.text = text; self.tone = tone; self.progress = progress
        self.shortText = shortText; self.countdownUntil = countdownUntil
    }

    public var accessibilityLabel: String { "\(title), \(text)" }

    /// The words at a moment: a countdown's seconds move with them ("Summarizing in 11 s · 1 waiting").
    public func text(at now: Date) -> String {
        guard let until = countdownUntil else { return text }
        let seconds = max(1, Int(until.timeIntervalSince(now).rounded(.up)))
        return text.replacingOccurrences(of: #"in \d+ s"#, with: "in \(seconds) s", options: .regularExpression)
    }
}

/// Everything a recorder's status is worded from, gathered from its device session, the handoff, and what the
/// device managing it reported over the link.
public struct RecorderFacts: Equatable {
    public struct Importing: Equatable {
        public var position: Int
        public var total: Int
        public var fraction: Double?
        /// Waiting for the recorder to come back.
        public var suspended: Bool
        /// A recording is coming off it now (not only waiting in the queue).
        public var running: Bool
        /// The transfer hasn't reported a fraction yet.
        public var preparing: Bool
        /// The current recording's time left, when the transfer knows it.
        public var secondsLeft: TimeInterval?
        public init(position: Int, total: Int, fraction: Double? = nil, suspended: Bool = false, running: Bool = true,
                    preparing: Bool = false, secondsLeft: TimeInterval? = nil) {
            self.position = position; self.total = total; self.fraction = fraction; self.suspended = suspended
            self.running = running && !suspended; self.preparing = preparing; self.secondsLeft = secondsLeft
        }
    }

    /// A recorder whose recordings arrive in a folder (`ImportFolderWatcher`).
    public struct Folder: Equatable {
        public var isWatching: Bool
        /// It can't be watched (moved, or permission lost).
        public var hasProblem: Bool
        public var waitingForICloud: Int
        public var lastImport: Date?
        public init(isWatching: Bool, hasProblem: Bool = false, waitingForICloud: Int = 0, lastImport: Date? = nil) {
            self.isWatching = isWatching; self.hasProblem = hasProblem; self.waitingForICloud = waitingForICloud; self.lastImport = lastImport
        }
    }

    public var id: String
    /// "Soundcore Work".
    public var name: String
    /// "Soundcore", for a chip and the narrowest lines.
    public var shortName: String
    /// The kind's glyph (`DeviceKind.systemImage`).
    public var symbol: String
    /// It has a direct connection (Bluetooth): battery, handoff, controls.
    public var isDirect: Bool
    public var state: ConnectionState
    /// Its direct connection is up.
    public var isLinked: Bool
    public var batteryLevel: Int?
    public var batteryCharging = false
    /// It says it's recording, connected now.
    public var isRecording = false
    /// It was last seen recording then, while it isn't connected.
    public var recordingAsOf: Date?
    public var isListeningLive = false
    /// A Record or Pause sent to it hasn't been confirmed yet.
    public var recordCommandPending = false
    /// Its link to the recording under way (multipoint), while there is one.
    public var along: CompanionRecording.State?
    /// Another device manages it: "Alex’s iPhone".
    public var managedBy: String?
    public var managedByPhone = false
    /// What it was last known to be doing while it isn't live here: "Recording since 10:02, as of 10:14".
    public var lastKnown: String?
    public var handoff: RecorderHandoff.State = .idle
    /// The problem's title, when there is one.
    public var problem: String?
    public var newCount = 0
    public var importing: Importing?
    /// A recording coming over the recorder's own Wi‑Fi.
    public var fastTransfer: FastTransferStage?
    public var lastConnected: Date?
    /// An import or a Start waits for another app: "Waiting for the Soundcore app to finish".
    public var otherAppWait: String?
    public var folder: Folder?
    /// It can start and pause recording (Record on Soundcore).
    public var hasRecordControl = false
    /// It can stream what it hears (Listen Live).
    public var hasLiveListening = false
    /// It isn't linked, and Connect would do something now.
    public var canConnect = false
    /// Connected, but it didn't list its recordings (it didn't answer, or refused): the new ones shown are from its
    /// remembered list.
    public var notListed = false

    public init(id: String, name: String, shortName: String, symbol: String, isDirect: Bool, state: ConnectionState, isLinked: Bool) {
        self.id = id; self.name = name; self.shortName = shortName; self.symbol = symbol
        self.isDirect = isDirect; self.state = state; self.isLinked = isLinked
    }

    /// From a device session: `handoff` is the recorder's handoff now, `link` what the device managing it last said
    /// (`LinkRecorderState`), `along` its link to the recording under way, and `problemTitle` how this app titles a
    /// problem (the iPhone has its own words for some).
    @MainActor
    public init(session: DeviceSession, handoff: RecorderHandoff.State = .idle, link: LinkRecorderState? = nil,
                along: CompanionRecording.State? = nil, problemTitle: (DeviceProblem) -> String = { $0.title }, now: Date = Date()) {
        self.init(id: session.id, name: session.device.name, shortName: session.kind.shortName, symbol: session.kind.systemImage,
                  isDirect: session.direct != nil, state: session.state, isLinked: session.isLinked)
        let status = session.status
        batteryLevel = status?.battery?.level
        batteryCharging = status?.battery?.charging == true
        isRecording = session.isLinked && status?.isRecording == true
        if !session.isLinked, let status, status.isRecording == true { recordingAsOf = status.updatedAt }
        isListeningLive = session.isListeningLive
        recordCommandPending = (session.primary as? any RecordControlConnection)?.recordCommandPending == true
        self.along = along
        if let owner = session.managedElsewhere {
            managedBy = owner.ownerName
            managedByPhone = owner.ownerClass == .phone
            if !session.isLinked { lastKnown = link?.summary(now: now) }
        } else if !session.isLinked {
            lastKnown = LinkRecorderState(session: session)?.summary(now: now)
        }
        self.handoff = handoff
        problem = session.problem.map(problemTitle)
        // A recorder another device manages imports there: its recordings arrive through sync.
        let importsHere = session.managedElsewhere == nil || session.primary?.method != .direct
        newCount = importsHere ? session.newRecordings.count : 0
        if session.queue.isActive {
            let running = session.queue.current != nil
            importing = Importing(position: session.queue.position, total: session.queue.total, fraction: session.importProgress,
                                  suspended: session.queue.isSuspended, running: running,
                                  preparing: running && session.phase == .preparing && session.queue.imported + session.queue.failed == 0,
                                  secondsLeft: session.secondsLeft)
        }
        fastTransfer = session.fastTransferStage
        lastConnected = session.direct?.lastConnectedAt ?? session.primary?.lastConnectedAt
        otherAppWait = session.otherAppWait
        if let files = session.files, session.primary?.method == .files {
            folder = Folder(isWatching: files.isWatching, hasProblem: files.problem != nil, waitingForICloud: files.waitingForICloud,
                            lastImport: files.lastImportDate)
        }
        let direct = session.direct
        hasRecordControl = direct is any RecordControlConnection && direct?.capabilities.contains(.recordControl) == true
        hasLiveListening = direct is any LiveListeningConnection
        canConnect = Self.canConnect(session)
        notListed = session.managedElsewhere == nil && session.listingState == .notListed
    }

    /// It isn't linked, and Connect would do something now: its direct link is set up and on, not already on its
    /// way, and Bluetooth can reach it.
    @MainActor
    public static func canConnect(_ session: DeviceSession) -> Bool {
        let direct = session.direct
        return !session.isLinked && !session.state.isBusy && direct?.isSetUp == true && direct?.state != .unavailable
            && session.device.isEnabled(.direct)
    }

    var battery: String? {
        batteryLevel.map { _ in BatteryFormat.label(DeviceStatus.Battery(level: batteryLevel, charging: batteryCharging)) }
    }

    var recordingAlong: Bool { [CompanionRecording.State.recording, .alreadyRecording].contains(along) }
}

public enum RecorderStatusWords {
    /// "Last seen today, 3:25 AM": the one way a device's absence is dated.
    public static func lastSeen(_ date: Date, now: Date = Date()) -> String {
        "Last seen \(DeviceDateFormat.lastSeen(date, now: now))"
    }

    /// The recorder's status line: "Soundcore Work  Connected · 80% · 1 new". `here` is how this device calls itself
    /// ("this Mac"). The same words serve the window's subtitle.
    public static func line(_ facts: RecorderFacts, here: String, now: Date = Date()) -> StatusLineWords {
        func line(_ text: String, _ tone: StatusLineWords.Tone, progress: Double? = nil, short: String? = nil) -> StatusLineWords {
            StatusLineWords(id: "recorder-\(facts.id)", symbol: facts.symbol, title: facts.name, text: text, tone: tone,
                            progress: progress, shortText: short)
        }
        switch facts.handoff {
        case .idle: break
        case .done: return line("On \(here) now", .linked)
        case .refused(let by, _): return line("\(by) didn’t hand it over", .attention)
        default: return line(handoffLine(facts.handoff) ?? "Moving…", .working, short: shortHandoff(facts.handoff))
        }
        if let owner = facts.managedBy {
            return line(facts.lastKnown.map { "Managed by \(owner) · \($0)" } ?? "Managed by \(owner)", .calm,
                        short: facts.lastKnown == nil ? nil : "Managed by \(owner)")
        }
        if facts.isListeningLive { return line("Listening live", .recording) }
        if let wait = facts.otherAppWait { return line(wait, .working, short: "Waiting…") }
        if let importing = facts.importing {
            if importing.suspended {
                return line(importing.total == 1 ? "1 recording waits to import" : "\(importing.total) recordings wait to import", .calm)
            }
            if let stage = facts.fastTransfer {
                let words = fastTransfer(stage, importing: importing)
                return line(words.text, .working, progress: importing.fraction, short: words.short)
            }
            return line("Importing \(importing.position) of \(importing.total)", .working, progress: importing.fraction)
        }
        if let problem = facts.problem, !facts.isLinked { return line(problem, .attention) }
        if let folder = facts.folder { return folderLine(folder, facts: facts, line: line) }
        switch facts.state {
        case .connected where facts.isDirect || facts.isLinked:
            if facts.recordCommandPending { return line("Waiting for \(facts.shortName)…", .working) }
            let state = facts.isRecording ? "Recording" : "Connected"
            let new = facts.newCount > 0 ? "\(facts.newCount) new" : nil
            let parts = [state, facts.battery, new].compactMap { $0 }
            // Narrow, it keeps what matters: a battery level or new recordings already say it's connected; while
            // recording, the word and the battery.
            let short = facts.isRecording ? [state, facts.battery].compactMap { $0 } : [facts.battery, new].compactMap { $0 }
            return line(parts.joined(separator: " · "), facts.isRecording ? .recording : .linked,
                        short: short.isEmpty || short == parts ? nil : short.joined(separator: " · "))
        case .connected:
            return line(facts.newCount > 0 ? "\(facts.newCount) new in its folder" : "Watching its folder", .calm)
        case .searching: return line("Looking for it…", .working)
        case .connecting: return line("Connecting…", .working)
        case .reconnecting: return line("Reconnecting…", .working)
        case .unavailable: return line(facts.problem ?? "Bluetooth isn’t available", .attention)
        case .notSetUp: return line("Not set up", .calm)
        case .notConnected:
            var parts: [String] = []
            if let known = facts.lastKnown { parts.append(known) }
            else if let asOf = facts.recordingAsOf { parts.append(DeviceDateFormat.recordingAsOf(asOf)) }
            if facts.newCount > 0 { parts.append("\(facts.newCount) new") }
            if let last = facts.lastConnected { parts.append(lastSeen(last, now: now)) }
            return line(parts.isEmpty ? "Not connected" : parts.joined(separator: " · "), .calm, short: parts.isEmpty ? nil : "Not connected")
        }
    }

    private static func folderLine(_ folder: RecorderFacts.Folder, facts: RecorderFacts,
                                   line: (String, StatusLineWords.Tone, Double?, String?) -> StatusLineWords) -> StatusLineWords {
        if folder.hasProblem { return line("Not watching", .attention, nil, nil) }
        if folder.waitingForICloud > 0 {
            let files = folder.waitingForICloud == 1 ? "1 file" : "\(folder.waitingForICloud) files"
            return line("Waiting for iCloud to download \(files)", .working, nil, "Waiting for iCloud")
        }
        guard folder.isWatching else { return line("Not watching", .calm, nil, nil) }
        return line(facts.newCount > 0 ? "\(facts.newCount) new in its folder" : "Watching its folder", .calm, nil, nil)
    }

    /// The device page's byline under its name, which the page's figures, import, and problem don't repeat:
    /// "Connected · Recording", "Not connected · Last seen today, 3:25 AM", "Watching · Last import 2 hours ago".
    public static func byline(_ facts: RecorderFacts, now: Date = Date()) -> String {
        if let folder = facts.folder {
            if folder.hasProblem {
                return folder.lastImport.map { "Not watching · Last import \(DeviceDateFormat.lastSeen($0, now: now))" } ?? "Not watching"
            }
            if folder.waitingForICloud > 0 {
                return folder.waitingForICloud == 1 ? "Waiting for iCloud to download 1 file" : "Waiting for iCloud to download \(folder.waitingForICloud) files"
            }
            guard folder.isWatching else { return "Not watching" }
            return folder.lastImport.map { "Watching · Last import \(DeviceDateFormat.relative($0, now: now))" } ?? "Watching"
        }
        func notConnected() -> String {
            facts.lastConnected.map { "Not connected · \(lastSeen($0, now: now))" } ?? "Not connected"
        }
        switch facts.state {
        case .searching: return "Looking for it…"
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        // The problem box below says why.
        case .unavailable: return facts.problem == nil ? "Not available" : notConnected()
        case .notSetUp: return "Not set up"
        case .connected:
            if let wait = facts.otherAppWait { return "Connected · \(wait)" }
            if facts.isListeningLive { return "Connected · Listening live" }
            if facts.recordCommandPending { return "Connected · Waiting for \(facts.shortName)…" }
            return facts.isRecording ? "Connected · Recording" : "Connected"
        case .notConnected:
            if let owner = facts.managedBy, facts.isDirect {
                return facts.lastKnown.map { "Managed by \(owner) · \($0)" } ?? "Managed by \(owner)"
            }
            if let asOf = facts.recordingAsOf { return DeviceDateFormat.recordingAsOf(asOf) }
            return notConnected()
        }
    }

    /// A chip in a status bar: a short label that keeps the recorder's name, with the whole status in a sentence for
    /// its menu, tooltip, and VoiceOver. `recording` while this device records: a recorder asked to record along
    /// says whether it is. Nil for a recorder not set up.
    public static func chip(_ facts: RecorderFacts, recording: Bool, here: String, now: Date = Date()) -> Chip? {
        let name = facts.name
        func chip(_ label: String, short: String? = nil, _ tone: StatusLineWords.Tone, dot: Bool = false, progress: Double? = nil,
                  detail: String) -> Chip {
            Chip(label: label, shortLabel: short, tone: tone, showsDot: dot, progress: progress, detail: detail)
        }
        switch facts.handoff {
        case .idle: break
        case .done: return chip("On \(here)", .linked, detail: RecorderHandoff.Words.headline(facts.handoff, recorder: name, here: here) ?? name)
        case .refused: return chip("Not handed over", .attention, detail: RecorderHandoff.Words.headline(facts.handoff, recorder: name, here: here) ?? name)
        default: return chip("Moving…", .working, detail: RecorderHandoff.Words.headline(facts.handoff, recorder: name, here: here) ?? "Moving \(name)…")
        }
        if let owner = facts.managedBy {
            return chip("\(facts.shortName) on \(owner)", short: facts.managedByPhone ? "On iPhone" : "On Mac", .calm,
                        detail: [name, "Managed by \(owner)", facts.lastKnown].compactMap { $0 }.joined(separator: " · "))
        }
        if recording, let along = facts.along, [.unavailable, .failed].contains(along) {
            return chip("Not recording", .attention, detail: "\(name) didn’t start recording. Start it on the recorder to record along.")
        }
        if recording, facts.along == .starting { return chip("Starting…", .working, detail: "Starting \(name)…") }
        if facts.isListeningLive {
            return chip("\(facts.shortName) · Listening", short: facts.shortName, .recording, dot: true, detail: "\(name) · Listening live")
        }
        if let problem = facts.problem, !facts.isLinked { return chip(problem, .attention, detail: "\(name) · \(problem)") }
        switch facts.state {
        case .connected:
            if let importing = facts.importing, !importing.suspended {
                return chip("Importing \(importing.position) of \(importing.total)", short: "\(importing.position)/\(importing.total)", .working,
                            progress: importing.fraction, detail: "\(name) · Importing \(importing.position) of \(importing.total)")
            }
            let recordingAlong = facts.isRecording || facts.recordingAlong
            var parts = [name, recordingAlong ? (recording ? "Recording along" : "Recording") : "Connected"]
            if let battery = facts.battery { parts.append(battery) }
            if facts.newCount > 0 { parts.append("\(facts.newCount) new") }
            // Short, it keeps its name: a battery level alone doesn't say whose it is.
            return chip(facts.battery.map { "\(facts.shortName) · \($0)" } ?? facts.shortName, short: facts.shortName, .linked,
                        dot: recordingAlong, detail: parts.joined(separator: " · "))
        case .searching: return chip("Looking…", .working, detail: "\(name) · Looking for it…")
        case .connecting, .reconnecting:
            return chip(facts.state == .reconnecting ? "Reconnecting…" : "Connecting…", .working, detail: "\(name) · Connecting…")
        case .unavailable: return chip("Unavailable", .attention, detail: "\(name) · \(facts.problem ?? "Bluetooth isn’t available")")
        case .notConnected:
            let seen = facts.lastConnected.map { " · \(lastSeen($0, now: now))" } ?? ""
            return chip("Not connected", .calm, detail: "\(name) · Not connected\(seen)")
        case .notSetUp: return nil
        }
    }

    /// A chip's words.
    public struct Chip: Equatable, Sendable {
        public var label: String
        /// For a narrow bar; nil leaves only the glyph.
        public var shortLabel: String?
        public var tone: StatusLineWords.Tone
        /// The red recording dot after the glyph.
        public var showsDot: Bool
        public var progress: Double?
        /// The whole status in a sentence: the menu's first line, the tooltip, and VoiceOver.
        public var detail: String
    }

    /// The menu bar's line for the recorder, which has no title column, so it names it: the handoff in its words,
    /// "Importing from Soundcore Work · 1 of 3", or nil when there's nothing under way.
    public static func menuItem(_ facts: RecorderFacts, here: String) -> String? {
        if let headline = RecorderHandoff.Words.headline(facts.handoff, recorder: facts.name, here: here) { return headline }
        if let importing = facts.importing, !importing.suspended {
            return "Importing from \(facts.name) · \(importing.position) of \(importing.total)"
        }
        return nil
    }

    /// The menu bar's item for new recordings: "Soundcore Work · 2 New Recordings…"; nil when there are none.
    public static func newRecordingsItem(_ facts: RecorderFacts) -> String? {
        guard facts.newCount > 0, facts.managedBy == nil else { return nil }
        return facts.newCount == 1 ? "\(facts.name) · 1 New Recording…" : "\(facts.name) · \(facts.newCount) New Recordings…"
    }

    /// A handoff on the recorder's line (its name is the line's title, so it isn't repeated).
    static func handoffLine(_ state: RecorderHandoff.State) -> String? {
        switch state {
        case .asking(let owner): return "Asking \(owner) to let go…"
        case .ownerFinishing(let owner, .importing?): return "\(owner) finishes an import, then lets go"
        case .ownerFinishing(let owner, .liveListening?): return "\(owner) saves what it heard live, then lets go"
        case .ownerFinishing(let owner, nil): return "\(owner) is letting go…"
        case .waitingForSync(let owner, _): return "Waiting for \(owner) to let go…"
        case .connecting: return "Connecting…"
        case .handingOver(let to, _): return "Moving to \(to)…"
        case .offering(let to): return "Asking \(to) to take it…"
        case .idle, .refused, .done: return nil
        }
    }

    /// The same, when the line is too narrow for it.
    static func shortHandoff(_ state: RecorderHandoff.State) -> String? {
        switch state {
        case .asking(let owner): return "Asking \(owner)…"
        case .ownerFinishing(_, .importing?): return "Moving here after an import"
        case .ownerFinishing: return "Moving here…"
        case .waitingForSync(let owner, _): return "Waiting for \(owner)…"
        case .offering(let to): return "Offering to \(to)…"
        default: return nil
        }
    }
}

// MARK: - The device a recorder's screens are on

extension RecorderStatusWords {
    /// Where the words are read, for what differs by device: what it calls itself, the other device it may share a
    /// recorder with, and where its Settings are.
    public enum Place: Hashable, Sendable {
        case mac, iPhone

        /// The platform these words are compiled for.
        public static var current: Place {
            #if os(iOS)
            .iPhone
            #else
            .mac
            #endif
        }

        /// "this Mac", "this iPhone".
        public var here: String { self == .mac ? "this Mac" : "this iPhone" }
        /// "This Mac", "This iPhone", for the start of a line or a title.
        public var hereTitle: String { self == .mac ? "This Mac" : "This iPhone" }
        /// The other device a recorder moves between, when it isn't named: "your iPhone", "your Mac".
        public var other: String { self == .mac ? "your iPhone" : "your Mac" }
        /// A label as this device's controls set it: sentence case on the Mac, title case on the iPhone
        /// ("Import automatically", "Import Automatically").
        public func label(_ sentence: String) -> String { self == .mac ? sentence : SettingsWords.titleCased(sentence) }
    }

    // MARK: Fast Transfer

    /// An import over the recorder's own Wi‑Fi, which ends, and starts again from the beginning over Bluetooth, if
    /// Daybook leaves the screen: "Importing 1 of 3 · Starting Wi‑Fi…", then "Importing · 64% · Keep Daybook open".
    /// `short` is what a narrow line keeps ("Keep Daybook open").
    public static func fastTransfer(_ stage: FastTransferStage, importing: RecorderFacts.Importing) -> (text: String, short: String?) {
        let lead = importing.total > 1 ? "Importing \(importing.position) of \(importing.total)" : "Importing"
        switch stage {
        case .opening, .starting, .joining, .connecting:
            return ("\(lead) · Starting Wi‑Fi…", "Starting Wi‑Fi…")
        case .transferring:
            let percent = importing.fraction.map(ProcessingWords.percentText)
            return ([lead, percent, "Keep Daybook open"].compactMap { $0 }.joined(separator: " · "), "Keep Daybook open")
        case .closing:
            return ("\(lead) · Back to Bluetooth…", lead)
        }
    }

    // MARK: Figures

    /// Under figures the recorder hasn't confirmed since it was last connected: "As of today, 2:14 PM".
    public static func asOf(_ date: Date, now: Date = Date()) -> String {
        "As of \(DeviceDateFormat.lastSeen(date, now: now))"
    }

    /// A recorder's room as a figure: "210 hr", "< 1 hr", and "6 hr left" when it's nearly full.
    public static func storageFigure(hours: Double, low: Bool) -> String {
        hours < 1 ? "< 1 hr" : "\(StorageFormat.roundedHours(hours)) hr\(low ? " left" : "")"
    }

    /// The line under a battery figure: whether it's reported, low, or charging.
    public static func batteryDetail(_ battery: DeviceStatus.Battery?, stale: Bool) -> String? {
        if battery?.level == nil { return "Not reported" }
        if BatteryFormat.isLow(battery) { return "Charge soon" }
        if battery?.charging == true, !stale { return "Charging" }
        return nil
    }

    // MARK: The device page's import

    /// The import over its bar on the device page: "Importing 1 of 3 · about 6 min left", "Importing 1 of 3 ·
    /// Preparing…", Fast Transfer's words, or what the queue waits for ("2 recordings waiting for Soundcore"). Nil when
    /// nothing is importing.
    public static func importTitle(_ facts: RecorderFacts) -> String? {
        guard let importing = facts.importing else { return nil }
        if importing.suspended {
            return importing.total == 1 ? "1 recording waiting for \(facts.shortName)"
                : "\(importing.total) recordings waiting for \(facts.shortName)"
        }
        if let stage = facts.fastTransfer { return fastTransfer(stage, importing: importing).text }
        let text = "Importing \(importing.position) of \(importing.total)"
        if let wait = facts.otherAppWait { return "\(text) · \(wait)" }
        if importing.preparing { return "\(text) · Preparing…" }
        if let seconds = importing.secondsLeft { return "\(text) · \(TransferRateEstimator.label(secondsLeft: seconds))" }
        return text
    }

    /// The line under the import's bar while it comes over Bluetooth, the one thing that keeps it going: "Keep your
    /// Soundcore near this iPhone." Nothing over Wi‑Fi (the title says to keep Daybook open) or from a folder.
    public static func importNote(_ facts: RecorderFacts, wireless: Bool, on place: Place) -> String? {
        guard let importing = facts.importing, !importing.suspended, facts.fastTransfer == nil, wireless else { return nil }
        return "Keep your \(facts.shortName) near \(place.here)."
    }

    // MARK: Problems

    /// A device problem in this device's words. The framework words its problems for the Mac; the iPhone reaches
    /// Bluetooth through its own Settings, imports a file with Import Audio, and is the phone the Soundcore app runs on.
    public static func problem(_ problem: DeviceProblem, on place: Place) -> (title: String, message: String) {
        guard place == .iPhone, let issue = SoundcoreIssue(rawValue: problem.id) else { return (problem.title, problem.message) }
        switch issue {
        case .bluetoothDenied: return (problem.title, "Allow Bluetooth for Daybook in Settings.")
        case .bluetoothUnsupported: return ("This iPhone can’t connect to Soundcore", "Export recordings from the Soundcore app and import them with Import Audio.")
        case .notFound: return (problem.title, "Take it out of its case, close the Soundcore app, and bring it close to this iPhone.")
        case .connectTimeout: return (problem.title, "Take it out of its case to wake it, and close the Soundcore app.")
        case .rejected: return (problem.title, "Export from the Soundcore app and import the file instead.")
        case .listFailed: return (problem.title, "Close the Soundcore app, then refresh.")
        default: return (problem.title, problem.message)
        }
    }

    /// A problem's actions this device can take: the iPhone has no folder to set up (Import Audio does that job) and
    /// shows a recorder's technical facts on its Details screen.
    public static func problemActions(_ problem: DeviceProblem, on place: Place, excluding hidden: Set<DeviceProblemAction> = []) -> [DeviceProblemAction] {
        problem.actions.filter { action in
            guard !hidden.contains(action) else { return false }
            return place == .mac || ![.setUpFolder, .chooseFolder, .technicalDetails].contains(action)
        }
    }

    /// An action's title on this device: both open the system's settings, which the iPhone calls Settings.
    public static func actionTitle(_ action: DeviceProblemAction, on place: Place) -> String {
        switch (action, place) {
        case (.openBluetoothSettings, .iPhone), (.openPrivacySettings, .iPhone): return "Open Settings"
        default: return action.title
        }
    }

    // MARK: Adding a recorder

    /// What a kind is, in the list of recorders to add: a plain label, never how it connects.
    @MainActor
    public static func kindLabel(_ kind: DeviceKind) -> String {
        kind.id == SoundcoreWorkIntegration.id ? "Records on its own." : kind.summary
    }

    /// What to try while looking for the recorder, the same on both devices with each one's own words: the other
    /// device that may be holding it, and which one to bring it close to.
    @MainActor
    public static func discoveryTips(_ kind: DeviceKind, on place: Place) -> [DeviceTip] {
        guard kind.id == SoundcoreWorkIntegration.id else { return kind.discoveryTips }
        return [
            DeviceTip(symbol: "moon.zzz", text: "Take it out of its case."),
            DeviceTip(symbol: "xmark.app", text: place == .mac ? "Close the Soundcore app on your phone." : "Close the Soundcore app."),
            DeviceTip(symbol: place == .mac ? "iphone" : "laptopcomputer", text: "If \(place.other) manages it, wait a few minutes."),
            DeviceTip(symbol: "wave.3.right", text: "Bring it close to \(place.here).")
        ]
    }

    /// The discovery step's title: "Looking for Soundcore Work…", "Connecting to Soundcore Work…", "No Soundcore Found
    /// Nearby", or "Found Nearby".
    public static func discoveryTitle(_ kind: DeviceKind, searching: Bool, connecting: Bool, found: Bool) -> String {
        if searching { return "Looking for \(kind.name)…" }
        if connecting { return "Connecting to \(kind.name)…" }
        if !found { return "No \(kind.shortName) Found Nearby" }
        return "Found Nearby"
    }

    /// The discovery step's own action: Stop while it looks, Try Again when nothing was found, Look Again beside what
    /// it found; nothing while it connects.
    public static func discoveryAction(searching: Bool, connecting: Bool, found: Bool) -> String? {
        if searching { return "Stop" }
        if connecting { return nil }
        return found ? "Look Again" : "Try Again"
    }

    // MARK: Options

    /// A recorder's options, in one set of words for both devices (`Place.label` sets their case).
    public enum Option: Hashable, Sendable {
        case importAutomatically, recordAlong, fastTransfer, handBack

        public func title(on place: Place) -> String {
            switch self {
            case .importAutomatically: return place.label("Import automatically")
            case .recordAlong: return place.label("Record along with \(place.here)")
            case .fastTransfer: return place.label("Fast transfer")
            case .handBack: return place.label("Hand back to your Mac")
            }
        }
    }

    /// "Remove from This iPhone…": a recorder is set up on each device, and removing it here leaves the others.
    public static func removeTitle(on place: Place) -> String { "Remove from \(place.hereTitle)…" }

    /// The removal's confirmation: its consequence, the same on both devices.
    public static func removeConsequence(on place: Place) -> String {
        "\(place.hereTitle) stops importing from it. Recordings you already imported stay in your library."
    }
}

/// What can be done with a recorder now, as its page's buttons and its status card offer it: only what works now,
/// never a disabled button.
public enum RecorderAction: Hashable, Sendable {
    case connect
    case record
    case pause
    case importNew(Int)
    /// Connected, but the recorder didn't list its recordings: what's new isn't known.
    case checkForNew
    case listenLive
    case stopListening

    /// The words and glyph each app draws: "Record on Soundcore", shortened to "Record" where the row is tight, and
    /// said in full to VoiceOver.
    public struct Label: Equatable, Sendable {
        public var title: String
        public var shortTitle: String?
        public var symbol: String
        public var spoken: String
    }

    public func label(shortName: String) -> Label {
        switch self {
        case .connect: return Label(title: "Connect", symbol: "antenna.radiowaves.left.and.right", spoken: "Connect")
        case .record:
            return Label(title: "Record on \(shortName)", shortTitle: "Record", symbol: "record.circle", spoken: "Record on \(shortName)")
        case .pause:
            return Label(title: "Pause on \(shortName)", shortTitle: "Pause", symbol: "pause.circle", spoken: "Pause Recording on \(shortName)")
        case .importNew(let count):
            return Label(title: "Import \(count) New", symbol: "arrow.down.circle",
                         spoken: count == 1 ? "Import 1 New Recording" : "Import \(count) New Recordings")
        case .checkForNew:
            return Label(title: "Check for New Recordings", shortTitle: "Check for New", symbol: "arrow.clockwise",
                         spoken: "Check for New Recordings")
        case .listenLive: return Label(title: "Listen Live", symbol: "ear", spoken: "Listen Live")
        case .stopListening: return Label(title: "Stop Listening", symbol: "stop.circle", spoken: "Stop Listening")
        }
    }
}

public enum RecorderActions {
    /// The recorder's actions, in order: Connect, Record or Pause, Import N New, Check for New, Listen Live or Stop
    /// Listening. A recorder another device manages, or one without a direct link, has none here: moving it here is
    /// the handoff's.
    public static func available(_ facts: RecorderFacts) -> [RecorderAction] {
        guard facts.isDirect, facts.managedBy == nil, !facts.handoff.isPending else { return [] }
        var actions: [RecorderAction] = []
        let importRunning = facts.importing?.running == true
        if !facts.isLinked, facts.canConnect { actions.append(.connect) }
        if facts.hasRecordControl, facts.isLinked, !importRunning {
            actions.append(facts.isRecording ? .pause : .record)
        }
        if facts.newCount > 0, facts.importing == nil { actions.append(.importNew(facts.newCount)) }
        if facts.notListed, facts.isLinked, facts.importing == nil { actions.append(.checkForNew) }
        if facts.hasLiveListening {
            if facts.isListeningLive {
                actions.append(.stopListening)
            } else if facts.isRecording, facts.isLinked, !importRunning {
                actions.append(.listenLive)
            }
        }
        return actions
    }
}

/// Another Daybook seen from this one: a paired iPhone on a Mac's home and devices, a Mac on an iPhone's status sheet.
public struct PeerFacts: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case iPhone, mac }
    public enum Activity: Equatable, Sendable { case idle, recording, paused }

    public var id: String
    public var name: String
    public var kind: Kind
    public var isConnected: Bool
    public var activity: Activity
    /// When it was last heard from (the link, or its presence in the library).
    public var lastSeen: Date?
    /// A Mac that syncs the library but doesn't transcribe.
    public var notProcessing: Bool
    /// Conversations waiting for it (a Mac).
    public var waiting: Int

    public init(id: String, name: String, kind: Kind, isConnected: Bool, activity: Activity = .idle, lastSeen: Date? = nil,
                notProcessing: Bool = false, waiting: Int = 0) {
        self.id = id; self.name = name; self.kind = kind; self.isConnected = isConnected; self.activity = activity
        self.lastSeen = lastSeen; self.notProcessing = notProcessing; self.waiting = waiting
    }
}

public enum PeerStatusWords {
    /// "Alex's iPhone  Connected", "Studio Mac  Last seen today, 9:12 AM · 2 waiting".
    public static func line(_ peer: PeerFacts, now: Date = Date()) -> StatusLineWords {
        let symbol = peer.kind == .iPhone ? "iphone" : "desktopcomputer"
        let waiting = peer.waiting > 0 ? "\(peer.waiting) waiting" : nil
        func line(_ text: String, _ tone: StatusLineWords.Tone, short: String? = nil) -> StatusLineWords {
            StatusLineWords(id: "\(peer.kind == .iPhone ? "phone" : "mac")-\(peer.id)", symbol: symbol, title: peer.name, text: text,
                            tone: tone, shortText: short)
        }
        if peer.notProcessing { return line("Not set up to transcribe", .attention) }
        guard peer.isConnected else {
            let parts = [peer.activity == .recording ? "Recording" : nil, peer.lastSeen.map { RecorderStatusWords.lastSeen($0, now: now) }, waiting]
                .compactMap { $0 }
            return line(parts.isEmpty ? "Not connected" : parts.joined(separator: " · "), peer.activity == .recording ? .recording : .calm,
                        short: parts.isEmpty ? nil : "Not connected")
        }
        switch peer.activity {
        case .recording:
            return line(["Recording", waiting].compactMap { $0 }.joined(separator: " · "), .recording, short: waiting == nil ? nil : "Recording")
        case .paused: return line("Paused", .calm)
        case .idle:
            // Narrow, the waiting work stays: the teal glyph already says it's connected.
            return line(["Connected", waiting].compactMap { $0 }.joined(separator: " · "), .linked, short: waiting)
        }
    }
}
