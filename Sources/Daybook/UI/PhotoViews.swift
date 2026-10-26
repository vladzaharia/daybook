import AppKit
import DaybookCore
import DaybookKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// Photos on the conversation page (docs/interface.md, "Photos"): under the summary sections they
// illustrate, in a strip of every photo after your notes, as markers in the transcript's time
// lane, and large in the viewer. Images are content, so they sit on the paper, never on glass.

// MARK: - Images

/// Downscaled, upright copies of photo originals, made off the main thread and kept while memory allows.
final class PhotoImageCache: @unchecked Sendable {
    static let shared = PhotoImageCache()
    private let cache = NSCache<NSString, NSImage>()

    func cached(_ url: URL, maxPixels: Int) -> NSImage? { cache.object(forKey: key(url, maxPixels)) }

    func image(_ url: URL, maxPixels: Int) async -> NSImage? {
        if let hit = cached(url, maxPixels: maxPixels) { return hit }
        let made = await Task.detached(priority: .userInitiated) { Self.render(url, maxPixels: maxPixels) }.value
        if let made { cache.setObject(made, forKey: key(url, maxPixels)) }
        return made
    }

    private func key(_ url: URL, _ maxPixels: Int) -> NSString { "\(url.path)#\(maxPixels)" as NSString }

    private static func render(_ url: URL, maxPixels: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixels, kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

/// One photo, filled into its frame. A quiet fill stands in while it loads, or when the original isn't here.
struct PhotoImage: View {
    let url: URL
    var maxPixels = 480
    var contentMode: ContentMode = .fill
    @State private var image: NSImage?

    var body: some View {
        // The frame comes from the caller; the image fills or fits it and never sizes it.
        Color.clear
            .overlay {
                if let image = image ?? PhotoImageCache.shared.cached(url, maxPixels: maxPixels) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
                } else {
                    Rectangle().fill(DaybookStyle.quietFill)
                        .overlay { Image(systemName: "photo").foregroundStyle(Ink.faint) }
                }
            }
            .clipped()
            .task(id: "\(url.path):\(maxPixels)") {
                image = nil
                let loaded = await PhotoImageCache.shared.image(url, maxPixels: maxPixels)
                if !Task.isCancelled { image = loaded }
            }
    }
}

// MARK: - Opening a photo

struct OpenPhotoKey: EnvironmentKey { static let defaultValue: ((MeetingPhoto) -> Void)? = nil }
extension EnvironmentValues {
    /// Opens a photo in the viewer (set by the conversation's detail view).
    var openPhoto: ((MeetingPhoto) -> Void)? {
        get { self[OpenPhotoKey.self] }
        set { self[OpenPhotoKey.self] = newValue }
    }
}

/// What a photo's tile offers on a right-click, wherever it's shown.
struct PhotoMenu: View {
    @ObservedObject var state: AppState
    let meeting: Meeting
    let photo: MeetingPhoto
    @Environment(\.openPhoto) private var openPhoto
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Button("Open Photo") { openPhoto?(photo) }
        Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([state.photoURL(photo, in: meeting.id) as NSURL])
        }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([state.photoURL(photo, in: meeting.id)]) }
        Divider()
        if photo.hiddenFromSummary == true {
            Button("Use in Summary") { state.library.setPhotoHiddenFromSummary(photo.id, hidden: false, in: meeting.id); state.placePhotosInSummary(meeting.id) }
        } else {
            Button("Remove from Summary") { state.library.setPhotoHiddenFromSummary(photo.id, hidden: true, in: meeting.id) }
                .disabled(meeting.summary == nil)
        }
        Divider()
        Button("Delete Photo", role: .destructive) { state.deletePhoto(photo.id, in: meeting.id, undoManager: undoManager) }
    }
}

// MARK: - In the summary

/// The photos a summary section shows, under its text: up to two across at the measure, each with its caption.
struct SectionPhotos: View {
    @ObservedObject var state: AppState
    let meeting: Meeting
    let photos: [MeetingPhoto]
    @Environment(\.openPhoto) private var openPhoto
    @Environment(\.readingScale) private var scale

    var body: some View {
        MarginRow {
            // One photo spans most of the measure; two or more go two across.
            let columns = Array(repeating: GridItem(.flexible(), spacing: Space.s3, alignment: .top), count: photos.count == 1 ? 1 : 2)
            LazyVGrid(columns: columns, alignment: .leading, spacing: Space.s3) {
                ForEach(photos) { photo in
                    VStack(alignment: .leading, spacing: Space.s1) {
                        Button { openPhoto?(photo) } label: {
                            PhotoImage(url: state.photoURL(photo, in: meeting.id), maxPixels: 1280)
                                .aspectRatio(PhotoWords.aspectRatio(photo), contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu { PhotoMenu(state: state, meeting: meeting, photo: photo) }
                        .accessibilityLabel(PhotoWords.accessibilityLabel(photo, in: meeting))
                        if let caption = photo.displayCaption {
                            Text(caption).font(.system(size: 12 * scale)).foregroundStyle(Ink.secondary)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(maxWidth: photos.count == 1 ? 480 * scale : .infinity, alignment: .leading)
        }
        .padding(.top, Space.s3)
    }
}

/// Every photo of the conversation, in the order they were taken, with their times: after your
/// notes on the summary page.
struct PhotoStrip: View {
    @ObservedObject var state: AppState
    let meeting: Meeting
    @Environment(\.readingScale) private var scale
    @Environment(\.openPhoto) private var openPhoto

    var body: some View {
        let photos = meeting.visiblePhotos
        if !photos.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                MarginRow {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Photos").font(TypeStyle.heading(scale)).foregroundStyle(Ink.body).accessibilityAddTraits(.isHeader)
                        Spacer()
                        Button("Add Photo…") { state.chooseAddPhoto(to: meeting.id) }.buttonStyle(.daybookLink).font(TypeStyle.status)
                    }
                }
                .padding(.top, Space.s6)
                MarginRow {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: Space.s2) {
                            ForEach(photos) { photo in
                                Button { openPhoto?(photo) } label: { tile(photo) }
                                    .buttonStyle(.plain)
                                    .contextMenu { PhotoMenu(state: state, meeting: meeting, photo: photo) }
                                    .help(photo.displayCaption ?? "Open Photo")
                                    .accessibilityLabel(PhotoWords.accessibilityLabel(photo, in: meeting))
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(.top, Space.s2)
            }
        }
    }

    private func tile(_ photo: MeetingPhoto) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            PhotoImage(url: state.photoURL(photo, in: meeting.id))
                .frame(width: 112 * scale, height: 84 * scale)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
            Text(PhotoWords.when(photo, in: meeting))
                .font(TypeStyle.margin(scale)).foregroundStyle(Ink.meta)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - In the transcript

/// A photo at the moment it was taken, in the transcript's time lane: its time in the margin, a
/// thumbnail, and its caption.
struct TranscriptPhotoBlock: View {
    @ObservedObject var state: AppState
    let meeting: Meeting
    let photo: MeetingPhoto
    let time: TimeInterval
    let play: () -> Void
    @Environment(\.openPhoto) private var openPhoto
    @Environment(\.readingScale) private var scale
    @State private var hovering = false

    var body: some View {
        MarginRow(alignment: .top) {
            MarginTime(time: time, play: play)
        } content: {
            Button { openPhoto?(photo) } label: {
                HStack(alignment: .top, spacing: Space.s3) {
                    PhotoImage(url: state.photoURL(photo, in: meeting.id))
                        .frame(width: 72 * scale, height: 54 * scale)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Photo").font(TypeStyle.speaker(scale)).foregroundStyle(Ink.secondary)
                        if let caption = photo.displayCaption {
                            Text(caption).font(TypeStyle.body(scale)).foregroundStyle(Ink.body).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(DaybookStyle.quietFill.opacity(hovering ? 1 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(.horizontal, -6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.hover, value: hovering)
            .contextMenu { PhotoMenu(state: state, meeting: meeting, photo: photo) }
            .accessibilityLabel(PhotoWords.accessibilityLabel(photo, in: meeting))
        }
        .id(photo.id)
    }
}

// MARK: - The viewer

/// One photo, large, with when it was taken. Play from Here and Show in Transcript go to its moment.
struct PhotoViewer: View {
    @ObservedObject var state: AppState
    let meetingID: UUID
    @State var photoID: UUID
    let play: (PlaybackTarget) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager
    @State private var caption = ""

    private var meeting: Meeting? { state.meetings.first { $0.id == meetingID } }
    private var photos: [MeetingPhoto] { meeting?.visiblePhotos ?? [] }
    private var photo: MeetingPhoto? { meeting?.photo(photoID) }

    var body: some View {
        VStack(spacing: 0) {
            if let meeting, let photo {
                PhotoImage(url: state.photoURL(photo, in: meeting.id), maxPixels: 2400, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.04))
                    .accessibilityLabel(PhotoWords.accessibilityLabel(photo, in: meeting))
                Divider()
                details(photo, in: meeting)
            } else {
                ContentUnavailableView("This photo was deleted.", systemImage: "photo")
            }
        }
        .frame(minWidth: 640, idealWidth: 860, minHeight: 520, idealHeight: 680)
        .background(DaybookStyle.paper)
        .onAppear { caption = photo?.caption ?? "" }
        .onDisappear(perform: saveCaption)
        .onChange(of: photoID) { _, _ in caption = photo?.caption ?? "" }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
    }

    private func details(_ photo: MeetingPhoto, in meeting: Meeting) -> some View {
        let time = meeting.timelineTime(of: photo)
        return VStack(alignment: .leading, spacing: Space.s2) {
            TextField(photo.analysis?.caption ?? "Caption", text: $caption)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Ink.body)
                .onSubmit(saveCaption)
                .accessibilityLabel("Caption")
            HStack(spacing: Space.s3) {
                Text(PhotoWords.taken(photo, in: meeting)).font(TypeStyle.status).foregroundStyle(Ink.secondary).monospacedDigit()
                Spacer()
                if let time, !meeting.tracks.isEmpty {
                    Button("Play from \(TimeLabel.short(time))") { saveCaption(); play(.timeline(time)); dismiss() }
                        .disabled(state.isRecording)
                    if !meeting.unifiedTranscript.isEmpty {
                        Button("Show in Transcript") {
                            saveCaption()
                            state.pageMode = .transcript
                            state.pageScrollTarget = photo.id
                            dismiss()
                        }
                    }
                }
                Button { step(-1) } label: { Image(systemName: "chevron.left") }.disabled(index == 0).help("Previous Photo")
                Button { step(1) } label: { Image(systemName: "chevron.right") }.disabled(index == nil || index == photos.count - 1).help("Next Photo")
                Button(role: .destructive) {
                    let next = photos.indices.contains((index ?? 0) + 1) ? photos[(index ?? 0) + 1].id : (index ?? 0) > 0 ? photos[(index ?? 0) - 1].id : nil
                    state.deletePhoto(photo.id, in: meeting.id, undoManager: undoManager)
                    if let next { photoID = next } else { dismiss() }
                } label: { Image(systemName: "trash") }.help("Delete Photo")
                Button("Done") { saveCaption(); dismiss() }.keyboardShortcut(.defaultAction)
            }
            .buttonStyle(.bordered)
        }
        .padding(Space.s4)
    }

    private var index: Int? { photos.firstIndex { $0.id == photoID } }

    private func step(_ delta: Int) {
        guard let index, photos.indices.contains(index + delta) else { return }
        saveCaption()
        photoID = photos[index + delta].id
    }

    private func saveCaption() {
        guard let photo, caption != (photo.caption ?? "") else { return }
        state.library.setPhotoCaption(photo.id, caption: caption, in: meetingID)
    }
}

/// Words about a photo, for its labels.
enum PhotoWords {
    /// "0:42" on the timeline, else the clock time it was taken.
    static func when(_ photo: MeetingPhoto, in meeting: Meeting) -> String {
        meeting.timelineTime(of: photo).map(TimeLabel.short) ?? photo.capturedAt.formatted(date: .omitted, time: .shortened)
    }

    /// "Taken 10:15 AM · 0:42 · Alex's iPhone".
    static func taken(_ photo: MeetingPhoto, in meeting: Meeting) -> String {
        let calendar = Calendar.current
        let sameDay = calendar.isDate(photo.capturedAt, inSameDayAs: meeting.date)
        var parts = ["Taken " + photo.capturedAt.formatted(date: sameDay ? .omitted : .abbreviated, time: .standard)]
        if photo.capturedAtSource == .added { parts[0] = "Added " + photo.capturedAt.formatted(date: sameDay ? .omitted : .abbreviated, time: .shortened) }
        if let time = meeting.timelineTime(of: photo) { parts.append(TimeLabel.short(time)) }
        if let name = photo.origin?.name { parts.append(name) }
        return parts.joined(separator: " · ")
    }

    /// Width over height, from the original's size (upright), kept between portrait and panorama.
    static func aspectRatio(_ photo: MeetingPhoto) -> CGFloat {
        guard let width = photo.pixelWidth, let height = photo.pixelHeight, width > 0, height > 0 else { return 4 / 3 }
        return min(2, max(0.75, CGFloat(width) / CGFloat(height)))
    }

    static func accessibilityLabel(_ photo: MeetingPhoto, in meeting: Meeting) -> String {
        let time = meeting.timelineTime(of: photo).map { " at \(SpokenTime.format($0))" } ?? ""
        return "Photo\(time)" + (photo.displayCaption.map { ": \($0)" } ?? "")
    }
}

// MARK: - Bringing photos in

/// Drops, paste, and Continuity Camera ("Take Photo" from an iPhone) onto a conversation.
struct PhotoDropTarget: ViewModifier {
    @ObservedObject var state: AppState
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
