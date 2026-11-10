import AppKit
import DaybookCore
import DaybookKit
import DaybookUI
import Foundation
import SwiftUI

/// Presents the main window's one sheet for the selected conversation. Review Earlier Corrections, Adjust Timing, and
/// Original Transcript are DaybookUI's, the same sheets the iPhone shows.
struct ConversationSheet: View {
    let state: AppState
    let sheet: ActiveSheet
    var body: some View {
        if let meeting = state.selectedMeeting {
            switch sheet {
            case .versionHistory:
                VersionHistorySheet(state: state, meeting: meeting)
            case .reviewCorrections:
                ReviewCorrectionsSheet(library: state.library, meetingID: meeting.id)
            case .adjustTiming(let id):
                AdjustTimingSheet(library: state.library, meetingID: meeting.id, trackID: id,
                                  recordingName: { state.recordingName($0, in: $1) },
                                  play: { MacPlayback.play($0, in: meeting, state: state) })
            case .originalTranscript(let id):
                OriginalTranscriptSheet(library: state.library, meetingID: meeting.id, trackID: id,
                                        recordingName: { state.recordingName($0, in: $1) })
            }
        } else {
            ContentUnavailableView("No Conversation Selected", systemImage: "text.bubble").frame(width: 360, height: 200)
        }
    }
}

// MARK: - Version History

struct VersionHistorySheet: View {
    let state: AppState
    let meeting: Meeting
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?
    @State private var confirmingRestore = false

    private var revisions: [MeetingRevision] { meeting.revisions.reversed() }
    private var groups: [(day: String, revisions: [MeetingRevision])] {
        var result: [(String, [MeetingRevision])] = []
        for revision in revisions {
            let day = DateGroup.title(for: revision.date, now: Date(), calendar: .current)
            if result.last?.0 == day { result[result.count - 1].1.append(revision) } else { result.append((day, [revision])) }
        }
        return result
    }
    private var locked: Bool { state.recordingID == meeting.id || state.processingID == meeting.id }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                // A sheet has no title bar: the sheet names itself at the top of its list.
                Text("Version History")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .padding(.top, Space.s5 - Space.s2)
                    .selectionDisabled()
                    .accessibilityAddTraits(.isHeader)
                ForEach(groups, id: \.day) { group in
                    Section(group.day) {
                        ForEach(group.revisions) { revision in
                            HStack {
                                Label(RevisionText.title(revision, in: meeting), systemImage: RevisionText.symbol(revision))
                                Spacer()
                                Text(revision.date.formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary).font(.caption)
                                    .monospacedDigit()
                            }
                            .tag(revision.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .labelStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 320)
        } detail: {
            if let revision = revisions.first(where: { $0.id == selection }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.s5) {
                        Text(RevisionText.subject(revision, in: meeting)).font(.headline).foregroundStyle(Ink.title)
                        RevisionComparison(revision: revision)
                    }
                    // The headline lines up with the list's title.
                    .padding(.horizontal, Space.s5)
                    .padding(.top, Space.s5)
                    .padding(.bottom, Space.s5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(DaybookStyle.paper)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if RevisionRestore.canRestore(revision, in: meeting) {
                        HStack {
                            Spacer()
                            Button("Restore Previous Version…") { confirmingRestore = true }
                                .buttonStyle(.bordered)
                                .disabled(locked)
                                .help(locked ? "Wait until this conversation finishes recording or processing." : "Put back the text from before this change")
                        }
                        // Trailing edge lines up with the sheet's Done button.
                        .padding(Space.s4).padding(.trailing, Space.s1)
                    }
                }
                .alert("Restore the previous version?", isPresented: $confirmingRestore) {
                    Button("Restore") { state.library.restore(revision, in: meeting.id) }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("What’s there now stays in Version History.")
                }
            } else {
                ContentUnavailableView("Choose a Change", systemImage: "clock.arrow.circlepath")
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .dismissesOnEscape { dismiss() }
        .frame(width: 760, height: 520)
        .onAppear {
            selection = revisions.first?.id
            #if DEBUG
            // `--history-change "Summary written"` opens the newest change with that title, for snapshots, as on the iPhone.
            if let title = LaunchOptions.value(after: "--history-change"),
               let change = revisions.first(where: { RevisionText.title($0, in: meeting) == title }) {
                selection = change.id
            }
            #endif
        }
    }
}
