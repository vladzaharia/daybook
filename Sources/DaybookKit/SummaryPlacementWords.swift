import DaybookCore
import Foundation

/// Where a summary runs, in the words both apps say it (docs/multipoint.md, "Where summaries run"): the countdown before
/// it starts, the wait for a Mac, a summary under way where it was placed, and the person's choices. The page and its
/// list row, the list's subtitle, the inspector, Floating Notes and the menu bar on a Mac, the iPhone's status sheet,
/// and a Mac's countdown seen over the link all say them from here, with one rounding rule for the seconds and one way
/// to move them as a line ticks. Personal under Always counts down as Offer First does (`SummaryPlacementPlanner`), so
/// it reads as any countdown, with Use the Cloud.
public enum SummaryPlacementWords {
    // MARK: The countdown

    /// Whole seconds left before `deadline`, rounded up and never under one: the last second reads "in 1 s", and every
    /// view counting down to the same moment says the same number.
    public static func secondsLeft(until deadline: Date, at now: Date) -> Int {
        max(1, Int(deadline.timeIntervalSince(now).rounded(.up)))
    }

    /// "12 s": a countdown's seconds alone, for a chip with no room for its words.
    public static func seconds(_ seconds: Int) -> String { "\(seconds) s" }

    /// "Summarizing in": a countdown's words without its seconds, so a line animates when what it says changes, not at
    /// every tick.
    public static let phrase = "\(ProcessingWords.verb(.summarizing)) in"

    /// "Summarizing in 12 s": a list row, a chip, the list's subtitle, and a line under the device it counts down to.
    public static func countdown(seconds: Int) -> String { "\(phrase) \(self.seconds(seconds))" }

    /// The same, counting down to `deadline`.
    public static func countdown(until deadline: Date, at now: Date) -> String {
        countdown(seconds: secondsLeft(until: deadline, at: now))
    }

    /// "Summarizing on this Mac in 12 s", "Summarizing on Studio Mac in 12 s": the page's line, naming the device it
    /// starts on when the time runs out.
    public static func countdown(on device: String, seconds: Int) -> String {
        "\(ProcessingWords.elsewhere(.summarizing, device: device)) in \(self.seconds(seconds))"
    }

    /// The same, counting down to `deadline`.
    public static func countdown(on device: String, until deadline: Date, at now: Date) -> String {
        countdown(on: device, seconds: secondsLeft(until: deadline, at: now))
    }

    /// The same toward a planner's place; `thisDevice` is how this device calls itself ("this Mac", "this iPhone").
    public static func countdown(to place: SummaryPlace, thisDevice: String, seconds: Int) -> String {
        "\(running(place, thisDevice: thisDevice)) in \(self.seconds(seconds))"
    }

    /// "Summarizing “Weekly product sync” in 12 s": the menu bar's, which names the conversation (`conversation` comes
    /// quoted, or as "a personal conversation") since a menu has no title column.
    public static func countdown(of conversation: String, seconds: Int) -> String {
        "\(ProcessingWords.verb(.summarizing)) \(conversation) in \(self.seconds(seconds))"
    }

    /// A countdown's words at a moment: their seconds move to `seconds` ("Summarizing in 11 s · 1 waiting", "11 s").
    /// Words without a countdown's seconds are left as they are.
    public static func ticking(_ words: String, to seconds: Int) -> String {
        if words.range(of: #"^\d+ s$"#, options: .regularExpression) != nil { return self.seconds(seconds) }
        return words.replacingOccurrences(of: #"\bin \d+ s\b"#, with: "in \(self.seconds(seconds))", options: .regularExpression)
    }

    /// The same, counting down to `deadline`.
    public static func ticking(_ words: String, until deadline: Date, at now: Date) -> String {
        ticking(words, to: secondsLeft(until: deadline, at: now))
    }

    // MARK: Where it runs

    /// "on this Mac", "on Studio Mac", "with Claude Sonnet 5.5".
    public static func `where`(_ place: SummaryPlace, thisDevice: String) -> String {
        switch place {
        case .thisDevice: return "on \(thisDevice)"
        case .mac(_, let name): return "on \(name)"
        case .cloud(let model): return "with \(model.name)"
        }
    }

    /// "Summarizing on this Mac", "Summarizing on Studio Mac", "Summarizing with Claude Sonnet 5.5": a summary under way
    /// where it was placed.
    public static func running(_ place: SummaryPlace, thisDevice: String) -> String {
        "\(ProcessingWords.verb(.summarizing)) \(self.where(place, thisDevice: thisDevice))"
    }

    /// "Summarizing with Claude Sonnet 5.5": the cloud at work on it.
    public static func inCloud(_ model: String) -> String { "\(ProcessingWords.verb(.summarizing)) with \(model)" }

    /// "Summarizing “Roadmap” with Claude Sonnet 5.5": the menu bar's, naming the conversation.
    public static func inCloud(_ model: String, of conversation: String) -> String {
        "\(ProcessingWords.verb(.summarizing)) \(conversation) with \(model)"
    }

    /// "Waiting for a Mac to summarize": nowhere to run it but the cloud, which is the person's to choose.
    public static let waitingForMac = "Waiting for a Mac to \(ProcessingWords.infinitive(.summaryOnly))"

    // MARK: Choices

    /// What the person can do while it counts down or waits: "Use the Cloud", "Start Now", "Wait for a Mac".
    public static func title(_ action: SummaryPlacementPlanner.Action) -> String {
        switch action {
        case .useCloud: return "Use the Cloud"
        case .startNow: return "Start Now"
        case .waitForMac: return "Wait for a Mac"
        }
    }
}
