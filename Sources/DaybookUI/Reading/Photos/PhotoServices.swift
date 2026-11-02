import DaybookDesign
import DaybookKit
import Foundation
import SwiftUI

// Photos on the conversation page (docs/photos.md): under the summary sections they illustrate, in a strip of every
// photo after your notes, at their moments in the transcript, and large in the viewer. One set of views for both apps,
// over one seam: where a photo's original is on this device (the Mac's library file, the iPhone's fetch from iCloud),
// and what the app does for the actions that differ by platform (Copy and Show in Finder on the Mac, Share on the
// iPhone). Images are content, so they sit on the paper, never on glass.

/// What a photo view asks of its app.
public struct PhotoServices {
    /// How the app hands a photo on: a copy on the pasteboard (the Mac), or the share sheet (the iPhone).
    public enum Handoff: Sendable {
        case copy
        case share

        public var title: String { self == .copy ? "Copy" : "Share Photo" }
        public var symbol: String { self == .copy ? "doc.on.doc" : "square.and.arrow.up" }
    }

    /// Where edits go: captions, summary placement, deleting.
    public var library: LibraryController
    /// The original on this device, fetched first when it must be (throws when it can't be: offline, missing).
    public var original: @MainActor (MeetingPhoto, UUID) async throws -> URL
    /// Opens a photo in the viewer; nil uses the environment's `openPhoto`.
    public var open: (@MainActor (MeetingPhoto, UUID) -> Void)?
    /// Add Photos…
    public var add: @MainActor (UUID) -> Void
    public var handoff: Handoff
    /// Copies or shares the photo as an export writes it, without its location or camera details.
    public var handOn: @MainActor (MeetingPhoto, Meeting) async -> Void
    /// Show in Finder: the library's original. Nil where there's no such thing.
    public var reveal: (@MainActor (MeetingPhoto, UUID) -> Void)?
    /// Plays the conversation from a time.
    public var play: @MainActor (PlaybackTarget, Meeting) -> Void
    /// Whether anything can play now (nothing plays on the Mac while it records).
    public var canPlay: @MainActor () -> Bool
    /// Turns to the transcript at the photo's moment.
    public var showInTranscript: @MainActor (MeetingPhoto, Meeting) -> Void

    public init(library: LibraryController,
                original: @escaping @MainActor (MeetingPhoto, UUID) async throws -> URL,
                open: (@MainActor (MeetingPhoto, UUID) -> Void)? = nil,
                add: @escaping @MainActor (UUID) -> Void,
                handoff: Handoff,
                handOn: @escaping @MainActor (MeetingPhoto, Meeting) async -> Void,
                reveal: (@MainActor (MeetingPhoto, UUID) -> Void)? = nil,
                play: @escaping @MainActor (PlaybackTarget, Meeting) -> Void,
                canPlay: @escaping @MainActor () -> Bool = { true },
                showInTranscript: @escaping @MainActor (MeetingPhoto, Meeting) -> Void) {
        self.library = library
        self.original = original
        self.open = open
        self.add = add
        self.handoff = handoff
        self.handOn = handOn
        self.reveal = reveal
        self.play = play
        self.canPlay = canPlay
        self.showInTranscript = showInTranscript
    }
}

/// Opens a photo in the viewer: set by the view that presents it (the Mac's conversation). It does the same for as long
/// as that view, so every copy is equal and a tile never redraws because the closure was made again.
public struct OpenPhotoAction: Equatable {
    private let run: @MainActor (MeetingPhoto) -> Void

    public init(_ run: @escaping @MainActor (MeetingPhoto) -> Void) { self.run = run }

    @MainActor public func callAsFunction(_ photo: MeetingPhoto) { run(photo) }

    public static func == (lhs: Self, rhs: Self) -> Bool { true }
}

/// The seam's identity for the environment: the services it holds do the same for as long as the view that set them.
struct PhotoServicesValue: Equatable {
    let services: PhotoServices?
    static func == (lhs: Self, rhs: Self) -> Bool { (lhs.services == nil) == (rhs.services == nil) }
}

extension EnvironmentValues {
    /// The photo views' app, for the views under it that weren't given one.
    public var photoServices: PhotoServices? {
        get { photoServicesValue.services }
        set { photoServicesValue = PhotoServicesValue(services: newValue) }
    }
    @Entry var photoServicesValue = PhotoServicesValue(services: nil)
    /// Opens a photo in the viewer (`PhotoServices.open` comes first).
    @Entry public var openPhoto: OpenPhotoAction? = nil
}

extension View {
    /// Fills the photo views' seam for everything under it.
    public func photoServices(_ services: PhotoServices?) -> some View {
        environment(\.photoServices, services)
    }

    /// The conversation says how a photo opens: `.environment(\.openPhoto) { photo in … }`.
    public func environment(_ keyPath: WritableKeyPath<EnvironmentValues, OpenPhotoAction?>,
                            _ open: @escaping @MainActor (MeetingPhoto) -> Void) -> some View {
        environment(keyPath, OpenPhotoAction(open))
    }
}

/// What a photo offers, the same everywhere it shows (a tile, the transcript, the viewer) on both apps.
@MainActor
public enum PhotoActions {
    /// Use in Summary or Remove from Summary, and the summary's photos arranged again around the choice: placement
    /// isn't prose, so it isn't a Version History entry.
    public static func setUsedInSummary(_ used: Bool, photo: MeetingPhoto, meetingID: UUID, library: LibraryController) {
        library.setPhotoHiddenFromSummary(photo.id, hidden: !used, in: meetingID)
        library.update(meetingID) { meeting in
            guard let summary = meeting.summary else { return }
            let arranged = PhotoPlacement.arrange(summary, in: meeting)
            if arranged != summary { meeting.summary = arranged }
        }
    }

    /// Deletes a photo, once the person confirmed: the original stays, Version History keeps the change, and Undo
    /// puts it back.
    public static func delete(_ photo: MeetingPhoto, meetingID: UUID, library: LibraryController, undoManager: UndoManager?) {
        library.removePhoto(photo.id, in: meetingID)
        registerRestore(photo.id, meetingID: meetingID, library: library, undoManager: undoManager)
    }

    private static func registerRestore(_ photoID: UUID, meetingID: UUID, library: LibraryController, undoManager: UndoManager?) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: library) { library in
            MainActor.assumeIsolated {
                library.restorePhoto(photoID, in: meetingID)
                undoManager.registerUndo(withTarget: library) { library in
                    MainActor.assumeIsolated {
                        library.removePhoto(photoID, in: meetingID)
                        registerRestore(photoID, meetingID: meetingID, library: library, undoManager: undoManager)
                    }
                }
            }
        }
        undoManager.setActionName("Delete Photo")
    }

    /// The question before a delete, on both apps.
    public static let deleteTitle = "Delete this photo?"
    public static let deleteMessage = "It stays in Version History."
}

/// Words about a photo, for its labels.
public enum PhotoWords {
    /// "0:42" on the timeline, else the clock time it was taken.
    public static func when(_ photo: MeetingPhoto, in meeting: Meeting) -> String {
        meeting.timelineTime(of: photo).map(TimeLabel.short) ?? photo.capturedAt.formatted(date: .omitted, time: .shortened)
    }

    /// "Taken 10:15:02 AM · 0:42 · Alex's iPhone", or "Added …" for a photo with no capture time of its own.
    public static func taken(_ photo: MeetingPhoto, in meeting: Meeting, calendar: Calendar = .current) -> String {
        let sameDay = calendar.isDate(photo.capturedAt, inSameDayAs: meeting.date)
        var parts: [String] = []
        if photo.capturedAtSource == .added {
            parts.append("Added " + photo.capturedAt.formatted(date: sameDay ? .omitted : .abbreviated, time: .shortened))
        } else {
            parts.append("Taken " + photo.capturedAt.formatted(date: sameDay ? .omitted : .abbreviated, time: .standard))
        }
        if let time = meeting.timelineTime(of: photo) { parts.append(TimeLabel.short(time)) }
        if let name = photo.origin?.name { parts.append(name) }
        return parts.joined(separator: " · ")
    }

    /// Width over height, from the original's size (upright), kept between portrait and panorama.
    public static func aspectRatio(_ photo: MeetingPhoto) -> CGFloat {
        guard let width = photo.pixelWidth, let height = photo.pixelHeight, width > 0, height > 0 else { return 4 / 3 }
        return min(2, max(0.75, CGFloat(width) / CGFloat(height)))
    }
}
