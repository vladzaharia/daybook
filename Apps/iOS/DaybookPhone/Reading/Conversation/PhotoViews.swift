import DaybookKit
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The system picker shares only the photos the person selects; no photo-library permission is needed.
struct ImportPhotosSheet: View {
    @ObservedObject var library: LibraryController
    let meetingID: UUID
    private let dismiss = SheetDismiss()
    @State private var selection: [PhotosPickerItem] = []
    @State private var choosingFiles = false
    @State private var importing = false
    /// Why the last photos weren't added, in the system's words (behind Details).
    @State private var failures: [String] = []
    @State private var showingDetails = false

    var body: some View {
        NavigationStack {
            List {
                PhotosPicker(selection: $selection, maxSelectionCount: 24, matching: .images, preferredItemEncoding: .current) {
                    Label("Choose Photos", systemImage: "photo.on.rectangle")
                }
                Button { choosingFiles = true } label: { Label("Choose Files", systemImage: "folder") }
                if importing { ProgressView("Adding photos…") }
                if !failures.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        Label(failures.count == 1 ? "A photo wasn’t added." : "\(failures.count) photos weren’t added.",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(PhoneStyle.Ink.warning)
                        Spacer()
                        Button("Details") { showingDetails = true }.buttonStyle(.daybookLink)
                    }
                    .font(PhoneStyle.Typeface.status)
                }
            }
            .sheet(isPresented: $showingDetails) { DetailsSheet(title: "Details", text: failures.joined(separator: "\n")) }
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
                case .failure(let error): failures = [error.localizedDescription]
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

    private var origin: PhotoOrigin { .thisIPhone() }

    private func finish(_ failures: [String]) {
        importing = false
        self.failures = failures
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
                catch { failure = PlainError.message(for: error, fallback: "The photo couldn’t be loaded.").message }
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
        .accessibilityLabel(meeting.photoAccessibilityLabel(photo))
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
                    Button("Add Photos…") { session.sheet = .importPhotos(meeting.id) }
                        .buttonStyle(.daybookLink)
                        .font(PhoneStyle.Typeface.statusLead)
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
    private let dismiss = SheetDismiss()
    @State private var caption = ""
    @State private var failure: String?
    @State private var confirmingDelete = false

    private var meeting: Meeting? { library.meeting(meetingID) }
    private var photos: [MeetingPhoto] { meeting?.visiblePhotos ?? [] }
    private var photo: MeetingPhoto? { photos.first { $0.id == photoID } }

    var body: some View {
        NavigationStack {
            if let meeting, let photo {
                VStack(spacing: 12) {
                    // Swipe between the conversation's photos, as in Photos; the dots show where you are.
                    TabView(selection: $photoID) {
                        ForEach(photos) { item in
                            PhotoImage(photo: item, meetingID: meetingID, maxPixels: 2400, mode: .fit)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .accessibilityLabel(meeting.photoAccessibilityLabel(item))
                                .accessibilityActions {
                                    if let index, index > 0 { Button("Previous Photo") { step(-1) } }
                                    if let index, index < photos.count - 1 { Button("Next Photo") { step(1) } }
                                }
                                .tag(item.id)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: photos.count > 1 ? .always : .never))
                    .indexViewStyle(.page(backgroundDisplayMode: .always))
                    VStack(alignment: .leading, spacing: 12) {
                        TextField(photo.analysis?.caption ?? "Caption", text: $caption, axis: .vertical)
                            .accessibilityLabel("Caption").onSubmit(saveCaption)
                        Text(photo.capturedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(PhoneStyle.Typeface.byline).foregroundStyle(PhoneStyle.Ink.secondary)
                        if let time = meeting.timelineTime(of: photo), !meeting.tracks.isEmpty {
                            HStack(spacing: PhoneStyle.Space.s5) {
                                Button("Play from \(TimeLabel.short(time))") {
                                    saveCaption(); session.player.play(.timeline(time), in: meeting, provider: provider); dismiss()
                                }
                                if !meeting.unifiedTranscript.isEmpty {
                                    Button("Show in Transcript") {
                                        saveCaption(); session.showInTranscript(photo.id, flash: false); dismiss()
                                    }
                                }
                            }
                            .buttonStyle(.daybookLink)
                            .font(PhoneStyle.Typeface.statusLead)
                        }
                        if let failure {
                            Label(failure, systemImage: "exclamationmark.triangle")
                                .font(PhoneStyle.Typeface.status).foregroundStyle(PhoneStyle.Ink.warning)
                        }
                    }
                    .padding(.horizontal).padding(.bottom)
                }
                .navigationTitle("Photo")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { saveCaption(); dismiss() } }
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button(photo.hiddenFromSummary == true ? "Use in Summary" : "Remove from Summary",
                                   systemImage: photo.hiddenFromSummary == true ? "text.badge.plus" : "text.badge.minus") {
                                library.setPhotoHiddenFromSummary(photo.id, hidden: photo.hiddenFromSummary != true, in: meetingID)
                                library.update(meetingID) { current in
                                    if let summary = current.summary { current.summary = PhotoPlacement.arrange(summary, in: current) }
                                }
                            }
                            Button("Share Photo", systemImage: "square.and.arrow.up") {
                                Task {
                                    do {
                                        let url = try await provider.localPhoto(for: photo, in: meetingID)
                                        saveCaption()
                                        session.sheet = .share([try ExportFiles.photo(url, caption: photo.displayCaption)])
                                    } catch { failure = PlainError.message(for: error, fallback: "The photo couldn’t be shared. Try again.").message }
                                }
                            }
                            Button("Delete Photo…", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                        } label: { Label("Photo Actions", systemImage: "ellipsis") }
                    }
                }
                .alert("Delete this photo?", isPresented: $confirmingDelete) {
                    Button("Delete Photo", role: .destructive) {
                        saveCaption(); library.removePhoto(photo.id, in: meetingID); dismiss()
                    }
                    Button("Cancel", role: .cancel) { }
                } message: { Text("It stays in Version History.") }
                .onAppear { caption = photo.caption ?? "" }
                .onChange(of: photoID) { previous, _ in
                    // The caption typed for the photo swiped away is kept before the next one's shows.
                    saveCaption(for: previous)
                    caption = self.photo?.caption ?? ""
                }
                .onDisappear(perform: saveCaption)
            } else {
                ContentUnavailableView("Photo Deleted", systemImage: "photo")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            }
        }
    }

    private var index: Int? { photos.firstIndex { $0.id == photoID } }
    private func step(_ delta: Int) {
        guard let index, photos.indices.contains(index + delta) else { return }
        photoID = photos[index + delta].id
    }
    private func saveCaption() { saveCaption(for: photoID) }
    private func saveCaption(for id: UUID) {
        guard let photo = photos.first(where: { $0.id == id }), caption != (photo.caption ?? "") else { return }
        library.setPhotoCaption(photo.id, caption: caption, in: meetingID)
    }
}
