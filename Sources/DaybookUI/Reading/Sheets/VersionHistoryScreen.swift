import DaybookDesign
import DaybookKit
import SwiftUI

/// Version History on both apps (`VersionHistoryList`, `VersionHistoryWords`): every change to the notes, the
/// transcript, speaker names, photos, bookmarks, and the summary, newest first under each day, each drawn as the page
/// draws it (`RevisionComparison`), with Restore Previous Version where the earlier text can be put back, asked first
/// with the one alert. On the Mac it's a sheet, the list beside the change; on the iPhone (and the open Duo's right
/// page) a list whose rows push the change.
///
/// `isLocked` says when a restore would be overwritten (the conversation is recording here, or being processed here or
/// on a Mac): Restore Previous Version waits until it isn't.
public struct VersionHistoryScreen: View {
    private let library: LibraryController
    private let meetingID: UUID
    private let isLocked: (Meeting) -> Bool
    private let close = SheetDismiss()
    #if os(macOS)
    @State private var selection: MeetingRevision.ID?
    #else
    @State private var path: [MeetingRevision.ID] = []
    #endif

    public init(library: LibraryController, meetingID: UUID, isLocked: @escaping (Meeting) -> Bool) {
        self.library = library
        self.meetingID = meetingID
        self.isLocked = isLocked
    }

    private var meeting: Meeting? { library.meeting(meetingID) }

    public var body: some View { content }

    #if DEBUG
    /// `--history-change "Summary written"` opens the newest change with that title, for snapshots on both apps.
    private func requestedChange(in meeting: Meeting, arguments: [String] = CommandLine.arguments) -> MeetingRevision.ID? {
        guard let index = arguments.firstIndex(of: "--history-change"), arguments.indices.contains(index + 1) else { return nil }
        return meeting.revisions.last { RevisionText.title($0, in: meeting) == arguments[index + 1] }?.id
    }
    #endif

    // MARK: Compact: the iPhone

    #if os(iOS)
    private var content: some View {
        NavigationStack(path: $path) {
            Group {
                if let meeting, !meeting.revisions.isEmpty {
                    List {
                        ForEach(VersionHistoryList.days(meeting.revisions), id: \.day) { group in
                            Section(group.day) {
                                ForEach(group.revisions) { revision in
                                    NavigationLink(value: revision.id) { VersionHistoryRow(revision: revision, in: meeting) }
                                }
                            }
                        }
                    }
                    .navigationDestination(for: MeetingRevision.ID.self) { id in
                        if let meeting = self.meeting, let revision = meeting.revisions.first(where: { $0.id == id }) {
                            VersionHistoryChange(library: library, meeting: meeting, revision: revision, locked: isLocked(meeting))
                        }
                    }
                    #if DEBUG
                    .task { if let change = requestedChange(in: meeting) { path = [change] } }
                    #endif
                } else {
                    LibraryEmptyPlaceView(LibraryWords.EmptyPlace(title: VersionHistoryWords.noChanges, symbol: VersionHistoryWords.symbol))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(VersionHistoryWords.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button(role: .close) { close() }.tint(DaybookPalette.Ink.title) }
            }
        }
        .presentationDetents([.large])
    }
    #endif

    // MARK: Wide: the Mac's sheet

    #if os(macOS)
    private var content: some View {
        NavigationSplitView {
            List(selection: $selection) {
                // A sheet has no title bar: the sheet names itself at the top of its list.
                Text(VersionHistoryWords.title)
                    .font(.headline)
                    .foregroundStyle(DaybookPalette.Ink.title)
                    .padding(.top, DaybookSpacing.s5 - DaybookSpacing.s2)
                    .selectionDisabled()
                    .accessibilityAddTraits(.isHeader)
                if let meeting {
                    ForEach(VersionHistoryList.days(meeting.revisions), id: \.day) { group in
                        Section(group.day) {
                            ForEach(group.revisions) { revision in
                                VersionHistoryRow(revision: revision, in: meeting).tag(revision.id)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 320)
        } detail: {
            if let meeting, let revision = meeting.revisions.first(where: { $0.id == selection }) {
                VersionHistoryChange(library: library, meeting: meeting, revision: revision, locked: isLocked(meeting))
                    .id(revision.id)
            } else {
                ContentUnavailableView(meeting?.revisions.isEmpty == false ? VersionHistoryWords.chooseChange : VersionHistoryWords.noChanges,
                                       systemImage: VersionHistoryWords.symbol)
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { close() } }
        }
        .dismissesOnEscape { close() }
        .frame(width: 760, height: 520)
        .onAppear {
            guard let meeting else { return }
            selection = meeting.revisions.last?.id
            #if DEBUG
            if let change = requestedChange(in: meeting) { selection = change }
            #endif
        }
    }
    #endif
}

/// A change in the list: its glyph, what kind of change it was, and its time; on the iPhone, a line under the title
/// with what it's about (`VersionHistoryList.detail`).
struct VersionHistoryRow: View {
    let revision: MeetingRevision
    let meeting: Meeting

    init(revision: MeetingRevision, in meeting: Meeting) {
        self.revision = revision
        self.meeting = meeting
    }

    private var time: String { revision.date.formatted(date: .omitted, time: .shortened) }

    var body: some View {
        #if os(macOS)
        HStack(spacing: DaybookSpacing.s2) {
            // The sidebar's symbol size, centred in one column.
            Image(systemName: RevisionText.symbol(revision))
                .font(.title3)
                .foregroundStyle(DaybookPalette.Ink.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(RevisionText.title(revision, in: meeting))
            Spacer()
            Text(time).font(.caption).monospacedDigit().foregroundStyle(DaybookPalette.Ink.secondary)
        }
        #else
        HStack(spacing: 12) {
            Image(systemName: RevisionText.symbol(revision)).foregroundStyle(DaybookPalette.Ink.secondary)
                .frame(width: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(RevisionText.title(revision, in: meeting)).foregroundStyle(DaybookPalette.Ink.title)
                if let detail = VersionHistoryList.detail(revision, in: meeting) {
                    Text(detail).font(.footnote).foregroundStyle(DaybookPalette.Ink.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Text(time).font(.footnote.monospacedDigit()).foregroundStyle(DaybookPalette.Ink.secondary)
        }
        #endif
    }
}

/// One change: what it's about, before and after as the page draws it, and Restore Previous Version, asked first.
struct VersionHistoryChange: View {
    let library: LibraryController
    let meeting: Meeting
    let revision: MeetingRevision
    let locked: Bool
    @State private var confirming = false
    @State private var restored = false
    @Environment(\.daybookDensity) private var density
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DaybookSpacing.s5) {
                header
                // Drawn as the page draws it: the page's bullets, the changed words marked.
                RevisionComparison(revision: revision)
                if restored {
                    Label(VersionHistoryWords.restored, systemImage: "checkmark.circle.fill")
                        .font(DaybookFont.status.font(density))
                        .foregroundStyle(DaybookPalette.Ink.link)
                }
            }
            #if os(macOS)
            // The headline lines up with the list's title.
            .padding(DaybookSpacing.s5)
            #else
            .padding(ReadingGeometry.gutters(density: .touch, hangs: false).leading)
            #endif
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DaybookPalette.paper.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if RevisionRestore.canRestore(revision, in: meeting) { restoreButton }
        }
        .alert(VersionHistoryWords.restoreQuestion, isPresented: $confirming) {
            Button(VersionHistoryWords.restore) { restore() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(VersionHistoryWords.restoreConsequence)
        }
        #if os(iOS)
        .navigationTitle(RevisionText.title(revision, in: meeting))
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// The Mac's list names the change, so the page says what it's about; the iPhone's title names it, so the page
    /// says what it's about only when that's more, and when it was.
    @ViewBuilder private var header: some View {
        let subject = RevisionText.subject(revision, in: meeting)
        #if os(macOS)
        Text(subject).font(.headline).foregroundStyle(DaybookPalette.Ink.title)
        #else
        VStack(alignment: .leading, spacing: 4) {
            if subject != RevisionText.title(revision, in: meeting) {
                Text(subject).font(DaybookFont.sheetTitle.font(.touch)).foregroundStyle(DaybookPalette.Ink.title)
            }
            Text(revision.date.formatted(date: .abbreviated, time: .shortened))
                .font(.subheadline).foregroundStyle(DaybookPalette.Ink.secondary)
        }
        #endif
    }

    @ViewBuilder private var restoreButton: some View {
        #if os(macOS)
        HStack {
            Spacer()
            Button(VersionHistoryWords.restorePrevious + "…") { confirming = true }
                .buttonStyle(.bordered)
                .disabled(locked)
                .help(locked ? VersionHistoryWords.locked : VersionHistoryWords.restoreHelp)
        }
        // Trailing edge lines up with the sheet's Done button.
        .padding(DaybookSpacing.s4).padding(.trailing, DaybookSpacing.s1)
        #else
        Button { confirming = true } label: {
            Text(VersionHistoryWords.restorePrevious).font(.headline).frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.glassProminent)
        .tint(DaybookPalette.prominentFill)
        .disabled(locked)
        .padding(.horizontal, DaybookSpacing.s4).padding(.bottom, DaybookSpacing.s2)
        #endif
    }

    private func restore() {
        library.restore(revision, in: meeting.id)
        withAnimation(DaybookMotion.resolved(DaybookMotion.fade, reduceMotion: reduceMotion)) { restored = true }
    }
}
