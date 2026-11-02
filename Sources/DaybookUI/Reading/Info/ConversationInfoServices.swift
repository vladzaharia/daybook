import DaybookKit
import Foundation

/// What a conversation's Info asks of the app showing it (the Mac's inspector, the iPhone's Info sheet): the names
/// it knows that the library doesn't, where audio is, what it can do now, and doing it. Edits that are the same on
/// both apps (folder, tags, placement, a speaker's name, a template) go straight to `LibraryController`.
public struct ConversationInfoServices {
    /// The models this device knows, to name the ones behind a transcript, its speakers, and its summary.
    public var catalog: ModelCatalog
    /// How this device's work and summaries are worded (`DeviceWords.mac(id:)`, `.iPhone(id:)`).
    public var words: DeviceWords
    /// A recording's name: "Microphone", "Alex’s iPhone" (this device may know the iPhone's name).
    public var recordingName: @MainActor (RecordingTrack, Meeting) -> String
    /// The line under it: "This Mac · The main recording" (`RecordingWords.line`).
    public var recordingLine: @MainActor (RecordingTrack, Meeting) -> String?
    /// Whether a recording's audio is here, where it may not be (the iPhone); nil where it always is.
    public var availability: (@MainActor (RecordingTrack, Meeting) async -> ReadingAudio)?
    /// What this device knows about the conversation for its actions: recording it, processing it.
    public var actionContext: @MainActor (Meeting) -> ConversationActions.Context
    /// Whether this app offers one of a recording's actions; one it can't do yet isn't listed.
    public var offers: @MainActor (ConversationAction.ID) -> Bool
    /// What's happening to the conversation now, with what can be done about it; nil when nothing is.
    public var now: @MainActor (Meeting, Date) -> InfoNow?
    /// Does what Info can't do alone.
    public var perform: @MainActor (ConversationInfoAction, Meeting) -> Void

    public init(catalog: ModelCatalog, words: DeviceWords,
                recordingName: @escaping @MainActor (RecordingTrack, Meeting) -> String,
                recordingLine: @escaping @MainActor (RecordingTrack, Meeting) -> String?,
                availability: (@MainActor (RecordingTrack, Meeting) async -> ReadingAudio)? = nil,
                actionContext: @escaping @MainActor (Meeting) -> ConversationActions.Context,
                offers: @escaping @MainActor (ConversationAction.ID) -> Bool = { _ in true },
                now: @escaping @MainActor (Meeting, Date) -> InfoNow?,
                perform: @escaping @MainActor (ConversationInfoAction, Meeting) -> Void) {
        self.catalog = catalog; self.words = words; self.recordingName = recordingName; self.recordingLine = recordingLine
        self.availability = availability; self.actionContext = actionContext; self.offers = offers; self.now = now
        self.perform = perform
    }
}

/// What Info asks its app to do.
public enum ConversationInfoAction: Equatable {
    /// One of a recording's actions (`ConversationActions.track`). Remove Recording… comes here once the person
    /// confirmed it.
    case track(ConversationAction.ID, RecordingTrack)
    /// Put back a recording that was removed.
    case putBack(RecordingTrack)
    /// Reprocess ▸ one of its modes.
    case process(ProcessingRequest.Mode)
    /// The template changed: summarize again with it (nil: Automatic).
    case summarize(templateID: String?)
    case versionHistory
    /// One of the Now row's actions.
    case status(ConversationStatusPresentation.Action)
    /// Show every conversation with a tag.
    case searchTag(String)
}

/// Info's Now row: what's happening, in the list row's words, and what can be done about it there (where a summary
/// runs, and stopping it).
public struct InfoNow: Equatable, Sendable {
    public var text: String
    /// A countdown runs out then: the words count down to it.
    public var countdownUntil: Date?
    public var actions: [ConversationStatusPresentation.Action]

    public init(text: String, countdownUntil: Date? = nil, actions: [ConversationStatusPresentation.Action] = []) {
        self.text = text; self.countdownUntil = countdownUntil; self.actions = actions
    }

    /// The words at a moment: a countdown's seconds move.
    public func text(at now: Date) -> String {
        ConversationRowStatus(kind: .waiting, text: text, countdownUntil: countdownUntil).text(at: now) ?? text
    }

    /// The row's words for a status (`ConversationStatusPresentation.row`), with the choices of a summary that's
    /// being placed (Use the Cloud, Start Now, Wait for a Mac), Stop while one runs, and Don’t Wait while it waits for
    /// recordings, as the page offers. Nil when everything is fine.
    public static func make(_ status: ProcessingStatus, meeting: Meeting, inputs: ConversationStatusPresentation.Inputs,
                            now: Date = Date()) -> InfoNow? {
        guard let row = ConversationStatusPresentation.row(status, meeting: meeting, inputs: inputs, now: now), let text = row.text else { return nil }
        var actions: [ConversationStatusPresentation.Action] = []
        if inputs.placement.run != nil {
            actions = [.stopSummary]
        } else if let planner = inputs.placement.planner, planner.shortLine(at: now) != nil {
            actions = planner.actions.map(ConversationStatusPresentation.Action.placement)
            if planner.started != nil { actions.append(.stopSummary) }
        } else if case .awaitingRecordings = status {
            actions = [.dontWait]
        }
        return InfoNow(text: text, countdownUntil: row.countdownUntil, actions: actions)
    }
}
