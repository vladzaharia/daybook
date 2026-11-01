import DaybookDesign
import DaybookKit
import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
#endif

// The seams a shared screen reaches its app through. Each app fills them (the Mac from `AppState`, the
// iPhone from `PhoneAppModel`), so a view in this library never names either app's model, and an edit
// goes to `LibraryController` as it does today.

/// Where reading goes next: another conversation, its Info, a tag's conversations, its transcript.
public struct ReadingNavigator {
    private let openConversation: @MainActor (Meeting.ID) -> Void
    private let showInfoFor: @MainActor (Meeting.ID) -> Void
    private let searchTag: @MainActor (String) -> Void
    private let showTranscriptOf: @MainActor (Meeting.ID, TimeInterval?) -> Void

    public init(open: @escaping @MainActor (Meeting.ID) -> Void,
                showInfo: @escaping @MainActor (Meeting.ID) -> Void,
                search: @escaping @MainActor (_ tag: String) -> Void,
                showTranscript: @escaping @MainActor (Meeting.ID, _ at: TimeInterval?) -> Void) {
        openConversation = open
        showInfoFor = showInfo
        searchTag = search
        showTranscriptOf = showTranscript
    }

    /// Opens a conversation's page.
    @MainActor public func open(_ id: Meeting.ID) { openConversation(id) }
    /// Shows a conversation's Info: the Mac's inspector, the iPhone's Info sheet.
    @MainActor public func showInfo(_ id: Meeting.ID) { showInfoFor(id) }
    /// Shows every conversation with a tag.
    @MainActor public func search(tag: String) { searchTag(tag) }
    /// Turns to a conversation's transcript, at a time when there is one.
    @MainActor public func showTranscript(_ id: Meeting.ID, at time: TimeInterval? = nil) { showTranscriptOf(id, time) }

    /// Goes nowhere: previews and tests.
    public static let inert = ReadingNavigator(open: { _ in }, showInfo: { _ in }, search: { _ in }, showTranscript: { _, _ in })
}

/// The app's player, as a page sees it: what's playing, where, and how to play from a time. Each app's
/// player observes itself, so a view reading it redraws as it plays.
@MainActor
public protocol ReadingPlayer: AnyObject {
    /// The conversation playing (or paused partway), if any.
    var playingMeetingID: Meeting.ID? { get }
    /// Where in it, in seconds from its start.
    var playbackPosition: TimeInterval { get }
    var isPlaying: Bool { get }
    /// Plays a passage, a bookmark, or from a time in a conversation.
    func play(_ target: PlaybackTarget, in meetingID: Meeting.ID)
    /// Pauses or resumes.
    func togglePlayback()
}

/// Whether a conversation's audio can play on this device now.
public enum ReadingAudio: Equatable, Sendable {
    /// Here; plays at once.
    case local
    /// In iCloud; plays after a download of about this many bytes (nil when unknown).
    case downloadable(bytes: Int64?)
    /// Not here, and can't be fetched now.
    case offline
    /// No copy anywhere this device can see.
    case missing
}

/// What a shared reading screen needs to know about the device it's on.
public struct ReadingContext {
    /// "this Mac", "this iPhone": the device in the person's hands, in the middle of a sentence.
    public var thisDevice: String
    /// How Audio names a Mac's own recordings: "This Mac" on the Mac, "Your Mac" on the iPhone
    /// (`RecordingWords.place`).
    public var macPlace: String
    /// Whether a conversation's audio can play here now.
    public var audio: @MainActor (Meeting) -> ReadingAudio
    public var player: (any ReadingPlayer)?
    public var navigator: ReadingNavigator

    public init(thisDevice: String, macPlace: String, audio: @escaping @MainActor (Meeting) -> ReadingAudio,
                player: (any ReadingPlayer)? = nil, navigator: ReadingNavigator = .inert) {
        self.thisDevice = thisDevice
        self.macPlace = macPlace
        self.audio = audio
        self.player = player
        self.navigator = navigator
    }

    /// This device's words, before an app fills in the rest.
    public static var platform: ReadingContext {
        #if os(macOS)
        ReadingContext(thisDevice: "this Mac", macPlace: "This Mac", audio: { _ in .local })
        #else
        ReadingContext(thisDevice: "this iPhone", macPlace: "Your Mac", audio: { _ in .local })
        #endif
    }
}

/// What a shared screen asks of its platform that SwiftUI doesn't give both: showing a problem's own
/// words, and copying a conversation's words without sending them to other devices.
public struct ScreenServices {
    /// Shows a problem's own words: a popover on the Mac (`DetailsButton`'s own), a page sheet on the Duo.
    public var presentDetails: @MainActor (_ title: String, _ details: String) -> Void
    /// Copies text for this device only.
    public var copyLocally: @MainActor (_ text: String, _ expiresIn: Duration?) -> Void

    public init(presentDetails: @escaping @MainActor (_ title: String, _ details: String) -> Void,
                copyLocally: @escaping @MainActor (_ text: String, _ expiresIn: Duration?) -> Void = { text, expiresIn in
                    LocalCopy.copy(text, expiresIn: expiresIn)
                }) {
        self.presentDetails = presentDetails
        self.copyLocally = copyLocally
    }

    @MainActor public func copyLocally(_ text: String, expiresIn: Duration? = nil) { copyLocally(text, expiresIn) }
}

extension EnvironmentValues {
    @Entry public var readingContext: ReadingContext = .platform
    @Entry public var screenServices: ScreenServices? = nil
}

extension View {
    /// Fills a screen's seams. Details buttons under it present through `services` too.
    public func screenServices(_ services: ScreenServices) -> some View {
        environment(\.screenServices, services)
            .environment(\.detailsPresenter, DetailsPresenter(present: services.presentDetails))
    }

    /// The reading context for the screens under it.
    public func readingContext(_ context: ReadingContext) -> some View {
        environment(\.readingContext, context)
    }
}

/// Copying a conversation's words: never to Universal Clipboard on nearby devices, and kept out of
/// clipboard managers' history on the Mac. An expiry clears it from the pasteboard after a while.
public enum LocalCopy {
    #if canImport(AppKit)
    /// Clipboard managers leave items carrying these alone (nspasteboard.org): concealed (not shown) and
    /// transient (not kept).
    public static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    public static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    @MainActor
    public static func copy(_ text: String, expiresIn: Duration? = nil, to pasteboard: NSPasteboard = .general) {
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: concealedType)
        pasteboard.setData(Data(), forType: transientType)
        guard let expiresIn else { return }
        let change = pasteboard.changeCount
        Task { @MainActor in
            try? await Task.sleep(for: expiresIn)
            // Only what this copy put there: anything copied since stays.
            if pasteboard.changeCount == change { pasteboard.clearContents() }
        }
    }
    #elseif canImport(UIKit)
    /// The options a copy carries: this device only, and an expiry when asked for.
    public static func options(expiresIn: Duration?, now: Date = Date()) -> [UIPasteboard.OptionsKey: Any] {
        var options: [UIPasteboard.OptionsKey: Any] = [.localOnly: true]
        if let expiresIn {
            let seconds = Double(expiresIn.components.seconds) + Double(expiresIn.components.attoseconds) / 1e18
            options[.expirationDate] = now.addingTimeInterval(seconds)
        }
        return options
    }

    @MainActor
    public static func copy(_ text: String, expiresIn: Duration? = nil, to pasteboard: UIPasteboard = .general) {
        pasteboard.setItems([[UTType.utf8PlainText.identifier: text]], options: options(expiresIn: expiresIn))
    }
    #endif
}
