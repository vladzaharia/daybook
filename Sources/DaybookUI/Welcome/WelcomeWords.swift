import Foundation

/// What Welcome says, once for both apps: the same words on the Mac and the iPhone wherever they mean the same thing.
/// Welcome is the one place that explains, so its pages may say what a step is for, in a sentence.
public enum WelcomeWords {
    /// Which app is welcoming: what it records and what it sets up differ.
    public enum Device: Sendable {
        case mac, iPhone
    }

    public static let name = "Daybook"
    public static let tagline = "Your conversations, on your devices."
    public static let next = "Continue"
    public static let notNow = "Not Now"
    public static let downloadAndContinue = "Download and Continue"
    public static let changeLater = "You can change this later in Settings."

    /// What Daybook is, a line each. `summaries`: something here or within reach makes them (a Mac, or this iPhone's own
    /// model); without, the reading line promises transcripts and search alone.
    public static func points(_ device: Device, summaries: Bool = true) -> [WelcomePoint] {
        [
            WelcomePoint(symbol: "mic.circle.fill", text: device == .mac
                         ? "Record calls, and conversations in the room."
                         : "Record conversations in the room, or with a recorder."),
            WelcomePoint(symbol: "magnifyingglass.circle.fill",
                         text: summaries ? "Read a short summary. Search every word." : "Read the transcript. Search every word."),
            WelcomePoint(symbol: "play.circle.fill", text: "Play back any moment."),
            WelcomePoint(symbol: "lock.circle.fill", text: "Transcribed and summarized on your devices, unless you choose a cloud model.")
        ]
    }

    // MARK: Models

    /// The Mac's quality page.
    public static let qualityTitle = "Choose How Carefully Daybook Listens"
    public static let qualityMessage = "Models download once and run on this Mac."
    /// The iPhone's models page.
    public static let phoneModelsTitle = "Transcribe on This iPhone"
    public static let phoneModelsMessage = "Download models so this iPhone transcribes what it records."
    /// What the download holds, beside its size.
    public static let phoneModelsRow = "Transcription and speakers"
    /// The summary model's row, where this iPhone can run one.
    public static let phoneSummariesRow = "Summaries"
    /// The button with the total of the rows chosen: "Download 4.4 GB and Continue".
    public static func downloadAndContinue(_ size: String) -> String { "Download \(size) and Continue" }
    /// A download the disk can't hold: "Needs 16.5 GB · 12 GB free".
    public static func needsSpace(_ needed: String, free: String) -> String { "Needs \(needed) · \(free) free" }

    // MARK: Allow

    public static let allowTitle = "Allow Recording"
    public static func allowMessage(_ device: Device) -> String {
        device == .mac
            ? "The microphone records you. Computer audio records the other people on a call."
            : "The microphone records the conversation around you."
    }
    public static let microphone = "Microphone"
    public static let computerAudio = "Computer Audio"
    /// The same words as Settings › General › Permissions; the iPhone leaves off the ellipsis, as its buttons do.
    public static func allow(_ device: Device) -> String { device == .mac ? "Allow…" : "Allow" }
    public static let allowed = "Allowed"
    public static func openSettings(_ device: Device) -> String { device == .mac ? "Open System Settings…" : "Open Settings" }

    // MARK: Pair

    public static let pairTitle = "Pair with Your Mac"
    public static let pairMessage = "Start and stop recording on both at once."
    public static let pair = "Pair with Your Mac…"
    public static func paired(with mac: String) -> String { "Paired with \(mac)" }

    // MARK: Ready

    public static let readyTitle = "You’re Ready"
    public static let record = "Record"
    public static let importAudio = "Import Audio…"
    public static let recorderQuestion = "Use a wearable or handheld recorder?"
    public static let addDevice = "Add Device…"
    /// The Mac's Ready page: Daybook as a login item, so calls are noticed after a restart; the one row on it that says why.
    public static let openAtLogin = "Open Daybook at login"
    public static let openAtLoginReason = "So Daybook can notice calls."

    /// The Ready page's line: what happens to a recording made now. `transcribesElsewhere`: a Mac known to transcribe
    /// this library transcribes what this iPhone records. `waitsForWiFi`: the download is asked for and waits for Wi‑Fi,
    /// so the transcript waits for it too. `summarizesElsewhere`: this iPhone won't summarize it and a Mac known to this
    /// library will; with neither, the line says nothing of a summary.
    public static func readyMessage(downloading: Bool, canTranscribe: Bool, transcribesElsewhere: Bool = false,
                                    waitsForWiFi: Bool = false, summarizesElsewhere: Bool = false) -> String {
        let summary = summarizesElsewhere ? " Your Mac summarizes it." : ""
        if downloading {
            return (waitsForWiFi ? "Start a conversation now. It’s transcribed once the models download on Wi‑Fi."
                : "Start a conversation now. It’s transcribed once the models download.") + summary
        }
        if canTranscribe { return "Start a conversation now." + summary }
        if transcribesElsewhere {
            return summarizesElsewhere ? "Start a conversation now. Your Mac transcribes and summarizes it."
                : "Start a conversation now. Your Mac transcribes it."
        }
        return "Start a conversation now. Download models in Settings to transcribe it." + summary
    }

    /// "Downloading Balanced models", or without a name, "Downloading models".
    public static func downloading(_ name: String?) -> String {
        name.map { "Downloading \($0) models" } ?? "Downloading models"
    }

    /// The dots' words for VoiceOver: "Page 2 of 4".
    public static func page(_ number: Int, of count: Int) -> String { "Page \(number) of \(count)" }
}

/// One line of what Daybook is: a symbol in the brand gradient and a sentence.
public struct WelcomePoint: Hashable, Sendable {
    public var symbol: String
    public var text: String

    public init(symbol: String, text: String) {
        self.symbol = symbol
        self.text = text
    }
}
