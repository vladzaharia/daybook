import DaybookKit
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The system picker shares only the photos the person selects; no photo-library permission is needed.
struct ImportPhotosSheet: View {
    @ObservedObject var library: LibraryController
    let meetingID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var selection: [PhotosPickerItem] = []
    @State private var choosingFiles = false
    @State private var importing = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            List {
                PhotosPicker(selection: $selection, maxSelectionCount: 24, matching: .images, preferredItemEncoding: .current) {
                    Label("Choose Photos", systemImage: "photo.on.rectangle")
                }
                Button { choosingFiles = true } label: { Label("Choose Files", systemImage: "folder") }
                if importing { ProgressView("Adding photos…") }
                if let failure { Text(failure).foregroundStyle(.secondary) }
            }
            .disabled(importing)
            .navigationTitle("Add Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(importing) } }
            .interactiveDismissDisabled(importing)
            .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.heic, .jpeg, .png], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    importing = true
                    Task {
                        let result = await library.importPhotos(urls, into: meetingID, origin: origin)
                        finish(result.failures)
                    }
                case .failure(let error): failure = error.localizedDescription
                }
            }
            .onChange(of: selection) { _, items in
                guard !items.isEmpty else { return }
                importing = true
                Task {
                    var failures: [String] = []
                    for item in items {
                        do {
                            guard let data = try await item.loadTransferable(type: Data.self) else {
                                throw PhotoStoreError.unsupportedImage("The selected photo")
                            }
                            await library.acquireLock()
                            defer { library.releaseLock() }
                            try await library.addPhoto(data: data, to: meetingID, origin: origin)
                        } catch { failures.append(error.localizedDescription) }
                    }
                    selection = []
                    finish(failures)
                }
            }
        }
    }

    private var origin: PhotoOrigin {
        PhotoOrigin(kind: "daybook.iphone", serial: PhoneDevice.installationID(), name: UIDevice.current.name)
    }

    private func finish(_ failures: [String]) {
        importing = false
        failure = failures.isEmpty ? nil : failures.joined(separator: "\n")
        if failures.isEmpty { dismiss() }
    }
}

/// Thumbnails are decoded off the main actor at their display size, after the original is fetched.
struct PhotoImage: View {
    let photo: MeetingPhoto
    let meetingID: UUID
    var maxPixels = 640
    var mode: ContentMode = .fill
    @Environment(\.audioProvider) private var provider
    @State private var image: UIImage?
    @State private var failure: String?
    @State private var retry = 0

    var body: some View {
        Rectangle().fill(.quaternary)
            .overlay {
                if let image { Image(uiImage: image).resizable().aspectRatio(contentMode: mode) }
                else if let failure {
                    Button { retry += 1 } label: { Label("Try Again", systemImage: "arrow.clockwise") }
                        .accessibilityHint(failure)
                } else { ProgressView().accessibilityLabel("Loading photo") }
            }
            .clipped()
            .task(id: "\(meetingID):\(photo.id):\(photo.sha256):\(maxPixels):\(retry)") {
                image = nil; failure = nil
                do {
                    let url = try await provider.localPhoto(for: photo, in: meetingID)
                    let pixels = maxPixels
                    let loaded = await Task.detached(priority: .userInitiated) { Self.thumbnail(url, maxPixels: pixels) }.value
                    try Task.checkCancellation()
                    guard let loaded else { throw PhotoStoreError.unsupportedImage(photo.fileName) }
                    image = UIImage(cgImage: loaded)
                } catch is CancellationError { }
                catch { failure = error.localizedDescription }
            }
    }

    nonisolated static func thumbnail(_ url: URL, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}

struct PhotoTile: View {
    let meeting: Meeting
    let photo: MeetingPhoto
    var large = false
    @Environment(ReadingSession.self) private var session

    var body: some View {
        Button { session.sheet = .photo(meetingID: meeting.id, photoID: photo.id) } label: {
            VStack(alignment: .leading, spacing: 6) {
                PhotoImage(photo: photo, meetingID: meeting.id, maxPixels: large ? 1200 : 480)
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                if let caption = photo.displayCaption {
                    Text(caption).font(.caption).foregroundStyle(PhoneStyle.Ink.secondary).lineLimit(2)
                }
                if let time = meeting.timelineTime(of: photo) {
                    Text(TimeLabel.short(time)).font(.caption.monospacedDigit()).foregroundStyle(PhoneStyle.Ink.meta)
                }
            }
            .frame(width: large ? nil : 120)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Photo: \(photo.displayCaption ?? photo.fileName)")
    }
}

struct PhotoStrip: View {
    let meeting: Meeting
    @Environment(ReadingSession.self) private var session

    var body: some View {
        if !meeting.visiblePhotos.isEmpty {
            VStack(alignment: .leading, spacing: PhoneStyle.Space.s3) {
                HStack {
                    PageHeading(text: "Photos")
                    Spacer()
                    Button("Add Photos") { session.sheet = .importPhotos(meeting.id) }.font(.subheadline)
                }
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(meeting.visiblePhotos) { PhotoTile(meeting: meeting, photo: $0) }
                    }
                }
                .scrollIndicators(.hidden)
            }
            .padding(.top, PhoneStyle.Space.s6)
        }
    }
}

struct PhotoViewer: View {
    @ObservedObject var library: LibraryController
    let meetingID: UUID
    @State var photoID: UUID
    @Environment(ReadingSession.self) private var session
    @Environment(\.audioProvider) private var provider
    @Environment(\.dismiss) private var dismiss
    @State private var caption = ""
    @State private var failure: String?

    private var meeting: Meeting? { library.meeting(meetingID) }
    private var photos: [MeetingPhoto] { meeting?.visiblePhotos ?? [] }
    private var photo: MeetingPhoto? { photos.first { $0.id == photoID } }

    var body: some View {
        NavigationStack {
            if let meeting, let photo {
                VStack(spacing: 12) {
                    PhotoImage(photo: photo, meetingID: meetingID, maxPixels: 2400, mode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel(photo.displayCaption ?? "Photo")
                    VStack(alignment: .leading, spacing: 12) {
                        TextField(photo.analysis?.caption ?? "Caption", text: $caption, axis: .vertical)
                            .accessibilityLabel("Caption").onSubmit(saveCaption)
                        Text(photo.capturedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                        if let time = meeting.timelineTime(of: photo), !meeting.tracks.isEmpty {
                            HStack {
                                Button("Play from \(TimeLabel.short(time))") {
                                    saveCaption(); session.player.play(.timeline(time), in: meeting, provider: provider); dismiss()
                                }
                                if !meeting.unifiedTranscript.isEmpty {
                                    Button("Show in Transcript") {
                                        saveCaption(); session.showInTranscript(photo.id, flash: false); dismiss()
                                    }
                                }
                            }
                            .font(.subheadline)
                        }
                        if let failure { Text(failure).font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal).padding(.bottom)
                }
                .navigationTitle("Photo")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { saveCaption(); dismiss() } }
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button(photo.hiddenFromSummary == true ? "Use in Summary" : "Remove from Summary") {
                                library.setPhotoHiddenFromSummary(photo.id, hidden: photo.hiddenFromSummary != true, in: meetingID)
                                library.update(meetingID) { current in
                                    if let summary = current.summary { current.summary = PhotoPlacement.arrange(summary, in: current) }
                                }
                            }
                            Button("Share Photo", systemImage: "square.and.arrow.up") {
                                Task {
                                    do {
                                        let url = try await provider.localPhoto(for: photo, in: meetingID)
                                        saveCaption(); session.sheet = .share([url])
                                    } catch { failure = error.localizedDescription }
                                }
                            }
                            Button("Delete Photo", systemImage: "trash", role: .destructive) {
                                saveCaption(); library.removePhoto(photo.id, in: meetingID); dismiss()
                            }
                        } label: { Label("Photo Actions", systemImage: "ellipsis") }
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button("Previous", systemImage: "chevron.left") { step(-1) }.disabled(index == nil || index == 0)
                        Spacer()
                        Button("Next", systemImage: "chevron.right") { step(1) }.disabled(index == nil || index == photos.count - 1)
                    }
                }
                .onAppear { caption = photo.caption ?? "" }
                .onChange(of: photoID) { _, _ in caption = self.photo?.caption ?? "" }
                .onDisappear(perform: saveCaption)
            } else {
                ContentUnavailableView("Photo Not Found", systemImage: "photo")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            }
        }
    }

    private var index: Int? { photos.firstIndex { $0.id == photoID } }
    private func step(_ delta: Int) {
        guard let index, photos.indices.contains(index + delta) else { return }
        saveCaption(); photoID = photos[index + delta].id
    }
    private func saveCaption() {
        guard let photo, caption != (photo.caption ?? "") else { return }
        library.setPhotoCaption(photo.id, caption: caption, in: meetingID)
    }
}
