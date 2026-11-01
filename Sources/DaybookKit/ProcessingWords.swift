import DaybookCore
import Foundation

// What processing is doing, in the words both apps show: the verb for each step, a progress line with one
// rounding rule, work on another device, and what waits and why. The page, the list, Floating Notes, the
// iPhone's status sheet, and the continued-processing activity all say a moment the same way from these
// (docs/interface.md, "Status speaks only when there is something to say").

/// How a device calls itself and the devices it doesn't know, for "Transcribing on this iPhone" and "Something went
/// wrong on your Mac".
public struct DeviceWords: Equatable, Sendable {
    /// "this Mac", "this iPhone".
    public var here: String
    /// For a failure whose device isn't known: "this Mac" on a Mac (it's where work happens), "your Mac" on an
    /// iPhone. Work under way with no device named is always this device's own (`ConversationStatusPresentation`).
    public var unknown: String
    /// This device's sync ID (`LibraryController.thisDevice.id`), to tell its own work from another's.
    public var thisDeviceID: String?
    /// Work here names the place ("Transcribing on this iPhone · 40%"): on an iPhone, work usually happens on a
    /// Mac, so its own is worth saying. A Mac's own work reads bare ("Transcribing · 40%").
    public var namesItself: Bool
    /// The glyph for work here: "laptopcomputer", "desktopcomputer", "iphone" (`SettingsWords.thisDeviceSymbol`).
    public var symbol: String

    public init(here: String, unknown: String, thisDeviceID: String? = nil, namesItself: Bool, symbol: String) {
        self.here = here; self.unknown = unknown; self.thisDeviceID = thisDeviceID; self.namesItself = namesItself; self.symbol = symbol
    }

    /// A Mac's words.
    public static func mac(id: String? = nil, symbol: String = "desktopcomputer") -> DeviceWords {
        DeviceWords(here: "this Mac", unknown: "this Mac", thisDeviceID: id, namesItself: false, symbol: symbol)
    }

    /// An iPhone's words.
    public static func iPhone(id: String? = nil) -> DeviceWords {
        DeviceWords(here: "this iPhone", unknown: "your Mac", thisDeviceID: id, namesItself: true, symbol: "iphone")
    }

    /// Whether `device` is this one; nil (unknown) is this one only where `unknown` says so.
    public func isHere(_ device: ProcessingRequest.Device?) -> Bool {
        guard let device else { return unknown == here }
        return device.id == thisDeviceID
    }

    /// What to call `device`: "this Mac" for this one, its name for another, `unknown` when it isn't known.
    public func name(of device: ProcessingRequest.Device?) -> String {
        guard let device else { return unknown }
        return device.id == thisDeviceID ? here : device.name
    }

    /// "This Mac", for the start of a line.
    public var hereTitle: String { here.prefix(1).uppercased() + here.dropFirst() }
}

public enum ProcessingWords {
    /// The verb for a step: "Transcribing", "Identifying speakers", "Summarizing".
    public static func verb(_ stage: ProcessingRequest.Stage) -> String {
        switch stage {
        case .transcribing: return "Transcribing"
        case .identifyingSpeakers: return "Identifying speakers"
        case .summarizing: return "Summarizing"
        }
    }

    /// The one rounding rule for a percent: whole, rounded down, so 100% shows only when it's done. A fraction that
    /// isn't a number reads as 0.
    public static func percent(_ fraction: Double) -> Int {
        guard fraction.isFinite else { return 0 }
        return Int((min(1, max(0, fraction)) * 100).rounded(.down))
    }

    /// "40%".
    public static func percentText(_ fraction: Double) -> String { "\(percent(fraction))%" }

    /// "Transcribing · 40%", or "Identifying speakers…" when there's no figure.
    public static func progressLine(_ stage: ProcessingRequest.Stage, fraction: Double?) -> String {
        guard let fraction else { return verb(stage) + "…" }
        return "\(verb(stage)) · \(percentText(fraction))"
    }

    /// Work on another device, or named here: "Transcribing on Studio Mac · 40%", "Summarizing on this iPhone".
    public static func elsewhere(_ stage: ProcessingRequest.Stage, device: String, fraction: Double? = nil) -> String {
        "\(verb(stage)) on \(device)" + (fraction.map { " · \(percentText($0))" } ?? "")
    }

    /// The same without its figure, for animating a line only when its words change: "Transcribing on Studio Mac".
    public static func phrase(_ line: String) -> String {
        line.components(separatedBy: " · ").first.map { $0.hasSuffix("…") ? String($0.dropLast()) : $0 } ?? line
    }

    /// What a request asks, as Reprocess names it: "Transcribe", "Summarize Again", "Identify Speakers Again",
    /// "Transcribe Everything Again" (docs/interface.md, "Words").
    public static func title(_ mode: ProcessingRequest.Mode) -> String {
        switch mode {
        case .newAudio: return "Transcribe"
        case .summaryOnly: return "Summarize Again"
        case .speakerRefresh: return "Identify Speakers Again"
        case .fullRetranscription: return "Transcribe Everything Again"
        }
    }

    /// What waits to happen, by the request's mode: "transcribe", "summarize", "identify speakers".
    static func infinitive(_ mode: ProcessingRequest.Mode?, summarized: Bool = false) -> String {
        switch mode {
        case .summaryOnly?: return summarized ? "summarize again" : "summarize"
        case .speakerRefresh?: return "identify speakers again"
        case .fullRetranscription?: return "transcribe everything again"
        case .newAudio?, nil: return "transcribe"
        }
    }

    /// What a conversation in this device's queue waits for.
    public enum QueuedBehind: Equatable, Sendable {
        /// Next, after the conversation running now.
        case conversation(String)
        /// Next, after the models download.
        case download
        /// Further back: `ahead` conversations before it, the running one included.
        case position(ahead: Int)
        case nothing
    }

    /// A conversation in this device's queue: "Waiting to transcribe after “Roadmap review”", "Waiting to transcribe
    /// after the download", "Waiting to summarize · 3 ahead".
    public static func waitingHere(_ mode: ProcessingRequest.Mode? = nil, behind: QueuedBehind) -> String {
        let waiting = "Waiting to \(infinitive(mode))"
        switch behind {
        case .conversation(let title): return title.isEmpty ? waiting : "\(waiting) after “\(title)”"
        case .download: return "\(waiting) after the download"
        case .position(let ahead): return ahead > 0 ? "\(waiting) · \(ahead) ahead" : waiting
        case .nothing: return waiting
        }
    }

    /// The short form, for a row or a chip: "Waiting to transcribe".
    public static func waitingHereShort(_ mode: ProcessingRequest.Mode? = nil) -> String { "Waiting to \(infinitive(mode))" }

    /// A request waiting for a device that processes: "Waiting for your Mac", "Waiting for Studio Mac to summarize
    /// again". `device` is the Mac it waits for, when one is known to be around; nil says "your Mac".
    public static func waitingForMac(_ mode: ProcessingRequest.Mode, summarized: Bool = false, device: String? = nil) -> String {
        let mac = device ?? "your Mac"
        switch mode {
        case .newAudio: return "Waiting for \(mac)"
        default: return "Waiting for \(mac) to \(infinitive(mode, summarized: summarized))"
        }
    }

    /// Why this device's work waits, and when it goes on (the iPhone pauses for these; a Mac only when asked).
    public enum PauseReason: Equatable, Sendable {
        /// A recording is under way here.
        case recording
        /// Daybook isn't on the screen, and the system didn't let the work go on.
        case background
        case heat
        case lowPowerMode
        case lowBattery
        /// The person paused it.
        case person
    }

    /// When paused work goes on: "Continues after the recording"; nil when the person paused it (Resume says it).
    public static func pausedLine(_ reason: PauseReason, device: String = "iPhone") -> String? {
        switch reason {
        case .recording: return "Continues after the recording"
        case .background: return "Continues when Daybook is open"
        case .heat: return "Continues when \(device) cools down"
        case .lowPowerMode: return "Continues when Low Power Mode is off"
        case .lowBattery: return "Continues when \(device) is charging"
        case .person: return nil
        }
    }
}

extension ProcessingRequest.Upgrade {
    /// An upgrade waiting for the device that has the better model, for a list row: "Waiting for Studio Mac". The
    /// page says what improves (`waitingLine`).
    public var shortLine: String { "Waiting for \(device?.name ?? "your Mac")" }
}
