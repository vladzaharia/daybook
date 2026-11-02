import DaybookDesign
import DaybookKit
import SwiftUI

/// One photo, large, with its caption to edit, when it was taken, and its moment: Play from its time and Show in
/// Transcript. Moving between the conversation's photos swipes on the iPhone, as in Photos, and takes ← and → or the
/// buttons on the Mac. The photo's actions are the ones its tile offers (`PhotoMenu`), deleting with the same question.
public struct PhotoViewer: View {
    private let meetingID: UUID
    private let services: PhotoServices
    @State private var photoID: UUID
    @State private var caption = ""
    @State private var deleting: MeetingPhoto?
    @FocusState private var editingCaption: Bool
    private let close = SheetDismiss()
    @Environment(\.daybookDensity) private var density

    public init(meetingID: UUID, photoID: UUID, services: PhotoServices) {
        self.meetingID = meetingID
        self.services = services
        _photoID = State(initialValue: photoID)
    }

    private var meeting: Meeting? { services.library.meeting(meetingID) }
    private var photos: [MeetingPhoto] { meeting?.visiblePhotos ?? [] }
    private var photo: MeetingPhoto? { photos.first { $0.id == photoID } }
    private var index: Int? { photos.firstIndex { $0.id == photoID } }

    public var body: some View {
        content
            .onAppear { caption = photo?.caption ?? "" }
            .onChange(of: photoID) { previous, _ in
                // The caption typed for the photo left behind is kept before the next one's shows.
                saveCaption(for: previous)
                caption = photo?.caption ?? ""
            }
            .onDisappear { saveCaption(for: photoID) }
            .modifier(PhotoDeleteConfirmation(photo: $deleting, meetingID: meetingID, services: services) { deleted in
                // The next photo takes its place, else the one before; with none left the viewer closes.
                if let next = PhotoViewerSteps.after(deleting: deleted.id, in: photos) { photoID = next } else { close() }
            })
    }

    @ViewBuilder private var content: some View {
        #if os(iOS)
        NavigationStack {
            if let meeting, let photo {
                VStack(spacing: DaybookSpacing.s3) {
                    TabView(selection: $photoID) {
                        ForEach(photos) { item in
                            PhotoImage(photo: item, meetingID: meetingID, maxPixels: 2400, contentMode: .fit, services: services)
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
                    details(photo, in: meeting).padding(.horizontal).padding(.bottom)
                }
                .navigationTitle("Photo")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { close() } }
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            PhotoMenu(photo: photo, meeting: meeting, services: services, showsOpen: false) { deleting = photo }
                        } label: { Label("Photo Actions", systemImage: "ellipsis") }
                    }
                }
            } else {
                ContentUnavailableView("Photo Deleted", systemImage: "photo")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { close() } } }
            }
        }
        #else
        VStack(spacing: 0) {
            if let meeting, let photo {
                PhotoImage(photo: photo, meetingID: meetingID, maxPixels: 2400, contentMode: .fit, services: services)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DaybookPalette.quietFill)
                    .accessibilityLabel(meeting.photoAccessibilityLabel(photo))
                Divider()
                details(photo, in: meeting).padding(DaybookSpacing.s4)
            } else {
                ContentUnavailableView("Photo Deleted", systemImage: "photo")
                HStack { Spacer(); Button("Done") { close() }.keyboardShortcut(.defaultAction) }.padding(DaybookSpacing.s4)
            }
        }
        .frame(minWidth: 640, idealWidth: 860, minHeight: 520, idealHeight: 680)
        .background(DaybookPalette.paper)
        // ← and → move between photos, except while the caption is being edited, where they move the cursor.
        .onKeyPress(.leftArrow) { editingCaption ? .ignored : { step(-1); return .handled }() }
        .onKeyPress(.rightArrow) { editingCaption ? .ignored : { step(1); return .handled }() }
        .dismissesOnEscape { close() }
        #endif
    }

    private func details(_ photo: MeetingPhoto, in meeting: Meeting) -> some View {
        let time = meeting.timelineTime(of: photo)
        return VStack(alignment: .leading, spacing: DaybookSpacing.s2) {
            TextField(photo.analysis?.caption ?? "Caption", text: $caption, axis: .vertical)
                .textFieldStyle(.plain)
                .font(DaybookFont.body.font(density))
                .foregroundStyle(DaybookPalette.Ink.body)
                .focused($editingCaption)
                .onSubmit { saveCaption(for: photoID) }
                .accessibilityLabel("Caption")
            #if os(macOS)
            HStack(spacing: DaybookSpacing.s3) {
                taken(photo, in: meeting)
                Spacer()
                moment(photo, time: time, in: meeting)
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(index == 0)
                    .help("Previous Photo").accessibilityLabel("Previous Photo")
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(index == nil || index == photos.count - 1)
                    .help("Next Photo").accessibilityLabel("Next Photo")
                Menu {
                    PhotoMenu(photo: photo, meeting: meeting, services: services, showsOpen: false) { deleting = photo }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Photo Actions").accessibilityLabel("Photo Actions")
                Button("Done") { close() }.keyboardShortcut(.defaultAction)
            }
            .buttonStyle(.bordered)
            #else
            taken(photo, in: meeting)
            HStack(spacing: DaybookSpacing.s5) { moment(photo, time: time, in: meeting) }
                .buttonStyle(.daybookLink)
                .font(DaybookFont.statusLead.font(density))
            #endif
        }
    }

    private func taken(_ photo: MeetingPhoto, in meeting: Meeting) -> some View {
        Text(PhotoWords.taken(photo, in: meeting))
            .font(DaybookFont.status.font(density))
            .foregroundStyle(DaybookPalette.Ink.secondary)
            .monospacedDigit()
    }

    /// Play from the photo's time and Show in Transcript, when it has a time and there's something to go to.
    @ViewBuilder private func moment(_ photo: MeetingPhoto, time: TimeInterval?, in meeting: Meeting) -> some View {
        if let time, !meeting.presentTracks.isEmpty {
            Button("Play from \(TimeLabel.short(time))") { saveCaption(for: photoID); services.play(.timeline(time), meeting); close() }
                .disabled(!services.canPlay())
            if !meeting.unifiedTranscript.isEmpty {
                Button("Show in Transcript") { saveCaption(for: photoID); services.showInTranscript(photo, meeting); close() }
            }
        }
    }

    private func step(_ delta: Int) {
        guard let index, photos.indices.contains(index + delta) else { return }
        photoID = photos[index + delta].id
    }

    private func saveCaption(for id: UUID) {
        guard let photo = photos.first(where: { $0.id == id }), caption != (photo.caption ?? "") else { return }
        services.library.setPhotoCaption(photo.id, caption: caption, in: meetingID)
    }
}

/// Where the viewer goes when its photo is deleted, as plain values.
public enum PhotoViewerSteps {
    /// The photo after the deleted one, else the one before it; nil when it was the only one.
    public static func after(deleting id: UUID, in photos: [MeetingPhoto]) -> UUID? {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return nil }
        if photos.indices.contains(index + 1) { return photos[index + 1].id }
        if index > 0 { return photos[index - 1].id }
        return nil
    }
}
