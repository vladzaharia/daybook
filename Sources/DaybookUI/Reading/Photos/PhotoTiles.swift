import DaybookDesign
import DaybookKit
import SwiftUI

/// What a photo offers, in its context menu wherever it shows and in the viewer's menu, in one order on both apps:
/// open it, its moment (play, the transcript), the summary, hand it on, then delete it, which asks first.
public struct PhotoMenu: View {
    private let photo: MeetingPhoto
    private let meeting: Meeting
    private let services: PhotoServices
    private let showsOpen: Bool
    private let deleting: () -> Void
    @Environment(\.openPhoto) private var openPhoto

    /// - Parameter deleting: Asks whether to delete (`PhotoActions.deleteTitle`); the view showing the menu confirms.
    public init(photo: MeetingPhoto, meeting: Meeting, services: PhotoServices, showsOpen: Bool = true, deleting: @escaping () -> Void) {
        self.photo = photo
        self.meeting = meeting
        self.services = services
        self.showsOpen = showsOpen
        self.deleting = deleting
    }

    public var body: some View {
        if showsOpen {
            Button("Open Photo", systemImage: "photo") { PhotoOpening.open(photo, in: meeting.id, services: services, fallback: openPhoto) }
        }
        if let time = meeting.timelineTime(of: photo), !meeting.tracks.isEmpty {
            Button("Play from \(TimeLabel.short(time))", systemImage: "play") { services.play(.timeline(time), meeting) }
                .disabled(!services.canPlay())
            if !meeting.unifiedTranscript.isEmpty {
                Button("Show in Transcript", systemImage: "text.quote") { services.showInTranscript(photo, meeting) }
            }
        }
        Divider()
        if photo.hiddenFromSummary == true {
            Button("Use in Summary", systemImage: "text.badge.plus") {
                PhotoActions.setUsedInSummary(true, photo: photo, meetingID: meeting.id, library: services.library)
            }
            .disabled(meeting.summary == nil)
        } else {
            Button("Remove from Summary", systemImage: "text.badge.minus") {
                PhotoActions.setUsedInSummary(false, photo: photo, meetingID: meeting.id, library: services.library)
            }
            .disabled(meeting.summary == nil)
        }
        Divider()
        Button(services.handoff.title, systemImage: services.handoff.symbol) {
            let photo = photo, meeting = meeting, services = services
            Task { await services.handOn(photo, meeting) }
        }
        if let reveal = services.reveal {
            Button("Show in Finder", systemImage: "folder") { reveal(photo, meeting.id) }
        }
        Divider()
        Button("Delete Photo…", systemImage: "trash", role: .destructive, action: deleting)
    }
}

/// Opening a photo: the app's own way, else the conversation's (`openPhoto`).
enum PhotoOpening {
    @MainActor
    static func open(_ photo: MeetingPhoto, in meetingID: UUID, services: PhotoServices, fallback: OpenPhotoAction?) {
        if let open = services.open { open(photo, meetingID) } else { fallback?(photo) }
    }
}

/// Asks before a photo is deleted, the same on both apps; Undo puts it back too (`PhotoActions.delete`).
struct PhotoDeleteConfirmation: ViewModifier {
    @Binding var photo: MeetingPhoto?
    let meetingID: UUID
    let services: PhotoServices?
    /// Called once the person confirmed, before the photo goes: the viewer moves to another photo.
    var willDelete: (MeetingPhoto) -> Void = { _ in }
    @Environment(\.undoManager) private var undoManager

    func body(content: Content) -> some View {
        content.alert(PhotoActions.deleteTitle, isPresented: Binding(get: { photo != nil }, set: { if !$0 { photo = nil } }),
                      presenting: photo) { photo in
            Button("Delete Photo", role: .destructive) {
                guard let services else { return }
                willDelete(photo)
                PhotoActions.delete(photo, meetingID: meetingID, library: services.library, undoManager: undoManager)
            }
            Button("Cancel", role: .cancel) { }
        } message: { _ in
            Text(PhotoActions.deleteMessage)
        }
    }
}

/// One photo in the strip or under a summary section: the image, its time, and its caption. Its size follows the page:
/// a strip tile at a fixed width (growing with the Mac's text size), or the measure's width under a section on a
/// narrow page.
public struct PhotoTile: View {
    private let meeting: Meeting
    private let photo: MeetingPhoto
    private let large: Bool
    private let explicitServices: PhotoServices?
    @Environment(\.photoServices) private var environmentServices
    @Environment(\.openPhoto) private var openPhoto
    @Environment(\.readingScale) private var scale
    @Environment(\.daybookDensity) private var density
    @State private var deleting: MeetingPhoto?

    /// - Parameter large: Under a summary section: as wide as the page allows, at the photo's own shape.
    public init(meeting: Meeting, photo: MeetingPhoto, large: Bool = false, services: PhotoServices? = nil) {
        self.meeting = meeting
        self.photo = photo
        self.large = large
        self.explicitServices = services
    }

    private var services: PhotoServices? { explicitServices ?? environmentServices }

    /// A strip tile's width: 112 pt in a window, scaled with the reading text; 120 under touch.
    static func stripWidth(density: DaybookDensity, scale: CGFloat) -> CGFloat { density == .touch ? 120 : 112 * scale }

    public var body: some View {
        let width = Self.stripWidth(density: density, scale: scale)
        Button {
            if let services { PhotoOpening.open(photo, in: meeting.id, services: services, fallback: openPhoto) } else { openPhoto?(photo) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Group {
                    if large {
                        PhotoImage(photo: photo, meetingID: meeting.id, maxPixels: 1280, services: explicitServices)
                            .aspectRatio(PhotoWords.aspectRatio(photo), contentMode: .fit)
                    } else {
                        PhotoImage(photo: photo, meetingID: meeting.id, maxPixels: 480, services: explicitServices)
                            .frame(width: width, height: width * 0.75)
                    }
                }
                .clipShape(DaybookRadius.shape(DaybookRadius.row))
                .overlay(DaybookRadius.shape(DaybookRadius.row).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                Text(PhotoWords.when(photo, in: meeting))
                    .font(DaybookFont.marginTime.font(density, scale: scale))
                    .foregroundStyle(DaybookPalette.Ink.meta)
                if let caption = photo.displayCaption {
                    Text(caption)
                        .font(DaybookFont.status.font(density))
                        .foregroundStyle(DaybookPalette.Ink.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: large ? nil : width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let services { PhotoMenu(photo: photo, meeting: meeting, services: services) { deleting = photo } }
        }
        .modifier(PhotoDeleteConfirmation(photo: $deleting, meetingID: meeting.id, services: services))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(meeting.photoAccessibilityLabel(photo))
        .accessibilityAddTraits(.isButton)
        #if os(macOS)
        .help(photo.displayCaption ?? "Open Photo")
        #endif
    }
}

/// Every photo of the conversation, in the order they were taken, with Add Photos…: after your notes on the summary.
public struct PhotoStrip: View {
    private let meeting: Meeting
    private let explicitServices: PhotoServices?
    @Environment(\.photoServices) private var environmentServices
    @Environment(\.readingScale) private var scale
    @Environment(\.daybookDensity) private var density

    public init(meeting: Meeting, services: PhotoServices? = nil) {
        self.meeting = meeting
        self.explicitServices = services
    }

    public var body: some View {
        let photos = meeting.visiblePhotos
        if !photos.isEmpty {
            VStack(alignment: .leading, spacing: DaybookSpacing.s2) {
                PageBlock {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Photos")
                            .font(DaybookFont.heading.font(density, scale: scale))
                            .foregroundStyle(DaybookPalette.Ink.body)
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        Button("Add Photos…") { (explicitServices ?? environmentServices)?.add(meeting.id) }
                            .buttonStyle(.daybookLink)
                            .font(DaybookFont.statusLead.font(density))
                            .daybookHitTarget()
                    }
                }
                PageBlock {
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: density == .touch ? DaybookSpacing.s3 : DaybookSpacing.s2) {
                            ForEach(photos) { PhotoTile(meeting: meeting, photo: $0, services: explicitServices) }
                        }
                        .padding(.vertical, 2)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .padding(.top, DaybookSpacing.s6)
        }
    }
}

/// The photos a summary section shows, under its text: one as wide as the page allows (up to 480 pt in a window), two
/// or more two across in a window and one under another on a narrow page, each with its time and caption.
public struct SectionPhotos: View {
    private let meeting: Meeting
    private let photos: [MeetingPhoto]
    private let explicitServices: PhotoServices?
    @Environment(\.readingScale) private var scale
    @Environment(\.daybookDensity) private var density

    public init(meeting: Meeting, photos: [MeetingPhoto], services: PhotoServices? = nil) {
        self.meeting = meeting
        self.photos = photos
        self.explicitServices = services
    }

    public var body: some View {
        PageBlock {
            let across = density == .touch || photos.count == 1 ? 1 : 2
            let columns = Array(repeating: GridItem(.flexible(), spacing: DaybookSpacing.s3, alignment: .top), count: across)
            LazyVGrid(columns: columns, alignment: .leading, spacing: DaybookSpacing.s3) {
                ForEach(photos) { PhotoTile(meeting: meeting, photo: $0, large: true, services: explicitServices) }
            }
            .frame(maxWidth: density != .touch && photos.count == 1 ? 480 * scale : .infinity, alignment: .leading)
        }
        .padding(.top, DaybookSpacing.s3)
    }
}

/// A photo at the moment it was taken, in the transcript: its time in the margin (beside "Photo" on a narrow page), a
/// thumbnail, and its caption.
public struct TranscriptPhotoRow: View {
    private let meeting: Meeting
    private let photo: MeetingPhoto
    private let time: TimeInterval
    private let services: PhotoServices
    private let highlight: String
    @Environment(\.openPhoto) private var openPhoto
    @Environment(\.readingScale) private var scale
    @Environment(\.daybookDensity) private var density
    @Environment(\.readingWidth) private var readingWidth
    @State private var hovering = false
    @State private var deleting: MeetingPhoto?

    public init(meeting: Meeting, photo: MeetingPhoto, time: TimeInterval, services: PhotoServices, highlight: String = "") {
        self.meeting = meeting
        self.photo = photo
        self.time = time
        self.services = services
        self.highlight = highlight
    }

    public var body: some View {
        TranscriptMarginRow(alignment: .top) {
            TranscriptTime(time: time) { services.play(.timeline(time), meeting) }
        } content: {
            Button { PhotoOpening.open(photo, in: meeting.id, services: services, fallback: openPhoto) } label: {
                HStack(alignment: .top, spacing: DaybookSpacing.s3) {
                    PhotoImage(photo: photo, meetingID: meeting.id, services: services)
                        .frame(width: 72 * scale, height: 54 * scale)
                        .clipShape(DaybookRadius.shape(5))
                        .overlay(DaybookRadius.shape(5).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("Photo").font(DaybookFont.speaker.font(density, scale: scale)).foregroundStyle(DaybookPalette.Ink.secondary)
                            if readingWidth == .narrow {
                                Text(TimeLabel.short(time))
                                    .font(DaybookFont.time.font(density, scale: scale))
                                    .foregroundStyle(DaybookPalette.Ink.meta)
                            }
                        }
                        if let caption = photo.displayCaption {
                            Text(FindHighlight.mark(AttributedString(caption), query: highlight))
                                .font(DaybookFont.body.font(density, scale: scale))
                                .foregroundStyle(DaybookPalette.Ink.body)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(DaybookPalette.quietFill.opacity(hovering ? 1 : 0), in: DaybookRadius.shape(DaybookRadius.row))
                .padding(.horizontal, -6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .daybookMotion(DaybookMotion.hover, value: hovering)
            .contextMenu { PhotoMenu(photo: photo, meeting: meeting, services: services) { deleting = photo } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(meeting.photoAccessibilityLabel(photo))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Play from \(TimeLabel.short(time))") { services.play(.timeline(time), meeting) }
        }
        .modifier(PhotoDeleteConfirmation(photo: $deleting, meetingID: meeting.id, services: services))
    }
}

/// A block of a page that keeps the hanging margin's column where the page has one. Under touch the pages run edge
/// to edge, so it adds nothing there; in a window it's a `MarginRow` without a margin.
struct PageBlock<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.daybookDensity) private var density

    var body: some View {
        if density == .touch {
            content.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            MarginRow { content }
        }
    }
}
