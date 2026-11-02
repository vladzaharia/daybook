import DaybookDesign
import DaybookKit
import Foundation
import SwiftUI

// What the shared transcript (`TranscriptPage`) asks of the app it's on. Each app fills it once: the Mac from
// `AppState` and its player, the iPhone from its reading session and player. Edits go to `LibraryController` the same
// way on both.

/// Where the player is in a conversation, as the transcript follows it.
public struct TranscriptPlayhead: Equatable, Sendable {
    /// The recording playing (or paused partway).
    public var trackID: UUID
    /// Where in that recording.
    public var position: TimeInterval
    public var isPlaying: Bool

    public init(trackID: UUID, position: TimeInterval, isPlaying: Bool) {
        self.trackID = trackID
        self.position = position
        self.isPlaying = isPlaying
    }
}

/// A sheet the transcript asks its app to show. The app shows it the way its other reading sheets show: a sheet on
/// the Mac and the iPhone in the hand, a card on the open Duo's right page.
public enum TranscriptSheet: Identifiable, Hashable, Sendable {
    /// Correct Passage, on a page too narrow to correct in place.
    case correct(segmentID: UUID)
    /// Review Earlier Corrections.
    case reviewCorrections
    /// Adjust Timing for a recording; nil picks the one that couldn't be lined up, else the second.
    case adjustTiming(trackID: UUID?)
    /// A recording's own transcript, before the recordings were put together.
    case originalTranscript(trackID: UUID)

    public var id: String {
        switch self {
        case .correct(let id): return "correct:\(id)"
        case .reviewCorrections: return "review-corrections"
        case .adjustTiming(let id): return "adjust-timing:\(id?.uuidString ?? "")"
        case .originalTranscript(let id): return "original:\(id)"
        }
    }
}

/// Where the transcript should go next (a search hit, a summary line's evidence, a photo's moment): a row's ID, with a
/// token so asking for the same row twice still moves the page. A flash washes it briefly so the eye finds it.
public struct TranscriptScrollRequest: Equatable, Sendable {
    public var target: String
    public var token: Int
    public var flash: Bool

    public init(target: String, token: Int, flash: Bool = true) {
        self.target = target
        self.token = token
        self.flash = flash
    }
}

/// The app behind a transcript page.
public struct TranscriptHost {
    /// Where edits go: corrections, renames, bookmarks, a recording's timing.
    public var library: LibraryController
    /// The player in this conversation, nil when nothing of it is loaded. Read inside an observation, so the page
    /// follows the player apart from its body and redraws only when the passage under the playhead changes.
    public var playhead: @MainActor () -> TranscriptPlayhead?
    /// Plays a passage, a time, or a recording.
    public var play: @MainActor (PlaybackTarget) -> Void
    /// Whether anything can play now: the Mac plays nothing while it records.
    public var canPlay: @MainActor () -> Bool
    /// A recording's name, as Audio says it ("Microphone", "Soundcore Work", "Alex’s iPhone"; `RecordingWords`).
    public var recordingName: @MainActor (RecordingTrack, Meeting) -> String
    /// Shows one of the transcript's sheets, the way the app shows its reading sheets, and says whether it did; one it
    /// leaves (false) the page presents itself, as a plain sheet.
    public var present: @MainActor (TranscriptSheet) -> Bool
    /// Brings your notes into view on the summary.
    public var showNotes: @MainActor () -> Void
    /// The person scrolled the page by hand.
    public var didScroll: @MainActor () -> Void
    /// Photos in the transcript: their originals and what they offer.
    public var photos: PhotoServices

    public init(library: LibraryController,
                playhead: @escaping @MainActor () -> TranscriptPlayhead?,
                play: @escaping @MainActor (PlaybackTarget) -> Void,
                canPlay: @escaping @MainActor () -> Bool = { true },
                recordingName: @escaping @MainActor (RecordingTrack, Meeting) -> String = { RecordingWords.name($0, in: $1) },
                present: @escaping @MainActor (TranscriptSheet) -> Bool,
                showNotes: @escaping @MainActor () -> Void,
                didScroll: @escaping @MainActor () -> Void = {},
                photos: PhotoServices) {
        self.library = library
        self.playhead = playhead
        self.play = play
        self.canPlay = canPlay
        self.recordingName = recordingName
        self.present = present
        self.showNotes = showNotes
        self.didScroll = didScroll
        self.photos = photos
    }
}

/// The words of the transcript's notices, the same on both apps: the recording named as Audio names it, and the
/// action that fixes it.
public enum TranscriptNoticeWords {
    public static func unaligned(_ name: String) -> String { "Couldn’t line up the \(name) recording with the others" }

    public static func corrections(_ count: Int) -> String {
        count == 1 ? "An earlier correction needs a look" : "\(count) earlier corrections need a look"
    }

    public static let adjustTiming = "Adjust Timing…"
    public static let review = "Review…"
}
