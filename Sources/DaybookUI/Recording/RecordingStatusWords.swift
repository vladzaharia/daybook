import DaybookDesign
import DaybookKit
import Foundation

// What a recorder says about the recording and everything recording along with it, the same on both apps
// (docs/interface.md, "Floating Notes"): the phase ("● RECORDING · MacBook Pro Microphone", "✓ SAVED · 18 min"),
// a chip for each recorder and each other Daybook ("Soundcore · 80%" with the red dot, "Not recording" in
// warning ink), and a meter for each source. Plain values from plain inputs, so tests read exactly what each
// state says and the views only draw it. Floating Notes builds the inputs from AppState, the iPhone's recorder
// from PhoneAppModel.

/// The facts a recording's status is worded from.
public struct RecordingStatusInputs: Equatable {
    public enum Phase: Equatable, Sendable {
        case idle, starting, recording, paused, saving
        /// After a Stop seen on this surface.
        case saved
        /// The recording ended short: nothing reached the conversation, or the capture stopped on its own.
        case stopped
    }

    /// The call track, while recording (the Mac).
    public enum CallAudio: Equatable, Sendable {
        /// Computer audio isn't part of this recording (turned off in Settings).
        case off
        /// Captured, but silent for the last few seconds.
        case quiet
        case detected
        /// It should be captured and isn't.
        case missing
    }

    /// Another Daybook that can record along: a paired iPhone seen from a Mac, a Mac seen from an iPhone.
    public struct Peer: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case iPhone, mac }
        public enum Activity: Equatable, Sendable { case idle, recording, paused }

        public var id: String
        public var name: String
        public var kind: Kind
        public var isConnected: Bool
        public var activity: Activity
        /// Its link to this recording (multipoint): recording along, or leading it.
        public var along: CompanionRecording.State?
        public var lastConnected: Date?
        /// Its levels reach this device (an iPhone's, over the link to a Mac), so it gets a meter.
        public var hasMeter: Bool

        public init(id: String, name: String, kind: Kind, isConnected: Bool = false, activity: Activity = .idle,
                    along: CompanionRecording.State? = nil, lastConnected: Date? = nil, hasMeter: Bool? = nil) {
            self.id = id; self.name = name; self.kind = kind; self.isConnected = isConnected; self.activity = activity
            self.along = along; self.lastConnected = lastConnected; self.hasMeter = hasMeter ?? (kind == .iPhone)
        }

        var symbol: String { kind == .iPhone ? "iphone" : "desktopcomputer" }
        var shortName: String { kind == .iPhone ? "iPhone" : "Mac" }
    }

    public var phase: Phase = .idle
    /// The conversation's length, once saved.
    public var duration: TimeInterval?
    /// What it records from: "MacBook Pro Microphone".
    public var inputDevice: String?
    public var microphoneSilent = false
    /// Computer audio is part of this recording (Settings › General), so it has a Call meter.
    public var includesCall = false
    public var call: CallAudio = .off
    public var recorders: [RecorderFacts] = []
    public var peers: [Peer] = []
    /// How this device calls itself in a sentence: "this Mac", "this iPhone".
    public var here = "this Mac"

    public init() {}
}

/// The phase, as the band or the recorder's header says it.
public struct RecorderPhase: Equatable, Sendable {
    public var phase: RecordingPhaseLabel.Phase
    public var title: String
    public var detail: String?
    public var detailIsWarning: Bool

    public init(phase: RecordingPhaseLabel.Phase, title: String, detail: String? = nil, detailIsWarning: Bool = false) {
        self.phase = phase; self.title = title; self.detail = detail; self.detailIsWarning = detailIsWarning
    }
}

/// One item in a status bar: a glyph and a short label that open a menu with the whole sentence.
public struct RecorderChip: Identifiable, Equatable, Sendable {
    public enum Target: Equatable, Hashable, Sendable {
        /// `processing` is the shown conversation's work; `queue` is this device's, whichever conversation it's on.
        case call, recorder(String), peer(String), processing, queue, sync
    }

    public var target: Target
    public var symbol: String
    /// The label when there's room.
    public var label: String
    /// A shorter label for a narrow bar; nil leaves only the glyph.
    public var shortLabel: String?
    public var tone: StatusTone
    /// The red recording dot after the glyph: this device is recording too.
    public var showsDot: Bool
    /// Work in progress: how far the brand gradient fills the chip, from its leading edge.
    public var progress: Double?
    /// The whole status in a sentence: the menu's first line, the tooltip, and VoiceOver.
    public var detail: String
    /// Its short label says as much with its glyph (a paused iPhone's "Paused"), so it shortens before the other
    /// chips give up their names.
    public var shortensFirst: Bool
    /// A countdown runs out then ("Summarizing in 12 s"): its seconds move with it, and only the chip redraws.
    public var countdownUntil: Date?

    public init(target: Target, symbol: String, label: String, shortLabel: String? = nil, tone: StatusTone, showsDot: Bool = false,
                progress: Double? = nil, detail: String, shortensFirst: Bool = false, countdownUntil: Date? = nil) {
        self.target = target; self.symbol = symbol; self.label = label; self.shortLabel = shortLabel; self.tone = tone
        self.showsDot = showsDot; self.progress = progress; self.detail = detail; self.shortensFirst = shortensFirst
        self.countdownUntil = countdownUntil
    }

    /// The chip at a moment: a countdown's seconds move with it ("Summarizing in 11 s", "11 s").
    public func at(_ now: Date) -> RecorderChip {
        guard let until = countdownUntil else { return self }
        let seconds = max(1, Int(until.timeIntervalSince(now).rounded(.up)))
        func moved(_ text: String) -> String {
            text.replacingOccurrences(of: #"\b\d+ s\b"#, with: "\(seconds) s", options: .regularExpression)
        }
        var chip = self
        chip.label = moved(label)
        chip.shortLabel = shortLabel.map(moved)
        chip.detail = moved(detail)
        return chip
    }

    /// Keeps its words longest as the bar narrows: what's happening to the conversation, and anything that needs
    /// the person.
    public var isProminent: Bool { target == .processing || target == .queue || tone == .attention }

    /// Work in progress spans what's left of its row, its pill filling as the work goes.
    public var expands: Bool { progress != nil }

    public var id: String {
        switch target {
        case .call: return "call"
        case .recorder(let id): return "recorder-\(id)"
        case .peer(let id): return "peer-\(id)"
        case .processing: return "processing"
        case .queue: return "queue"
        case .sync: return "sync"
        }
    }
}

/// One of the recording's rolling meters: a source it has right now, labelled with the glyph its chip uses, its
/// name in the tooltip and for VoiceOver.
public struct RecorderMeter: Identifiable, Equatable, Sendable {
    public enum Source: Hashable, Sendable {
        case microphone, call
        /// A recorder recording along, by its device session's ID.
        case recorder(String)
        /// Another Daybook recording along, by its device session's ID (the link's device ID).
        case peer(String)
    }

    public var source: Source
    public var symbol: String
    public var name: String
    /// What's wrong with it, with the fix: its glyph turns warning ink and this is its tooltip.
    public var warning: String?
    /// Recording now. A paused iPhone's meter, or one still starting, rests.
    public var isRecording: Bool

    public init(source: Source, symbol: String, name: String, warning: String? = nil, isRecording: Bool = true) {
        self.source = source; self.symbol = symbol; self.name = name; self.warning = warning; self.isRecording = isRecording
    }

    public var id: String {
        switch source {
        case .microphone: return "microphone"
        case .call: return "call"
        case .recorder(let id): return "recorder-\(id)"
        case .peer(let id): return "peer-\(id)"
        }
    }
}

public enum RecordingStatusWords {
    public static let microphoneSilentHelp = "Check that your microphone isn’t muted or unplugged."
    public static let callMissingHelp = "Call audio isn’t being recorded. Allow Daybook in Privacy & Security › Screen & System Audio Recording."

    // MARK: Phase

    public static func phase(_ inputs: RecordingStatusInputs) -> RecorderPhase? {
        switch inputs.phase {
        case .idle: return nil
        case .starting: return RecorderPhase(phase: .starting, title: "Starting")
        case .recording:
            if inputs.microphoneSilent { return RecorderPhase(phase: .recording, title: "Recording", detail: "Microphone silent", detailIsWarning: true) }
            return RecorderPhase(phase: .recording, title: "Recording", detail: inputs.inputDevice)
        case .paused: return RecorderPhase(phase: .paused, title: "Paused")
        case .saving: return RecorderPhase(phase: .saving, title: "Saving…")
        // How long it is, as the page and the list say it ("18 min"), never a time that reads like a clock.
        case .saved: return RecorderPhase(phase: .saved, title: "Saved", detail: inputs.duration.map(DurationLabel.format))
        case .stopped: return RecorderPhase(phase: .stopped, title: "Stopped")
        }
    }

    // MARK: Chips

    /// What records along, in order: the call (while recording), each recorder, then each other Daybook.
    public static func chips(_ inputs: RecordingStatusInputs, includesCall: Bool = true, now: Date = Date()) -> [RecorderChip] {
        let recording = inputs.phase == .recording || inputs.phase == .paused
        var chips: [RecorderChip] = []
        if inputs.phase == .recording, includesCall, let call = callChip(inputs.call) { chips.append(call) }
        chips += inputs.recorders.compactMap { recorderChip($0, recording: recording, here: inputs.here, now: now) }
        chips += inputs.peers.compactMap { peerChip($0, recording: recording, here: inputs.here) }
        return chips
    }

    public static func callChip(_ call: RecordingStatusInputs.CallAudio) -> RecorderChip? {
        switch call {
        case .off: return nil
        case .detected:
            return RecorderChip(target: .call, symbol: "waveform", label: "Call", shortLabel: "Call", tone: .linked, detail: "Call audio detected")
        case .quiet:
            return RecorderChip(target: .call, symbol: "waveform", label: "Call", shortLabel: "Call", tone: .calm,
                                detail: "No call audio in the last few seconds")
        case .missing:
            return RecorderChip(target: .call, symbol: "speaker.slash.fill", label: "No call audio", shortLabel: "Call", tone: .attention,
                                detail: callMissingHelp)
        }
    }

    /// A recorder's chip, in the words its status line uses everywhere (`RecorderStatusWords`).
    public static func recorderChip(_ facts: RecorderFacts, recording: Bool, here: String, now: Date = Date()) -> RecorderChip? {
        guard let words = RecorderStatusWords.chip(facts, recording: recording, here: here, now: now) else { return nil }
        return RecorderChip(target: .recorder(facts.id), symbol: facts.symbol, label: words.label, shortLabel: words.shortLabel,
                            tone: tone(words.tone), showsDot: words.showsDot, progress: words.progress, detail: words.detail)
    }

    /// Another Daybook's chip: the red dot while it records this conversation too; a pause, or a start that didn't
    /// happen, in warning ink; connected and idle, its name.
    public static func peerChip(_ peer: RecordingStatusInputs.Peer, recording: Bool, here: String = "this Mac") -> RecorderChip? {
        func chip(_ label: String, short: String?, _ tone: StatusTone, dot: Bool = false, shortensFirst: Bool = false,
                  detail: String) -> RecorderChip {
            RecorderChip(target: .peer(peer.id), symbol: peer.symbol, label: label, shortLabel: short, tone: tone, showsDot: dot,
                         detail: detail, shortensFirst: shortensFirst)
        }
        let name = peer.name
        if recording, let along = peer.along {
            switch along {
            case .recording, .alreadyRecording, .stopping:
                // The chip is where a recording along shows, so a pause names it. Short, "Paused" by its glyph still
                // says it, so it gives way first.
                if peer.activity == .paused {
                    return chip("\(name) paused", short: "Paused", .attention, shortensFirst: true,
                                detail: "\(name) paused. \(here.prefix(1).uppercased() + here.dropFirst()) keeps recording.")
                }
                return chip(name, short: peer.shortName, .linked, dot: true, detail: "\(name) is recording too")
            case .starting:
                return chip("Starting…", short: nil, .working, detail: "Asking \(name) to record too…")
            case .unavailable, .failed:
                return chip("Not recording", short: nil, .attention, detail: "\(name) didn’t start recording")
            case .stopped, .stopFailed, .attached:
                break
            }
        }
        guard peer.isConnected else { return nil }
        switch peer.activity {
        case .recording: return chip(name, short: peer.shortName, .linked, dot: true, detail: "\(name) is recording")
        case .paused: return chip("\(name) paused", short: "Paused", .calm, shortensFirst: true, detail: "\(name) paused its recording")
        case .idle: return chip(name, short: nil, .linked, detail: "\(name) · Connected")
        }
    }

    /// A status's tone, from the words both apps share.
    static func tone(_ tone: StatusLineWords.Tone) -> StatusTone {
        switch tone {
        case .calm: return .calm
        case .working: return .working
        case .linked: return .linked
        case .recording: return .recording
        case .attention: return .attention
        }
    }

    // MARK: Processing

    /// After Stop, what's becoming of the conversation, as a chip in the words its library row says
    /// (`ConversationStatusPresentation.row`): "Transcribing · 40%" filling as it goes, "Waiting for your Mac", "Waiting
    /// for models", a summary's countdown. Nil when the row has nothing to say.
    public static func processingChip(_ row: ConversationRowStatus?) -> RecorderChip? {
        guard let row, let text = row.text else { return nil }
        func chip(_ symbol: String, _ tone: StatusTone, short: String?, progress: Double? = nil) -> RecorderChip {
            RecorderChip(target: .processing, symbol: symbol, label: text, shortLabel: short, tone: tone, progress: progress, detail: text,
                         countdownUntil: row.countdownUntil)
        }
        switch row.kind {
        case .processing:
            return chip("quote.bubble", .working, short: row.fraction.flatMap { $0 > 0 ? ProcessingWords.percentText($0) : nil },
                        progress: row.fraction)
        case .waiting:
            // A countdown's short words are its seconds ("12 s"), which move with it.
            let seconds = row.countdownUntil == nil ? nil : text.range(of: #"\d+ s$"#, options: .regularExpression).map { String(text[$0]) }
            return chip("clock", .calm, short: seconds ?? "Waiting")
        case .waitingForModels: return chip("arrow.down.circle", .attention, short: "Models")
        case .paused: return chip("pause.circle", .calm, short: "Paused")
        case .failed: return chip("exclamationmark.triangle.fill", .attention, short: nil)
        case .notTranscribed: return chip("quote.bubble", .calm, short: nil)
        case .recording, .playing, .justFinished: return nil
        }
    }

    // MARK: Meters

    /// The recording's meters, one per source it has now: the microphone, call audio when it's included, then each
    /// recorder and each other Daybook recording along, in the chips' order. A source whose levels haven't arrived
    /// keeps its row, flat; a Daybook whose levels never reach this device has none.
    public static func meters(_ inputs: RecordingStatusInputs) -> [RecorderMeter] {
        guard [.recording, .paused, .saving].contains(inputs.phase) else { return [] }
        var meters = [RecorderMeter(source: .microphone, symbol: "mic", name: "Microphone", warning: inputs.microphoneSilent ? microphoneSilentHelp : nil,
                                    isRecording: inputs.phase != .paused)]
        if inputs.includesCall {
            let missing = inputs.call == .missing
            meters.append(RecorderMeter(source: .call, symbol: "waveform", name: "Call audio", warning: missing ? callMissingHelp : nil,
                                        isRecording: !missing))
        }
        let along: Set<CompanionRecording.State> = [.starting, .recording, .alreadyRecording, .stopping]
        for recorder in inputs.recorders {
            guard let state = recorder.along, along.contains(state) else { continue }
            meters.append(RecorderMeter(source: .recorder(recorder.id), symbol: recorder.symbol, name: recorder.name, isRecording: state != .starting))
        }
        for peer in inputs.peers where peer.hasMeter {
            guard let state = peer.along, along.contains(state) else { continue }
            meters.append(RecorderMeter(source: .peer(peer.id), symbol: peer.symbol, name: peer.name,
                                        isRecording: state != .starting && peer.activity != .paused))
        }
        return meters
    }
}
