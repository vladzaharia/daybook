import AppKit
import DaybookCore
import DaybookKit
import DaybookUI
import SwiftUI
import UniformTypeIdentifiers

// Photos on the conversation page are DaybookUI's (`PhotoStrip`, `SectionPhotos`, `TranscriptPhotoRow`,
// `PhotoViewer`; docs/photos.md), the same views the iPhone draws. This is what this Mac fills them with: originals in
// the library's folder, Copy and Show in Finder, and its player. Bringing photos in by drop, paste, and Continuity
// Camera is the Mac's own.

extension PhotoServices {
    /// This Mac's: the library's own files, Copy (a copy without location or camera details, for this Mac only) and
    /// Show in Finder (the original), and the conversation's player. A photo opens in the conversation's viewer.
    @MainActor
    static func mac(state: AppState, play: ((PlaybackTarget) -> Void)? = nil) -> PhotoServices {
        PhotoServices(
            library: state.library,
            original: { photo, meetingID in state.photoURL(photo, in: meetingID) },
            add: { state.chooseAddPhoto(to: $0) },
            handoff: .copy,
            handOn: { photo, meeting in _ = await state.copyPhoto(photo, in: meeting.id) },
            reveal: { photo, meetingID in NSWorkspace.shared.activateFileViewerSelecting([state.photoURL(photo, in: meetingID)]) },
            play: { target, meeting in
                if let play { play(target) } else { MacPlayback.play(target, in: meeting, state: state) }
            },
            canPlay: { !state.isRecording },
            showInTranscript: { photo, _ in
                state.pageMode = .transcript
                state.pageScrollTarget = photo.id
            })
    }
}

/// Plays a conversation's time from a view that isn't given the page's player (the summary's photos): the recording
/// it falls in, fetched as the page fetches it. Nothing plays while this Mac records.
@MainActor
enum MacPlayback {
    static func play(_ target: PlaybackTarget, in meeting: Meeting, state: AppState) {
        guard !state.isRecording, let resolved = target.resolve(in: meeting) else { return }
        Task {
            guard let url = await state.audioURL(for: resolved.track, meetingID: meeting.id) else { return }
            state.playback.play(url: url, at: resolved.seconds, trackID: resolved.track.id, meetingID: meeting.id)
        }
    }
}

extension PhotoStrip {
    /// Every photo, after your notes on the summary.
    init(state: AppState, meeting: Meeting) {
        self.init(meeting: meeting, services: .mac(state: state))
    }
}

extension SectionPhotos {
    /// The photos a summary section shows, under its text.
    init(state: AppState, meeting: Meeting, photos: [MeetingPhoto]) {
        self.init(meeting: meeting, photos: photos, services: .mac(state: state))
    }
}

extension PhotoViewer {
    /// The viewer over the conversation's page, as a sheet. Esc closes it.
    init(state: AppState, meetingID: UUID, photoID: UUID, play: @escaping (PlaybackTarget) -> Void) {
        self.init(meetingID: meetingID, photoID: photoID, services: .mac(state: state, play: play))
    }
}

// MARK: - Bringing photos in

/// Drops, paste, and Continuity Camera ("Take Photo" from an iPhone) onto a conversation.
struct PhotoDropTarget: ViewModifier {
    let state: AppState
    let meetingID: UUID
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .onDrop(of: AppState.photoTypes, isTargeted: $targeted) { providers in
                let images = providers.filter { provider in AppState.photoTypes.contains { provider.hasItemConformingToTypeIdentifier($0.identifier) } }
                guard !images.isEmpty else { return false }
                state.addPhotos(images, to: meetingID)
                return true
            }
            .onPasteCommand(of: AppState.photoTypes) { providers in state.addPhotos(providers, to: meetingID) }
            .importsItemProviders([.image, .heic, .jpeg, .png]) { providers in
                state.addPhotos(providers, to: meetingID)
                return true
            }
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(DaybookStyle.accent, lineWidth: 2)
                        .padding(Space.s2)
                        .allowsHitTesting(false)
                }
            }
    }
}
