import DaybookCore
import DaybookLink
import Foundation

/// What a conversation's page and its list row say about its processing, the same on the Mac and the iPhone
/// (docs/interface.md, "Status speaks only when there is something to say"). Plain values from `ProcessingStatus`
/// and what this device knows: how it calls itself (`DeviceWords`), what it can do (`LocalCapabilities`), a Mac's
/// live progress over the link and whether one is around, where the summary runs, and an upgrade on offer. Each
/// app draws it; neither decides what a state reads, looks like, or offers.
///
/// | Status | Page | Row |
/// |---|---|---|
/// | Recorded | box (accent): "Not transcribed yet" + Transcribe | "Not transcribed yet" + dot |
/// | Transcribed | line: "Not summarized yet" + Summarize | the preview |
/// | Queued here | line: "Waiting to transcribe after “Roadmap review”" + Cancel | "Waiting to transcribe" + clock |
/// | Waiting for models | box (accent): "Download models to transcribe this conversation" + Choose Models…, Download | "Waiting for models" |
/// | Paused here | line: "Paused" + Resume, or why ("Continues when Daybook is open") | "Paused" + pause glyph |
/// | Requested, waiting for a Mac | line: "Waiting for your Mac" + "Last seen 2 h ago", Cancel for its own | the same |
/// | Requested, this iPhone could do it | box (accent): "Download models to transcribe this conversation" + Download | the same |
/// | Requested, no device can summarize | line: "Needs your Mac to summarize" | the same |
/// | Processing | line: "Transcribing · 40%" (here), "Transcribing on Studio Mac · 40%" + bar | the same + 2 pt line |
/// | Couldn't finish | box (problem): `FailureWords` + Details…, the fix ("Couldn’t summarize with Claude Sonnet 5.5" + Cloud Settings…, Summarize on This Mac) | "Couldn’t finish" + warning |
/// | Waiting for a recording | line: "Waiting for audio from Alex's iPhone" + Don’t Wait | "Waiting for iPhone audio" |
/// | Done | an upgrade's line, or a note to dismiss, else nothing | the preview |
///
/// A working state is a bare line; a state that waits on the person is a quiet box with at most two actions.
public struct ConversationStatusPresentation: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// One quiet line: a working or waiting state.
        case line
        /// A state that needs the person: a quiet filled box with at most two actions.
        case box(Box)
    }

    /// What a box is about: something went wrong, something to do, or something to know.
    public enum Box: Equatable, Sendable { case problem, accent, info }

    /// What the person can do from the status, in the order shown.
    public enum Action: Equatable, Sendable {
        /// Transcribe the recordings without a transcript; `newAudio` when some are transcribed already.
        case transcribe(newAudio: Bool)
        /// Summarize a transcript that has no summary.
        case summarize
        /// Ask again for what failed.
        case tryAgain(ProcessingRequest.Mode)
        /// The device's own words.
        case details(String)
        /// This device's own work: pause it, take it up again, or take it out of the queue.
        case pause, resume, cancel
        /// Take back the request this device made that waits for another device (`ProcessingRequest.withdrawn`).
        case cancelRequest(UUID)
        /// Stop waiting for a recording made alongside, and finish with the audio that's here.
        case dontWait
        /// Stop the model download the work waits for.
        case cancelDownload
        /// Download the models the work needs (this many bytes).
        case downloadModels(bytes: Int64)
        case chooseModels
        case cloudSettings
        /// Summarize on this device instead ("This Mac", "This iPhone"), or ask your Mac.
        case summarizeHere(String), useYourMac
        /// Where its summary runs: Use the Cloud, Start Now, Wait for a Mac.
        case placement(SummaryPlacementPlanner.Action)
        /// Stop a summary running here or in the cloud.
        case stopSummary
        /// Redo a step with the better model, or put the offer away.
        case upgrade(UpgradeOffer), dismissUpgrade(UpgradeOffer)
        /// Clear the conversation's note.
        case dismiss

        public var title: String {
            switch self {
            case .transcribe(let newAudio): return newAudio ? "Transcribe New Audio" : "Transcribe"
            case .summarize: return "Summarize"
            case .tryAgain: return "Try Again"
            case .details: return "Details…"
            case .pause: return "Pause"
            case .resume: return "Resume"
            case .cancel, .cancelRequest, .cancelDownload: return "Cancel"
            case .dontWait: return "Don’t Wait"
            case .downloadModels: return "Download"
            case .chooseModels: return "Choose Models…"
            case .cloudSettings: return "Cloud Settings…"
            case .summarizeHere(let device): return "Summarize on \(device)"
            case .useYourMac: return "Use Your Mac"
            case .placement(let action): return action.title
            case .stopSummary: return "Stop"
            case .upgrade: return "Upgrade"
            case .dismissUpgrade, .dismiss: return "Dismiss"
            }
        }

        /// The one prominent button in a box; the rest are text links.
        public var isPrimary: Bool {
            switch self {
            case .transcribe, .tryAgain, .downloadModels: return true
            default: return false
            }
        }
    }

    public var kind: Kind
    public var symbol: String?
    public var title: String
    public var detail: String?
    /// 0...1 when the work reported a figure: a bar.
    public var progress: Double?
    /// Something runs with no figure to show: a small spinner.
    public var isWorking = false
    /// A countdown runs out then: the title changes every second (`title(at:)`).
    public var countdownUntil: Date?
    public var actions: [Action] = []

    public init(kind: Kind, symbol: String?, title: String, detail: String? = nil, progress: Double? = nil, isWorking: Bool = false,
                countdownUntil: Date? = nil, actions: [Action] = []) {
        self.kind = kind; self.symbol = symbol; self.title = title; self.detail = detail; self.progress = progress
        self.isWorking = isWorking; self.countdownUntil = countdownUntil; self.actions = actions
    }

    /// The title without its figure, for animating the line only when its words change, not at every percent.
    public var phrase: String {
        countdownUntil != nil ? "Summarizing in" : ProcessingWords.phrase(title)
    }

    /// The title at a moment: a countdown's seconds move with it ("Summarizing on this Mac in 11 s").
    public func title(at now: Date) -> String {
        guard let until = countdownUntil, let range = title.range(of: #" in \d+ s$"#, options: .regularExpression) else { return title }
        return title[..<range.lowerBound] + " in \(Self.secondsLeft(until, at: now)) s"
    }

    static func secondsLeft(_ until: Date, at now: Date) -> Int { max(1, Int(until.timeIntervalSince(now).rounded(.up))) }
}

// MARK: - Inputs

extension ConversationStatusPresentation {
    /// What this device can do about a conversation's processing.
    public struct LocalCapabilities: Equatable, Sendable {
        /// It processes recordings itself: a Mac always; an iPhone with processing on this iPhone turned on.
        public var processesHere: Bool
        /// It transcribes requests other devices make (a Mac), so a waiting one can be started here.
        public var transcribes: Bool
        /// It summarizes with its own models.
        public var summarizes: Bool
        /// Its own queue takes Pause, Resume, and Cancel (a Mac's).
        public var controlsQueue: Bool
        /// It downloads and chooses its models from here (a Mac's Settings › Models).
        public var managesModels: Bool
        /// What the models it would need take to download.
        public var missingModelBytes: Int64
        /// The download the work waits for, under way.
        public var download: Download?

        public struct Download: Equatable, Sendable {
            public var name: String
            public var fraction: Double
            public init(name: String, fraction: Double) { self.name = name; self.fraction = fraction }
        }

        public init(processesHere: Bool, transcribes: Bool, summarizes: Bool, controlsQueue: Bool, managesModels: Bool,
                    missingModelBytes: Int64 = 0, download: Download? = nil) {
            self.processesHere = processesHere; self.transcribes = transcribes; self.summarizes = summarizes
            self.controlsQueue = controlsQueue; self.managesModels = managesModels
            self.missingModelBytes = missingModelBytes; self.download = download
        }

        /// A Mac: it does it all.
        public static func mac(missingModelBytes: Int64 = 0, download: Download? = nil) -> LocalCapabilities {
            LocalCapabilities(processesHere: true, transcribes: true, summarizes: true, controlsQueue: true, managesModels: true,
                              missingModelBytes: missingModelBytes, download: download)
        }

        /// An iPhone: its own recordings when processing here is on, and summaries when its model is here.
        /// `missingModelBytes` is what transcribing here still needs to download, with processing here on.
        public static func iPhone(processesHere: Bool = false, summarizes: Bool = false, missingModelBytes: Int64 = 0,
                                  download: Download? = nil) -> LocalCapabilities {
            LocalCapabilities(processesHere: processesHere, transcribes: false, summarizes: summarizes, controlsQueue: false, managesModels: false,
                              missingModelBytes: processesHere ? missingModelBytes : 0, download: processesHere ? download : nil)
        }

        /// This device would transcribe its own recordings once its models are here: an iPhone with processing on
        /// and models still to download. A Mac's own downloads are its queue's (`requested(.models)`).
        var transcribesOwnAfterDownload: Bool { processesHere && !managesModels && (missingModelBytes > 0 || download != nil) }
    }

    /// A Mac's live progress on this conversation over the local link: finer and sooner than the claim that syncs.
    public struct LinkWork: Equatable, Sendable {
        public var phase: LinkProcessingProgress.Phase
        public var fraction: Double?
        /// The Mac's name.
        public var device: String
        /// Its countdown to summarizing runs out then, on this device's clock.
        public var countdownUntil: Date?
        /// Summarizing in the cloud, with this model.
        public var cloudModel: String?
        /// What the person may choose here for the Mac's countdown.
        public var placementActions: [SummaryPlacementPlanner.Action]

        public init(phase: LinkProcessingProgress.Phase, fraction: Double? = nil, device: String, countdownUntil: Date? = nil,
                    cloudModel: String? = nil, placementActions: [SummaryPlacementPlanner.Action] = []) {
            self.phase = phase; self.fraction = fraction.map { min(1, max(0, $0)) }; self.device = device
            self.countdownUntil = countdownUntil; self.cloudModel = cloudModel; self.placementActions = placementActions
        }

        /// From the link's message, received at `receivedAt`; `answerable` when this device can answer the Mac's
        /// countdown (it knows which Mac sent it).
        public init(_ progress: LinkProcessingProgress, receivedAt: Date, answerable: Bool) {
            var until: Date?
            var actions: [SummaryPlacementPlanner.Action] = []
            if progress.phase == .summaryCountdown, let countdown = progress.countdown {
                until = receivedAt.addingTimeInterval(max(0, countdown.secondsLeft))
                if answerable { actions = (countdown.cloudOffered ? [.useCloud] : []) + [.startNow] }
            }
            self.init(phase: progress.phase, fraction: progress.fraction, device: progress.macName, countdownUntil: until,
                      cloudModel: progress.cloudModel, placementActions: actions)
        }

        /// Finished or failed: the library says the rest.
        public var isFinished: Bool { phase == .finished || phase == .failed }

        /// The step, for the phases that are one.
        var stage: ProcessingRequest.Stage? {
            switch phase {
            case .transcribing, .aligning: return .transcribing
            case .identifyingSpeakers: return .identifyingSpeakers
            case .summarizing: return .summarizing
            default: return nil
            }
        }
    }

    /// Whether a Mac that transcribes is around, for a request that waits for one.
    public enum MacStanding: Equatable, Sendable {
        /// Not known yet (sync hasn't listed the library's devices).
        case checking
        /// Connected over the link now.
        case connected(String)
        /// Last heard from then (its presence, a claim, or work it synced); its name when known.
        case seen(name: String?, at: Date)
        /// Recording now.
        case recording(String)
        /// Connected, and working on another conversation.
        case busy(String)
        /// This device can't reach the library's other devices: iCloud is off or signed out here.
        case needsICloud
        /// Syncs this library but doesn't transcribe.
        case notProcessing(String)
        /// No Mac has synced this library.
        case noMac

        /// A Mac heard from within this long reads as present ("Waiting for Studio Mac").
        public static let recent: TimeInterval = 15 * 60

        /// The one way every place says no Mac has turned up (docs/iphone.md), with what to do.
        public static let noMacLine = "No Mac has synced this library yet. Open Daybook on your Mac."

        /// No Mac this device could ask has been heard from: nothing is coming unless the person acts.
        var isNoMac: Bool {
            switch self {
            case .noMac, .needsICloud: return true
            default: return false
            }
        }

        /// The Mac a request can expect soon, by name.
        func present(at now: Date) -> String? {
            switch self {
            case .connected(let name), .recording(let name), .busy(let name): return name
            case .seen(let name, let date): return now.timeIntervalSince(date) <= Self.recent ? name : nil
            default: return nil
            }
        }

        /// The line under a request that waits: nil while a Mac is around.
        func detail(at now: Date) -> String? {
            switch self {
            case .checking, .connected: return nil
            case .seen(_, let date):
                let age = now.timeIntervalSince(date)
                return age <= Self.recent ? nil : "Last seen \(Self.ago(age))"
            case .recording(let name): return "\(name) is recording"
            case .busy(let name): return "\(name) is working on another conversation"
            case .notProcessing(let name): return "\(name) isn’t set up to transcribe. Finish in Daybook › Settings on \(name)."
            case .needsICloud: return "Needs iCloud"
            case .noMac: return Self.noMacLine
            }
        }

        /// "5 min ago", "2 h ago", "3 days ago".
        public static func ago(_ seconds: TimeInterval) -> String {
            let minutes = Int(max(0, seconds) / 60)
            if minutes < 60 { return "\(max(1, minutes)) min ago" }
            let hours = minutes / 60
            if hours < 48 { return "\(hours) h ago" }
            return "\(hours / 24) days ago"
        }
    }

    /// Where the conversation's summary runs, when that's what there is to say (docs/multipoint.md, "Where summaries run").
    public struct Placement: Equatable, Sendable {
        /// This device's countdown or wait.
        public var planner: SummaryPlacementPlanner?
        /// A summary running here or in the cloud.
        public var run: SummaryPlace?
        /// The cloud is on offer for a Summarize request still waiting for a Mac.
        public var cloudOffered: Bool

        public init(planner: SummaryPlacementPlanner? = nil, run: SummaryPlace? = nil, cloudOffered: Bool = false) {
            self.planner = planner; self.run = run; self.cloudOffered = cloudOffered
        }
    }

    /// Everything besides the status and the conversation.
    public struct Inputs: Equatable, Sendable {
        public var words: DeviceWords
        public var local: LocalCapabilities
        /// This device is recording the conversation now: its capture speaks, not processing.
        public var isRecording = false
        public var link: LinkWork?
        public var mac: MacStanding?
        public var placement = Placement()
        /// The upgrade on offer (`Upgrades.offer`), shown only when nothing else is to say.
        public var upgrade: UpgradeOffer?
        /// The conversation this device processes now, for "after “Roadmap review”".
        public var runningTitle: String?
        /// This device's queue waits for a model download before it goes on.
        public var queueWaitsForDownload = false
        /// What a conversation queued here was asked for.
        public var queuedMode: ProcessingRequest.Mode?
        /// Every recording it still needs transcribed was made or brought in on this device, which processes only
        /// its own (`OnDeviceProcessing`; always true on a Mac, which takes any).
        public var ownsUntranscribed: Bool
        /// Why this device's work on it is paused.
        public var pause: ProcessingWords.PauseReason?
        /// The cloud model this device summarizes with ("Claude Sonnet 5.5"), to name in a cloud failure.
        public var cloudModel: String?
        /// Rows: it's playing now, or its work just finished (the checkmark holds for a moment).
        public var isPlaying = false
        public var justFinished = false

        public init(words: DeviceWords, local: LocalCapabilities, isRecording: Bool = false, link: LinkWork? = nil, mac: MacStanding? = nil,
                    placement: Placement = Placement(), upgrade: UpgradeOffer? = nil, runningTitle: String? = nil,
                    queueWaitsForDownload: Bool = false, queuedMode: ProcessingRequest.Mode? = nil, ownsUntranscribed: Bool = true,
                    pause: ProcessingWords.PauseReason? = nil, cloudModel: String? = nil, isPlaying: Bool = false,
                    justFinished: Bool = false) {
            self.words = words; self.local = local; self.isRecording = isRecording; self.link = link; self.mac = mac
            self.placement = placement; self.upgrade = upgrade; self.runningTitle = runningTitle
            self.queueWaitsForDownload = queueWaitsForDownload; self.queuedMode = queuedMode; self.ownsUntranscribed = ownsUntranscribed
            self.pause = pause
            self.cloudModel = cloudModel; self.isPlaying = isPlaying; self.justFinished = justFinished
        }
    }
}

// MARK: - The page

extension ConversationStatusPresentation {
    /// The page's status, or nil when there's nothing to say. Recording is this device's own capture's to say.
    public static func page(_ status: ProcessingStatus, meeting: Meeting, inputs: Inputs, now: Date = Date()) -> ConversationStatusPresentation? {
        guard !inputs.isRecording else { return nil }
        if let placing = placement(status, inputs: inputs, now: now) { return placing }
        if let link = inputs.link, !link.isFinished, let live = linkLine(link) { return live }
        let words = inputs.words, local = inputs.local
        switch status {
        case .processing(let progress):
            let here = isHere(progress, words: words)
            var line = ConversationStatusPresentation(kind: .line, symbol: here ? words.symbol : symbol(forDevice: progress.device?.name),
                                                      title: workingTitle(progress, words: words), progress: progress.fraction,
                                                      isWorking: progress.fraction == nil)
            if !progress.awaiting.isEmpty { line.detail = ProcessingStatus.awaitingLine(progress.awaiting) }
            else if here, let origin = requestOrigin(meeting, words: words) { line.detail = origin }
            if here, local.controlsQueue { line.actions = [progress.stage == .summarizing ? .stopSummary : .pause] }
            return line

        case .requested(.queued(let position, let after)):
            // Position 0 is next: after the conversation running now, when one is.
            let behind: ProcessingWords.QueuedBehind
            if position > 0 { behind = .position(ahead: position + (after == nil ? 0 : 1)) }
            else if inputs.queueWaitsForDownload { behind = .download }
            else if let title = inputs.runningTitle { behind = .conversation(title) }
            else { behind = .nothing }
            return ConversationStatusPresentation(kind: .line, symbol: "clock", title: ProcessingWords.waitingHere(inputs.queuedMode, behind: behind),
                                                  actions: local.controlsQueue ? [.cancel] : [])

        case .requested(.models):
            if local.download != nil { return downloadHere(local) }
            guard local.managesModels else {
                return ConversationStatusPresentation(kind: .line, symbol: "arrow.down.circle", title: "Waiting for models")
            }
            return ConversationStatusPresentation(kind: .box(.accent), symbol: "arrow.down.circle.fill",
                                                  title: "Download models to transcribe this conversation",
                                                  detail: local.missingModelBytes > 0 ? ByteSize.format(local.missingModelBytes) : nil,
                                                  actions: [.chooseModels, .downloadModels(bytes: local.missingModelBytes)])

        case .requested(.paused):
            let reason = inputs.pause ?? (local.controlsQueue ? .person : nil)
            return ConversationStatusPresentation(kind: .line, symbol: "pause.circle", title: "Paused",
                                                  detail: reason.flatMap { ProcessingWords.pausedLine($0, device: words.hereDeviceName) },
                                                  actions: local.controlsQueue ? [.resume] : [])

        case .requested(.device(let request)):
            let mine = request.requestedBy.id == words.thisDeviceID
            // What this device asked for and no device has started can be taken back.
            let cancel: [Action] = mine ? [.cancelRequest(request.id)] : []
            if let upgrade = request.upgrade, !meeting.hasUntranscribedAudio {
                // An upgrade waits for the device with the better model; Cancel brings the offer back.
                return ConversationStatusPresentation(kind: .line, symbol: "clock", title: upgrade.waitingLine, actions: cancel)
            }
            if local.transcribes, !mine, meeting.hasUntranscribedAudio {
                // Asked for on another device, and this one can do it.
                return ConversationStatusPresentation(kind: .box(.accent), symbol: "waveform.circle.fill",
                                                      title: "Requested from \(request.requestedBy.name)",
                                                      actions: [.transcribe(newAudio: !meeting.transcripts.isEmpty)])
            }
            let mac = inputs.mac?.present(at: now)
            if mine, mac == nil, request.mode == .newAudio, inputs.ownsUntranscribed, meeting.hasUntranscribedTranscribableAudio,
               local.transcribesOwnAfterDownload {
                // This device would transcribe its own recording once its models are here, and no Mac is around to.
                return downloadHere(local)
            }
            if request.mode == .summaryOnly, !local.summarizes, inputs.mac?.isNoMac == true {
                // Nothing here or anywhere it can reach summarizes: a fact, not a wait.
                return ConversationStatusPresentation(kind: .line, symbol: "desktopcomputer", title: Self.needsMacToSummarize,
                                                      detail: inputs.mac?.detail(at: now), actions: cancel)
            }
            return ConversationStatusPresentation(kind: .line, symbol: "clock",
                                                  title: ProcessingWords.waitingForMac(request.mode, summarized: meeting.summary != nil, device: mac),
                                                  detail: inputs.mac?.detail(at: now),
                                                  actions: cancel)

        case .failed(let failure):
            return failed(failure, meeting: meeting, inputs: inputs)

        case .recorded:
            guard !meeting.tracks.isEmpty else { return nil }
            // Nothing happens until the person asks: a box, with the one thing to do.
            let newAudio = !meeting.transcripts.isEmpty
            return ConversationStatusPresentation(kind: .box(.accent), symbol: "waveform.circle.fill",
                                                  title: newAudio ? "A new recording isn’t transcribed yet" : "Not transcribed yet",
                                                  actions: [.transcribe(newAudio: newAudio)])

        case .transcribed:
            if !local.summarizes, !inputs.placement.cloudOffered, inputs.mac?.isNoMac == true {
                // Summarize would only wait: nothing here, no Mac, and no cloud summarizes.
                return ConversationStatusPresentation(kind: .line, symbol: "desktopcomputer", title: needsMacToSummarize,
                                                      detail: inputs.mac?.detail(at: now))
            }
            return ConversationStatusPresentation(kind: .line, symbol: "text.alignleft", title: "Not summarized yet", actions: [.summarize])

        case .awaitingRecordings(let recordings):
            return ConversationStatusPresentation(kind: .line, symbol: "clock", title: ProcessingStatus.awaitingDetail(recordings),
                                                  actions: [.dontWait])

        case .done:
            if let offer = inputs.upgrade {
                return ConversationStatusPresentation(kind: .line, symbol: "arrow.up.circle", title: offer.line,
                                                      actions: [.upgrade(offer), .dismissUpgrade(offer)])
            }
            guard let message = meeting.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else { return nil }
            return ConversationStatusPresentation(kind: .box(.info), symbol: "info.circle.fill", title: message, actions: [.dismiss])
        }
    }

    /// Where the summary runs, said first: a summary running here or in the cloud, this device's countdown or wait, a
    /// Mac's countdown over the link, or Use the Cloud for a Summarize request still waiting for a Mac.
    static func placement(_ status: ProcessingStatus, inputs: Inputs, now: Date) -> ConversationStatusPresentation? {
        let words = inputs.words, placement = inputs.placement
        if let run = placement.run {
            return ConversationStatusPresentation(kind: .line, symbol: nil,
                                                  title: "Summarizing \(SummaryPlacementPlanner.where(run, thisDevice: words.here))",
                                                  isWorking: true, actions: [.stopSummary])
        }
        if let planner = placement.planner, let title = planner.line(at: now, thisDevice: words.here) {
            var line = ConversationStatusPresentation(kind: .line, symbol: "clock", title: title, countdownUntil: planner.deadline,
                                                      actions: planner.actions.map(Action.placement))
            if case .started(.cloud) = planner.phase { line.symbol = nil; line.isWorking = true; line.countdownUntil = nil }
            // Waiting for a Mac with the cloud on offer: Use the Cloud makes it, so it's a wait, not "Needs your Mac".
            if planner.phase == .waitingForMac { line.detail = inputs.mac?.detail(at: now) }
            return line
        }
        if let link = inputs.link, link.phase == .summaryCountdown, let until = link.countdownUntil {
            return ConversationStatusPresentation(kind: .line, symbol: "clock",
                                                  title: "Summarizing on \(link.device) in \(secondsLeft(until, at: now)) s",
                                                  countdownUntil: until, actions: link.placementActions.map(Action.placement))
        }
        if let link = inputs.link, link.phase == .summarizing, let model = link.cloudModel {
            return ConversationStatusPresentation(kind: .line, symbol: nil, title: "Summarizing with \(model)", isWorking: true)
        }
        if placement.cloudOffered, case .requested(.device(let request)) = status, request.mode == .summaryOnly, request.upgrade == nil {
            let mine = request.requestedBy.id == words.thisDeviceID
            return ConversationStatusPresentation(kind: .line, symbol: "clock", title: "Waiting for a Mac to summarize",
                                                  detail: inputs.mac?.detail(at: now),
                                                  actions: [.placement(.useCloud)] + (mine ? [.cancelRequest(request.id)] : []))
        }
        return nil
    }

    /// A Mac's live progress, while it works: "Transcribing on Studio Mac · 40%", "In line on Studio Mac".
    static func linkLine(_ link: LinkWork) -> ConversationStatusPresentation? {
        if let stage = link.stage {
            return ConversationStatusPresentation(kind: .line, symbol: "desktopcomputer",
                                                  title: ProcessingWords.elsewhere(stage, device: link.device, fraction: link.fraction),
                                                  progress: link.fraction, isWorking: link.fraction == nil)
        }
        switch link.phase {
        case .queued: return ConversationStatusPresentation(kind: .line, symbol: "clock", title: "In line on \(link.device)")
        case .paused: return ConversationStatusPresentation(kind: .line, symbol: "pause.circle", title: "Paused on \(link.device)")
        case .waitingForModels:
            return ConversationStatusPresentation(kind: .line, symbol: "arrow.down.circle", title: "Waiting for models on \(link.device)")
        default: return nil
        }
    }

    /// "Needs your Mac to summarize": no device this one can reach summarizes, and no cloud model is on offer.
    public static let needsMacToSummarize = "Needs your Mac to summarize"

    /// A download this device makes to do the work itself: under way, a line with its figure and Cancel; else a box
    /// with Download and its size.
    static func downloadHere(_ local: LocalCapabilities) -> ConversationStatusPresentation {
        if let download = local.download {
            return ConversationStatusPresentation(kind: .line, symbol: "arrow.down.circle",
                                                  title: "Downloading \(download.name) · \(ProcessingWords.percentText(download.fraction))",
                                                  progress: download.fraction, actions: [.cancelDownload])
        }
        return ConversationStatusPresentation(kind: .box(.accent), symbol: "arrow.down.circle.fill",
                                              title: "Download models to transcribe this conversation",
                                              detail: local.missingModelBytes > 0 ? ByteSize.format(local.missingModelBytes) : nil,
                                              actions: [.downloadModels(bytes: local.missingModelBytes)])
    }

    /// The last attempt failed: a problem box in `FailureWords`, with what fixes it. Trying again can't find speech
    /// that isn't there, so a silent recording offers only its details.
    static func failed(_ failure: ProcessingStatus.Failure, meeting: Meeting, inputs: Inputs) -> ConversationStatusPresentation {
        let words = FailureWords(failure, words: inputs.words, cloudModel: inputs.cloudModel)
        let local = inputs.local
        let here = inputs.words.isHere(failure.device)
        // What failed is asked for again: the request's own work, else the transcript or, once there is one, the summary.
        let mode = failure.request?.mode
            ?? (meeting.hasUntranscribedTranscribableAudio || !failure.hadTranscripts ? .newAudio : .summaryOnly)
        let retry: Action? = meeting.tracks.isEmpty ? nil : .tryAgain(mode)
        var fix: [Action] = []
        switch failure.kind {
        case .noSpeech, .recordingDidNotStart:
            break
        case .modelsMissing:
            // Download what's still missing here; once nothing is, the work can simply run again.
            if here, local.managesModels, local.missingModelBytes > 0 { fix = [.downloadModels(bytes: local.missingModelBytes)] }
            else if here, local.managesModels { fix = retry.map { [$0] } ?? [.chooseModels] }
            else { fix = retry.map { [$0] } ?? [] }
        case .modelCouldNotStart:
            if here, local.managesModels { fix = [.chooseModels] + (retry.map { [$0] } ?? []) }
            else { fix = retry.map { [$0] } ?? [] }
        case .cloud(let cloud):
            // Elsewhere: this device's own summarizer, else your Mac when there's one to ask.
            let elsewhere: [Action] = local.summarizes ? [.summarizeHere(inputs.words.hereTitle)]
                : inputs.mac?.isNoMac == true ? [] : [.useYourMac]
            switch cloud {
            case .badKey, .noCredit, .modelUnavailable:
                // Asking the same key again can't help: its settings can.
                fix = [.cloudSettings] + elsewhere
            default:
                // Trying again helps only with the cloud's passing troubles (offline, busy, limited, cut off).
                let again: [Action] = failure.kind.isTransient ? (retry.map { [$0] } ?? []) : []
                fix = again + elsewhere
            }
        case .plainReason, .other:
            fix = retry.map { [$0] } ?? []
        }
        // At most two actions: the details come first when there's room for them.
        let details: [Action] = failure.reason.isEmpty ? [] : [.details(failure.reason)]
        let actions = fix.count >= 2 ? Array(fix.prefix(2)) : details + fix
        return ConversationStatusPresentation(kind: .box(.problem), symbol: "exclamationmark.triangle.fill", title: words.title,
                                              detail: words.message, actions: actions)
    }

    /// "Transcribing · 40%" for work here (on an iPhone, "Transcribing on this iPhone · 40%"), "Transcribing on
    /// Studio Mac · 40%" for another device's.
    public static func workingTitle(_ progress: ProcessingStatus.Progress, words: DeviceWords) -> String {
        guard isHere(progress, words: words) else {
            return ProcessingWords.elsewhere(progress.stage, device: words.name(of: progress.device), fraction: progress.fraction)
        }
        if !words.namesItself { return ProcessingWords.progressLine(progress.stage, fraction: progress.fraction) }
        return ProcessingWords.elsewhere(progress.stage, device: words.here, fraction: progress.fraction)
    }

    /// Work with no device named is this device's own queue's, on both apps (`ProcessingStatus(_:queue:)`); a
    /// failure's unknown device is another matter (`DeviceWords.unknown`).
    static func isHere(_ progress: ProcessingStatus.Progress, words: DeviceWords) -> Bool {
        progress.device == nil || words.isHere(progress.device)
    }

    /// Who asked for the work this device does, when another device did: "Requested from Alex's iPhone".
    static func requestOrigin(_ meeting: Meeting, words: DeviceWords) -> String? {
        guard let request = meeting.openProcessingRequests.last(where: { $0.requestedBy.id != words.thisDeviceID }) else { return nil }
        return "Requested from \(request.requestedBy.name)"
    }

    /// Another device's glyph: an iPhone's, else a Mac's.
    static func symbol(forDevice name: String?) -> String {
        name?.localizedCaseInsensitiveContains("iPhone") == true ? "iphone" : "desktopcomputer"
    }
}

extension DeviceWords {
    /// "iPhone" or "Mac", for "Continues when iPhone cools down".
    var hereDeviceName: String { here.hasPrefix("this ") ? String(here.dropFirst(5)) : here }
}

// MARK: - The row

/// What a list row says about a conversation that isn't ready, the same on both apps: a glyph by its kind, and a
/// line of words in place of the preview.
public struct ConversationRowStatus: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case recording, processing, waiting, waitingForModels, paused, failed, notTranscribed, playing, justFinished

        /// The row's glyph: nil for processing (the 2 pt gradient line) and not transcribed (the accent dot).
        public var symbol: String? {
            switch self {
            case .recording: return "record.circle.fill"
            case .processing, .notTranscribed: return nil
            case .waiting: return "clock"
            case .waitingForModels: return "arrow.down.circle"
            case .paused: return "pause.circle"
            case .failed: return "exclamationmark.triangle.fill"
            case .playing: return "waveform"
            case .justFinished: return "checkmark.circle.fill"
            }
        }
    }

    public var kind: Kind
    /// The words in place of the preview; nil keeps the preview (playing, just finished).
    public var text: String?
    /// How far processing has got, for the row's progress line.
    public var fraction: Double?
    /// A summary's countdown runs out then: the row counts down to it ("Summarizing in 12 s").
    public var countdownUntil: Date?

    public init(kind: Kind, text: String?, fraction: Double? = nil, countdownUntil: Date? = nil) {
        self.kind = kind; self.text = text; self.fraction = fraction; self.countdownUntil = countdownUntil
    }

    /// The words without their figure: the line fades when what it says changes, not at every percent.
    public var phrase: String? {
        if countdownUntil != nil { return "Summarizing in" }
        return text.map(ProcessingWords.phrase)
    }

    /// The words at a moment: a countdown's seconds move with it.
    public func text(at now: Date) -> String? {
        guard let until = countdownUntil else { return text }
        return "Summarizing in \(ConversationStatusPresentation.secondsLeft(until, at: now)) s"
    }
}

extension ConversationStatusPresentation {
    /// The row's status, or nil when everything is fine (the row shows its preview). Rows never offer an upgrade.
    public static func row(_ status: ProcessingStatus, meeting: Meeting, inputs: Inputs, now: Date = Date()) -> ConversationRowStatus? {
        if inputs.isRecording { return ConversationRowStatus(kind: .recording, text: "Recording now") }
        let words = inputs.words, placement = inputs.placement
        if let run = placement.run {
            return ConversationRowStatus(kind: .processing, text: "Summarizing \(SummaryPlacementPlanner.where(run, thisDevice: words.here))")
        }
        if let planner = placement.planner, let text = planner.shortLine(at: now) {
            if case .started(.cloud) = planner.phase { return ConversationRowStatus(kind: .processing, text: text) }
            return ConversationRowStatus(kind: .waiting, text: text, countdownUntil: planner.deadline)
        }
        if let link = inputs.link, !link.isFinished, let row = linkRow(link, now: now) { return row }
        if let row = statusRow(status, meeting: meeting, inputs: inputs, now: now) { return row }
        if inputs.isPlaying { return ConversationRowStatus(kind: .playing, text: nil) }
        if inputs.justFinished { return ConversationRowStatus(kind: .justFinished, text: nil) }
        return nil
    }

    static func linkRow(_ link: LinkWork, now: Date) -> ConversationRowStatus? {
        if link.phase == .summaryCountdown, let until = link.countdownUntil {
            return ConversationRowStatus(kind: .waiting, text: "Summarizing in \(secondsLeft(until, at: now)) s", countdownUntil: until)
        }
        if link.phase == .summarizing, let model = link.cloudModel { return ConversationRowStatus(kind: .processing, text: "Summarizing with \(model)") }
        if let stage = link.stage {
            return ConversationRowStatus(kind: .processing, text: ProcessingWords.elsewhere(stage, device: link.device, fraction: link.fraction),
                                         fraction: link.fraction)
        }
        switch link.phase {
        case .queued: return ConversationRowStatus(kind: .waiting, text: "In line on \(link.device)")
        case .paused: return ConversationRowStatus(kind: .paused, text: "Paused on \(link.device)")
        case .waitingForModels: return ConversationRowStatus(kind: .waitingForModels, text: "Waiting for models on \(link.device)")
        default: return nil
        }
    }

    static func statusRow(_ status: ProcessingStatus, meeting: Meeting, inputs: Inputs, now: Date = Date()) -> ConversationRowStatus? {
        let words = inputs.words
        switch status {
        case .processing(let progress):
            return ConversationRowStatus(kind: .processing, text: workingTitle(progress, words: words), fraction: progress.fraction ?? 0)
        case .requested(.queued):
            return ConversationRowStatus(kind: .waiting, text: ProcessingWords.waitingHereShort(inputs.queuedMode))
        case .requested(.models):
            return ConversationRowStatus(kind: .waitingForModels, text: "Waiting for models")
        case .requested(.paused):
            return ConversationRowStatus(kind: .paused, text: "Paused")
        case .requested(.device(let request)):
            // As the page: an upgrade's own line only while there's no new audio to transcribe first.
            if let upgrade = request.upgrade, !meeting.hasUntranscribedAudio { return ConversationRowStatus(kind: .waiting, text: upgrade.shortLine) }
            let mine = request.requestedBy.id == words.thisDeviceID
            if inputs.local.transcribes, !mine, meeting.hasUntranscribedAudio {
                return ConversationRowStatus(kind: .waiting, text: "Requested from \(request.requestedBy.name)")
            }
            // As the page: this device's own download, or a summary nothing can make.
            if mine, inputs.mac?.present(at: now) == nil, request.mode == .newAudio, inputs.ownsUntranscribed,
               meeting.hasUntranscribedTranscribableAudio, inputs.local.transcribesOwnAfterDownload {
                return ConversationRowStatus(kind: .waitingForModels, text: "Waiting for models")
            }
            if request.mode == .summaryOnly, !inputs.local.summarizes, inputs.mac?.isNoMac == true {
                return ConversationRowStatus(kind: .waiting, text: needsMacToSummarize)
            }
            return ConversationRowStatus(kind: .waiting, text: ProcessingWords.waitingForMac(request.mode, summarized: meeting.summary != nil))
        case .failed(let failure):
            return ConversationRowStatus(kind: .failed, text: failure.isNoSpeech ? "No speech" : "Couldn’t finish")
        case .recorded:
            return meeting.tracks.isEmpty ? nil : ConversationRowStatus(kind: .notTranscribed, text: "Not transcribed yet")
        case .awaitingRecordings(let recordings):
            return ConversationRowStatus(kind: .waiting, text: ProcessingStatus.awaitingLine(recordings))
        case .transcribed, .done:
            return nil
        }
    }
}
