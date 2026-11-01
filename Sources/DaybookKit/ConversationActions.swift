import DaybookCore
import Foundation

/// What can be done to a conversation, in one order on both apps (docs/interface.md): share, add, reprocess,
/// history, filing, then the Trash. Each app draws these in its toolbar's More menu, a row's context menu, and (on
/// the iPhone) a row's swipe actions; none writes its own list. An action that doesn't apply now says why
/// (`unavailable`): a Mac's menu shows it dimmed, an iPhone's leaves it out, as each platform's guidelines ask. An
/// action only one app has is tagged with it (Show in Finder, Floating Notes, Take Photo).
public struct ConversationAction: Equatable, Identifiable, Sendable {
    public enum ID: Hashable, Sendable {
        // Share
        case copySummary
        /// A menu: Markdown, Full Data (JSON), and on the iPhone the audio.
        case export
        case exportMarkdown, exportJSON, shareAudio
        // Add
        case showFloatingNotes
        case takePhoto
        case addPhotos
        /// A menu: From a File…, then each recorder's recordings.
        case addRecording
        case addRecordingFromFile
        // Reprocess
        /// A menu of the modes that apply.
        case reprocess
        case process(ProcessingRequest.Mode)
        // History
        case versionHistory
        // Filing
        case rename
        case moveToFolder
        case tags
        case moveTo(LibraryPlacement)
        case showInFinder
        // The Trash
        case moveToTrash
        // A recording (Info › Audio)
        case play
        case adjustTiming
        case showOriginalTranscript
        case moveToNewConversation
        case removeRecording
    }

    public enum Role: Equatable, Sendable { case normal, destructive }

    /// Whether it can be done now; when it can't, why, in a few words.
    public enum Availability: Equatable, Sendable {
        case available
        case unavailable(String)
        public var isAvailable: Bool { self == .available }
    }

    public enum Platform: Hashable, Sendable { case mac, iPhone }

    public var id: ID
    public var title: String
    public var symbol: String
    public var role: Role = .normal
    public var availability: Availability = .available
    /// Where it appears; both apps unless it's one platform's own.
    public var platforms: Set<Platform> = [.mac, .iPhone]
    /// A menu's items.
    public var children: [ConversationAction] = []

    public init(id: ID, title: String, symbol: String, role: Role = .normal, availability: Availability = .available,
                platforms: Set<Platform> = [.mac, .iPhone], children: [ConversationAction] = []) {
        self.id = id; self.title = title; self.symbol = symbol; self.role = role; self.availability = availability
        self.platforms = platforms; self.children = children
    }

    public var isAvailable: Bool { availability.isAvailable }
}

/// The actions of one group, between dividers.
public struct ConversationActionGroup: Equatable, Identifiable, Sendable {
    public enum ID: String, CaseIterable, Sendable { case playback, share, add, reprocess, history, filing, trash }
    public var id: ID
    public var actions: [ConversationAction]
    public init(id: ID, actions: [ConversationAction]) { self.id = id; self.actions = actions }
}

public enum ConversationActions {
    /// What the app knows besides the conversation.
    public struct Context: Equatable, Sendable {
        public var platform: ConversationAction.Platform
        /// This conversation is recording, starting, or saving here.
        public var isRecording: Bool
        /// This device is processing it now, or it's in this device's queue.
        public var isProcessingHere: Bool
        /// Its processing status: asked for or under way somewhere, Reprocess waits.
        public var status: ProcessingStatus?
        /// A camera is here to take a photo.
        public var canTakePhoto: Bool

        public init(platform: ConversationAction.Platform, isRecording: Bool = false, isProcessingHere: Bool = false,
                    status: ProcessingStatus? = nil, canTakePhoto: Bool = false) {
            self.platform = platform; self.isRecording = isRecording; self.isProcessingHere = isProcessingHere
            self.status = status; self.canTakePhoto = canTakePhoto
        }

        /// Why it can't change now, when it can't.
        var busy: String? {
            if isRecording { return "Recording now" }
            if isProcessingHere { return "Processing now" }
            return nil
        }
    }

    /// The conversation's actions, grouped in order, with what this platform doesn't show left out.
    public static func actions(for meeting: Meeting, context: Context) -> [ConversationActionGroup] {
        let mac = context.platform == .mac
        let locked: ConversationAction.Availability = context.busy.map { .unavailable($0) } ?? .available
        var share: [ConversationAction] = [
            ConversationAction(id: .copySummary, title: "Copy Summary", symbol: "doc.on.doc",
                               availability: meeting.summary == nil ? .unavailable("No summary yet") : .available),
        ]
        var exports = [ConversationAction(id: .exportMarkdown, title: mac ? "Markdown…" : "Markdown", symbol: "doc.richtext"),
                       ConversationAction(id: .exportJSON, title: mac ? "Full Data (JSON)…" : "Full Data (JSON)", symbol: "curlybraces")]
        if !mac {
            exports.append(ConversationAction(id: .shareAudio, title: "Audio", symbol: "waveform",
                                              availability: meeting.tracks.isEmpty ? .unavailable("No recording yet") : .available,
                                              platforms: [.iPhone]))
        }
        // The Mac exports to a file it saves; the iPhone shares through the share sheet.
        share.append(ConversationAction(id: .export, title: mac ? "Export" : "Share", symbol: "square.and.arrow.up", children: exports))

        let add: [ConversationAction] = [
            ConversationAction(id: .showFloatingNotes, title: "Show Floating Notes", symbol: "note.text", platforms: [.mac]),
            ConversationAction(id: .takePhoto, title: "Take Photo", symbol: "camera",
                               availability: context.canTakePhoto ? .available : .unavailable("No camera"), platforms: [.iPhone]),
            ConversationAction(id: .addPhotos, title: "Add Photos…", symbol: "photo.badge.plus"),
            ConversationAction(id: .addRecording, title: "Add Recording", symbol: "waveform.badge.plus", availability: locked,
                               children: [ConversationAction(id: .addRecordingFromFile, title: "From a File…", symbol: "doc")]),
        ]

        let history = [ConversationAction(id: .versionHistory, title: "Version History…", symbol: "clock.arrow.circlepath",
                                          availability: meeting.revisions.isEmpty ? .unavailable("No changes yet") : .available)]

        let personal = meeting.effectivePlacement == .personal
        var filing: [ConversationAction] = []
        if mac { filing.append(ConversationAction(id: .rename, title: "Rename", symbol: "pencil", platforms: [.mac])) }
        filing += [
            // A Mac's menu lists the folders; an iPhone's opens a sheet.
            ConversationAction(id: .moveToFolder, title: mac ? "Move to Folder" : "Move to Folder…", symbol: "folder"),
            ConversationAction(id: .tags, title: "Tags…", symbol: "tag"),
            placement(personal),
            ConversationAction(id: .showInFinder, title: "Show in Finder", symbol: "finder", platforms: [.mac]),
        ]

        let trash = [ConversationAction(id: .moveToTrash, title: "Move to Trash…", symbol: "trash", role: .destructive, availability: locked)]

        let groups = [ConversationActionGroup(id: .share, actions: share),
                      ConversationActionGroup(id: .add, actions: add),
                      ConversationActionGroup(id: .reprocess, actions: [reprocess(meeting, context: context)]),
                      ConversationActionGroup(id: .history, actions: history),
                      ConversationActionGroup(id: .filing, actions: filing),
                      ConversationActionGroup(id: .trash, actions: trash)]
        return groups.compactMap { only($0, on: context.platform) }
    }

    /// Reprocess ▸ with the modes that apply: Transcribe (audio without a transcript), Summarize Again, Identify
    /// Speakers Again, and Transcribe Everything Again. It runs wherever the work goes (this device, a Mac, the
    /// cloud for a summary), so its glyph says "again", not where.
    static func reprocess(_ meeting: Meeting, context: Context) -> ConversationAction {
        var availability: ConversationAction.Availability = .available
        if meeting.tracks.isEmpty { availability = .unavailable("No recording yet") }
        else if let busy = context.busy { availability = .unavailable(busy) }
        else if context.status?.isPending == true { availability = .unavailable("Already asked for") }
        var modes: [ConversationAction] = []
        if meeting.hasUntranscribedAudio {
            modes.append(ConversationAction(id: .process(.newAudio), title: ProcessingWords.title(.newAudio), symbol: "waveform"))
        }
        modes += [
            ConversationAction(id: .process(.summaryOnly), title: ProcessingWords.title(.summaryOnly), symbol: "text.alignleft",
                               availability: meeting.unifiedTranscript.isEmpty ? .unavailable("No transcript yet") : .available),
            ConversationAction(id: .process(.speakerRefresh), title: ProcessingWords.title(.speakerRefresh), symbol: "person.2",
                               availability: meeting.transcripts.isEmpty ? .unavailable("Not transcribed yet") : .available),
            ConversationAction(id: .process(.fullRetranscription), title: ProcessingWords.title(.fullRetranscription), symbol: "arrow.clockwise"),
        ]
        return ConversationAction(id: .reprocess, title: "Reprocess", symbol: "arrow.triangle.2.circlepath", availability: availability, children: modes)
    }

    /// Move to Work, or Move to Personal for one that isn't there yet.
    static func placement(_ personal: Bool) -> ConversationAction {
        ConversationAction(id: .moveTo(personal ? .work : .personal), title: personal ? "Move to Work" : "Move to Personal",
                           symbol: personal ? "briefcase" : "house")
    }

    /// Several conversations selected: filing them, summarizing those with a transcript again, and the Trash.
    public static func batch(_ ids: [UUID], in meetings: [Meeting], context: Context) -> [ConversationActionGroup] {
        let selected = meetings.filter { ids.contains($0.id) }
        guard !selected.isEmpty else { return [] }
        if selected.count == 1, let meeting = selected.first { return actions(for: meeting, context: context) }
        let mac = context.platform == .mac
        let personal = selected.allSatisfy { $0.effectivePlacement == .personal }
        let summarizable = selected.contains { !$0.unifiedTranscript.isEmpty }
        let groups = [
            ConversationActionGroup(id: .reprocess, actions: [
                ConversationAction(id: .process(.summaryOnly), title: ProcessingWords.title(.summaryOnly), symbol: "text.alignleft",
                                   availability: context.busy.map { .unavailable($0) } ?? (summarizable ? .available : .unavailable("No transcript yet"))),
            ]),
            ConversationActionGroup(id: .filing, actions: [
                ConversationAction(id: .moveToFolder, title: mac ? "Move to Folder" : "Move to Folder…", symbol: "folder"),
                ConversationAction(id: .tags, title: "Tags…", symbol: "tag"),
                placement(personal),
            ]),
            ConversationActionGroup(id: .trash, actions: [
                ConversationAction(id: .moveToTrash, title: "Move \(selected.count) to Trash…", symbol: "trash", role: .destructive,
                                   availability: context.busy.map { .unavailable($0) } ?? .available),
            ]),
        ]
        return groups.compactMap { only($0, on: context.platform) }
    }

    /// One recording's actions (the inspector's Audio, the iPhone's Info › Audio): play it, its timing and original
    /// transcript, move it into a conversation of its own, and remove it.
    public static func track(_ track: RecordingTrack, in meeting: Meeting, context: Context) -> [ConversationActionGroup] {
        let only = meeting.tracks.count < 2
        let locked = context.busy
        let groups = [
            ConversationActionGroup(id: .playback, actions: [
                ConversationAction(id: .play, title: "Play", symbol: "play.fill",
                                   availability: context.isRecording ? .unavailable("Recording now") : .available),
            ]),
            ConversationActionGroup(id: .history, actions: [
                ConversationAction(id: .adjustTiming, title: "Adjust Timing…", symbol: "slider.horizontal.below.rectangle",
                                   availability: only ? .unavailable("The only recording") : .available),
                ConversationAction(id: .showOriginalTranscript, title: "Show Original Transcript…", symbol: "text.quote",
                                   availability: meeting.transcripts.contains { $0.trackID == track.id } ? .available : .unavailable("Not transcribed yet")),
            ]),
            ConversationActionGroup(id: .filing, actions: [
                ConversationAction(id: .moveToNewConversation, title: "Move to New Conversation", symbol: "rectangle.portrait.and.arrow.right",
                                   availability: locked.map { .unavailable($0) } ?? (only ? .unavailable("The only recording") : .available)),
                ConversationAction(id: .showInFinder, title: "Show in Finder", symbol: "finder", platforms: [.mac]),
            ]),
            ConversationActionGroup(id: .trash, actions: [
                ConversationAction(id: .removeRecording, title: "Remove Recording…", symbol: "trash", role: .destructive,
                                   availability: locked.map { .unavailable($0) } ?? .available),
            ]),
        ]
        return groups.compactMap { Self.only($0, on: context.platform) }
    }

    /// The group as `platform` shows it: its own actions only, and none of its menus left empty.
    static func only(_ group: ConversationActionGroup, on platform: ConversationAction.Platform) -> ConversationActionGroup? {
        func keep(_ action: ConversationAction) -> ConversationAction? {
            guard action.platforms.contains(platform) else { return nil }
            var action = action
            action.children = action.children.compactMap(keep)
            return action
        }
        let actions = group.actions.compactMap(keep)
        return actions.isEmpty ? nil : ConversationActionGroup(id: group.id, actions: actions)
    }
}
