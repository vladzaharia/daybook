import DaybookDesign
import DaybookKit
import DaybookUI
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// Photos on the conversation page are DaybookUI's (`PhotoStrip`, `PhotoTile`, `SectionPhotos`, `TranscriptPhotoRow`,
// `PhotoViewer`; docs/photos.md), the same views the Mac draws. This is what this iPhone fills them with: originals
// fetched through the audio provider (downloaded from iCloud when they must be), Share, and its player and reading
// session. Bringing photos in (the picker, Files) is the iPhone's own.

extension PhotoServices {
    /// This iPhone's: originals through the provider, Share Photo (a copy without location or camera details), the
    /// reading session's viewer and transcript, and its player.
    @MainActor
    static func phone(library: LibraryController, session: ReadingSession, provider: any AudioProviding) -> PhotoServices {
        PhotoServices(
            library: library,
            original: { photo, meetingID in try await provider.localPhoto(for: photo, in: meetingID) },
            open: { photo, meetingID in session.sheet = .photo(meetingID: meetingID, photoID: photo.id) },
            add: { session.sheet = .importPhotos($0) },
            handoff: .share,
            handOn: { photo, meeting in
                do {
                    let url = try await provider.localPhoto(for: photo, in: meeting.id)
                    session.sheet = .share([try ExportFiles.photo(url, caption: photo.displayCaption)])
                } catch {
                    session.alert = ReadingAlert(title: "Couldn’t Share", error: error, fallback: "The photo couldn’t be shared. Try again.")
                }
            },
            play: { target, meeting in session.player.play(target, in: meeting, provider: provider) },
            showInTranscript: { photo, _ in session.showInTranscript(photo.id, flash: true) })
    }
}

/// The photo views' seam for everything a reading layout shows: the pages, their strips, and the sheets over them.
struct PhonePhotoServices: ViewModifier {
    let library: LibraryController
    @Environment(ReadingSession.self) private var session
    @Environment(\.audioProvider) private var provider

    func body(content: Content) -> some View {
        content.photoServices(.phone(library: library, session: session, provider: provider))
    }
}

/// The system picker shares only the photos the person selects; no photo-library permission is needed.
struct ImportPhotosSheet: View {
    let library: LibraryController
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
                            .foregroundStyle(DaybookPalette.Ink.warning)
                        Spacer()
                        Button("Details") { showingDetails = true }.buttonStyle(.daybookLink)
                    }
                    .font(DaybookFont.status.font(.touch))
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
