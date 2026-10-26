import DaybookKit
import Foundation

/// What the page and the list say about a conversation's processing, from DaybookKit's
/// `ProcessingStatus` (docs/iphone.md, "Processing on the Mac"). The phone never processes, so
/// every working state names the Mac doing the work, and nothing ever fakes progress.
///
/// | Status | Page | Row |
/// |---|---|---|
/// | Recorded | "Not transcribed yet" | "Not transcribed yet" + teal dot |
/// | Requested | "Waiting for your Mac" (+ "Last seen 2 h ago") | "Waiting for your Mac" + clock |
/// | Processing | "Transcribing on Studio · 40%" + gradient bar | same words + a 2 pt gradient line |
/// | Couldn't finish | a box with the Mac's reason, Try Again, Details | "Couldn't finish" + warning |
/// | Done | nothing | the preview |
struct StatusPresentation: Equatable {
    enum Kind: Equatable {
        /// One quiet line: a working or waiting state.
        case line
        /// A state that needs the person: a quiet filled box with at most two actions.
        case problem
        /// Something worth knowing, dismissible.
        case info
    }

    enum Action: Equatable {
        /// Writes a new request for the Mac (Try Again).
        case request(ProcessingRequest.Mode)
        /// The Mac's own words.
        case details(String)
        /// Clears the conversation's message.
        case dismiss
    }

    var kind: Kind
    var symbol: String?
    var title: String
    var detail: String?
    /// 0...1 when the Mac reported a figure; nil shows no bar.
    var progress: Double?
    /// Shows a small spinner: something is running with no figure to show.
    var isWorking = false
    var actions: [Action] = []

    /// The page's status, or nil when there's nothing to say.
    static func page(_ status: ProcessingStatus, meeting: Meeting, sighting: MacSighting?, now: Date = Date()) -> StatusPresentation? {
        switch status {
        case .recorded:
            return StatusPresentation(kind: .line, symbol: "waveform", title: "Not transcribed yet")
        case .requested(let waiting):
            let mode: ProcessingRequest.Mode
            if case .device(let request) = waiting { mode = request.mode } else { mode = .newAudio }
            return StatusPresentation(kind: .line, symbol: "clock", title: waitingTitle(mode),
                                      detail: MacSighting.line(sighting, now: now))
        case .processing(let progress):
            return StatusPresentation(kind: .line, symbol: nil, title: workingTitle(progress),
                                      progress: progress.fraction, isWorking: progress.fraction == nil)
        case .failed(let failure):
            let silent = FriendlyError.isNoSpeech(failure.reason)
            var actions: [Action] = []
            if !silent && !meeting.tracks.isEmpty { actions.append(.request(failure.request?.mode ?? .newAudio)) }
            if !failure.reason.isEmpty { actions.append(.details(failure.reason)) }
            return StatusPresentation(
                kind: .problem, symbol: "exclamationmark.triangle.fill",
                title: silent ? "No speech in this recording" : "Couldn’t finish \(failure.hadTranscripts ? "summarizing" : "transcribing")",
                detail: silent ? "The audio is saved." : FriendlyError.message(for: failure.reason, device: failure.device?.name),
                actions: actions)
        case .done:
            guard let message = meeting.errorMessage, !message.isEmpty else { return nil }
            return StatusPresentation(kind: .info, symbol: "info.circle.fill", title: message, actions: [.dismiss])
        }
    }

    /// The row's words and glyph when a conversation isn't ready; nil when everything is fine.
    static func row(_ status: ProcessingStatus) -> RowStatus? {
        switch status {
        case .recorded: return RowStatus(kind: .notTranscribed, text: "Not transcribed yet")
        case .requested(let waiting):
            if case .device(let request) = waiting { return RowStatus(kind: .waiting, text: waitingTitle(request.mode)) }
            return RowStatus(kind: .waiting, text: "Waiting for your Mac")
        case .processing(let progress):
            return RowStatus(kind: .processing, text: workingTitle(progress), fraction: progress.fraction)
        case .failed: return RowStatus(kind: .failed, text: "Couldn’t finish")
        case .done: return nil
        }
    }

    static func waitingTitle(_ mode: ProcessingRequest.Mode) -> String {
        switch mode {
        case .newAudio: return "Waiting for your Mac"
        case .summaryOnly: return "Waiting for your Mac to summarize again"
        case .speakerRefresh: return "Waiting for your Mac to identify speakers again"
        case .fullRetranscription: return "Waiting for your Mac to transcribe everything again"
        }
    }

    static func workingTitle(_ progress: ProcessingStatus.Progress) -> String {
        let verb: String
        switch progress.stage {
        case .transcribing: verb = "Transcribing"
        case .identifyingSpeakers: verb = "Identifying speakers"
        case .summarizing: verb = "Summarizing"
        }
        let place = progress.device.map { " on \($0.name)" } ?? " on this iPhone"
        let figure = progress.fraction.map { " · \(Int(($0 * 100).rounded()))%" } ?? ""
        return verb + place + figure
    }
}

/// What a list row says about a conversation that isn't ready.
struct RowStatus: Equatable {
    enum Kind: Equatable { case notTranscribed, waiting, processing, failed }
    var kind: Kind
    var text: String
    var fraction: Double?
}

/// When a Mac was last heard from, for "Last seen 2 h ago". The library carries the evidence: a
/// Mac's claim heartbeats and finished requests, and the transcripts and summaries it wrote. The
/// local link, which knows sooner, can inject its own through `\.macSighting`.
struct MacSighting: Equatable {
    var name: String?
    var date: Date

    /// The latest sign of a Mac at work in any conversation, other than this device's own requests.
    static func latest(in meetings: [Meeting], excluding deviceID: String?) -> MacSighting? {
        var best: MacSighting?
        func consider(_ date: Date, _ name: String?) {
            if best == nil || date > best!.date { best = MacSighting(name: name, date: date) }
        }
        for meeting in meetings {
            for request in meeting.processingRequests ?? [] {
                if let claim = request.claim, claim.device.id != deviceID { consider(claim.heartbeat, claim.device.name) }
                if let outcome = request.outcome, outcome.device.id != deviceID { consider(outcome.finishedAt, outcome.device.name) }
            }
            for run in meeting.transcripts { consider(run.createdAt, nil) }
            if let summary = meeting.summary { consider(summary.createdAt, nil) }
        }
        return best
    }

    /// "Last seen 2 h ago" when no Mac has checked in for a while; nil when one has, recently.
    static func line(_ sighting: MacSighting?, now: Date, recent: TimeInterval = 15 * 60) -> String? {
        guard let sighting else { return "No Mac has checked in yet. Open Daybook on your Mac." }
        let age = now.timeIntervalSince(sighting.date)
        guard age > recent else { return nil }
        return "Last seen \(ago(age))"
    }

    /// "5 min ago", "2 h ago", "3 days ago".
    static func ago(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        if minutes < 60 { return "\(max(1, minutes)) min ago" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours) h ago" }
        return "\(hours / 24) days ago"
    }
}

/// Plain-language reasons for processing failures. The Mac's own words stay one tap away.
enum FriendlyError {
    /// The recording worked but holds no speech; trying again can't help.
    static func isNoSpeech(_ error: String) -> Bool { error.lowercased().contains("no speech") }

    static func message(for error: String, device: String?) -> String {
        let lower = error.lowercased()
        let mac = device ?? "your Mac"
        if lower.contains("download") || lower.contains("not installed") { return "The models it needs aren’t on \(mac) yet. The recording is saved." }
        if lower.contains("memory") || lower.contains("language model") { return "The summary model couldn’t start on \(mac). The recording is saved." }
        return "Something went wrong on \(mac). The recording is saved."
    }
}

/// Plain words for an error on this iPhone. Daybook's own errors already say what happened and what
/// to do; the system's don't, so they get a sentence of their own and keep their words for Details.
enum PlainError {
    static func message(for error: Error, fallback: String) -> (message: String, details: String?) {
        switch error {
        case is AudioProvidingError, is PhotoProvidingError, is PhoneRecorderError, is PhotoStoreError:
            return (error.localizedDescription, nil)
        default:
            let words = error.localizedDescription
            return (fallback, words.isEmpty || words == fallback ? nil : words)
        }
    }
}
