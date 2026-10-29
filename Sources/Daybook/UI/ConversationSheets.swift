import AppKit
import DaybookCore
import DaybookKit
import Foundation
import SwiftUI

/// Presents the main window's one sheet for the selected conversation.
struct ConversationSheet: View {
    @ObservedObject var state: AppState
    let sheet: ActiveSheet
    var body: some View {
        if let meeting = state.selectedMeeting {
            switch sheet {
            case .versionHistory: VersionHistorySheet(state: state, meeting: meeting)
            case .reviewCorrections: ReviewCorrectionsSheet(state: state, meeting: meeting)
            case .adjustTiming(let id): AdjustTimingSheet(state: state, meeting: meeting, trackID: id ?? defaultTrack(meeting))
            case .originalTranscript(let id): OriginalTranscriptSheet(meeting: meeting, trackID: id)
            }
        } else {
            ContentUnavailableView("No Conversation Selected", systemImage: "text.bubble").frame(width: 360, height: 200)
        }
    }

    private func defaultTrack(_ meeting: Meeting) -> UUID? {
        meeting.alignmentReports.first { $0.method == .unaligned }?.trackID ?? meeting.tracks.dropFirst().first?.id
    }
}

// MARK: - Version History

struct VersionHistorySheet: View {
    @ObservedObject var state: AppState
    let meeting: Meeting
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
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
                        let diff = WordDiff.marked(old: RevisionText.readable(revision.oldValue, field: revision.field),
                                                   new: RevisionText.readable(revision.newValue, field: revision.field),
                                                   dark: scheme == .dark)
                        if RevisionText.hasBefore(revision) {
                            comparison("Before", diff.old)
                            comparison("After", diff.new)
                        } else {
                            comparison(nil, diff.new)
                        }
                    }
                    // The headline lines up with the list's first section header.
                    .padding(.horizontal, Space.s5)
                    .padding(.top, Space.s3)
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
                    Button("Restore") { state.update(meeting.id) { RevisionRestore.apply(revision, to: &$0) } }
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
        .navigationTitle("Version History")
        .frame(width: 760, height: 520)
        .onAppear { selection = revisions.first?.id }
    }

    private func comparison(_ title: String?, _ text: AttributedString) -> some View {
        let empty = text.characters.isEmpty
        return VStack(alignment: .leading, spacing: Space.s2) {
            if let title { Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Ink.secondary) }
            Group {
                if empty { Text("Empty").italic().foregroundStyle(.secondary) }
                else { Text(text).foregroundStyle(Ink.body) }
            }
            .font(.body)
            .lineSpacing(2)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Marks what changed between two versions word by word: removed words struck through in magenta,
/// inserted words washed in mint. Whitespace stays with the word before it, so the text reads unchanged.
enum WordDiff {
    /// Above this many words a diff stops being readable, so both versions show plain.
    static let limit = 4_000

    static func tokens(_ text: String) -> [Substring] {
        var result: [Substring] = []
        var start = text.startIndex, index = text.startIndex, inSpace = false
        while index < text.endIndex {
            let space = text[index].isWhitespace
            if !space && inSpace && start < index { result.append(text[start..<index]); start = index }
            inSpace = space
            index = text.index(after: index)
        }
        if start < text.endIndex { result.append(text[start...]) }
        return result
    }

    /// Indices of removed tokens in `old` and inserted tokens in `new`, compared ignoring trailing whitespace.
    static func changes(old: [Substring], new: [Substring]) -> (removed: IndexSet, inserted: IndexSet) {
        let difference = new.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .difference(from: old.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        var removed = IndexSet(), inserted = IndexSet()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        return (removed, inserted)
    }

    /// In dark mode the washes are stronger and an inserted word is itself neon mint (over 10:1 on its wash).
    static func marked(old: String, new: String, dark: Bool = false) -> (old: AttributedString, new: AttributedString) {
        let before = tokens(old), after = tokens(new)
        guard before.count + after.count <= limit, !before.isEmpty, !after.isEmpty else {
            return (AttributedString(old), AttributedString(new))
        }
        let changes = changes(old: before, new: after)
        return (build(before, marked: changes.removed) { word in
                    word.strikethroughStyle = Text.LineStyle(pattern: .solid, color: DaybookStyle.neonMagenta)
                    word.backgroundColor = DaybookStyle.neonMagenta.opacity(dark ? 0.20 : 0.16)
                },
                build(after, marked: changes.inserted) { word in
                    word.backgroundColor = DaybookStyle.neonMint.opacity(dark ? 0.22 : 0.16)
                    if dark { word.foregroundColor = DaybookStyle.neonMint }
                })
    }

    private static func build(_ tokens: [Substring], marked: IndexSet, style: (inout AttributedString) -> Void) -> AttributedString {
        var result = AttributedString()
        for (index, token) in tokens.enumerated() {
            guard marked.contains(index) else { result += AttributedString(token); continue }
            // Mark the word only; its trailing space joins the next word unmarked.
            let word = token.trimmingCharacters(in: .whitespacesAndNewlines)
            var styled = AttributedString(word)
            style(&styled)
            result += styled
            result += AttributedString(token.dropFirst(word.count))
        }
        return result
    }
}

// MARK: - Adjust Timing

struct AdjustTimingSheet: View {
    @ObservedObject var state: AppState
    let meeting: Meeting
    let trackID: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var automatic = true
    @State private var draft = ""

    private var track: RecordingTrack? { meeting.tracks.first { $0.id == trackID } }
    private var parsed: Double? { TimeField.parse(draft) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Adjust Timing for “\(track.map(name) ?? "Recording")”").font(.headline)
            Picker("", selection: $automatic) {
                Text("Automatically").tag(true)
                HStack(spacing: 8) {
                    Text("Starts at")
                    TextField("0:00", text: $draft).textFieldStyle(.roundedBorder).frame(width: 72).disabled(automatic)
                    Text("into the conversation")
                }
                .tag(false)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if meeting.alignmentReports.first(where: { $0.trackID == trackID })?.method == .unaligned {
                Label("Couldn’t line up automatically.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(Ink.warning)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    if let trackID { state.setOffset(meeting.id, trackID: trackID, seconds: automatic ? nil : parsed) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!automatic && parsed == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            automatic = track?.offset == nil
            draft = track?.offset.map(TimeLabel.short) ?? ""
        }
    }

    private func name(_ track: RecordingTrack) -> String { track.source == .imported ? track.fileName : track.source.recordingName }
}

enum TimeField {
    /// Accepts "42", "0:42", "1:02:03", and a leading minus for recordings that began earlier.
    static func parse(_ text: String) -> Double? {
        var value = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "−", with: "-")
        let negative = value.hasPrefix("-")
        if negative { value.removeFirst() }
        let parts = value.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil && $0!.isFinite && $0! >= 0 }) else { return nil }
        let seconds = parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
        return negative ? -seconds : seconds
    }
}

// MARK: - Review Earlier Corrections

struct ReviewCorrectionsSheet: View {
    @ObservedObject var state: AppState
    let meeting: Meeting
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var target: UUID?

    private var issues: [CorrectionTransferIssue] { meeting.correctionTransferIssues ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if issues.isEmpty {
                Text("All Corrections Reviewed").font(.headline)
                HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            } else {
                let issue = issues[min(index, issues.count - 1)]
                HStack {
                    Text("Review Earlier Corrections").font(.headline)
                    Spacer()
                    Text("\(min(index, issues.count - 1) + 1) of \(issues.count)").foregroundStyle(.secondary)
                }
                Text("You corrected this before the audio was transcribed again:").foregroundStyle(.secondary)
                Text("“\(issue.originalSegment.text)”").padding(10).frame(maxWidth: .infinity, alignment: .leading).quietBox()
                Text("Apply it to:").foregroundStyle(.secondary)
                ScrollView {
                    Picker("", selection: $target) {
                        ForEach(candidates(issue)) { segment in
                            Text("\(TimeLabel.short(segment.start))  \(meeting.speakerName(segment.speakerID).map { $0 + "  " } ?? "")\(String(segment.text.prefix(80)))")
                                .tag(UUID?.some(segment.id))
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                HStack {
                    Button("Keep in History Only") { resolve(issue, nil) }
                    Spacer()
                    Button("Skip") { index = (index + 1) % max(1, issues.count); target = nil }.disabled(issues.count < 2)
                    Button("Apply") { resolve(issue, target) }.keyboardShortcut(.defaultAction).disabled(target == nil)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { target = issues.first.flatMap { candidates($0).first?.id } }
    }

    private func candidates(_ issue: CorrectionTransferIssue) -> [TranscriptSegment] {
        let preferred = meeting.unifiedTranscript.filter { issue.candidateSegmentIDs.contains($0.id) }
        return preferred.isEmpty ? meeting.unifiedTranscript : preferred
    }

    private func resolve(_ issue: CorrectionTransferIssue, _ segment: UUID?) {
        state.update(meeting.id) { $0.resolveCorrectionTransfer(id: issue.id, targetSegmentID: segment) }
        target = nil
        if (state.selectedMeeting?.correctionTransferIssues ?? []).isEmpty { dismiss() }
        else { index = min(index, max(0, issues.count - 2)) }
    }
}

// MARK: - Original Transcript

struct OriginalTranscriptSheet: View {
    let meeting: Meeting
    let trackID: UUID
    @Environment(\.dismiss) private var dismiss

    private var track: RecordingTrack? { meeting.tracks.first { $0.id == trackID } }
    private var run: TrackTranscript? { meeting.transcripts.filter { $0.trackID == trackID }.max { $0.createdAt < $1.createdAt } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Original Transcript: \(track.map { $0.source == .imported ? $0.fileName : $0.source.recordingName } ?? "Recording")").font(.headline)
                Spacer()
                Button("Copy") {
                    LocalPasteboard.copy(run?.segments.map { "[\(TimeLabel.short($0.start))] \($0.text)" }.joined(separator: "\n") ?? "")
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(run?.segments ?? []) { segment in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(TimeLabel.short(segment.start)).font(.caption.monospacedDigit()).foregroundStyle(Ink.meta).frame(width: 44, alignment: .trailing)
                            Text(segment.text).foregroundStyle(Ink.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(16)
            }
            .background(DaybookStyle.paper)
        }
        .frame(width: 640, height: 560)
    }
}
