import DaybookDesign
import DaybookKit
import SwiftUI

// Correcting a passage and renaming a speaker, the same on both apps: in place on a regular page, a sheet on a narrow
// one; Heard In and Rename as popovers, which become sheets where a popover has no room (the iPhone in the hand).
// Each edit is recorded in Version History, and Undo takes it back.

/// The edits the transcript makes, each undoable under its menu item's name.
@MainActor
public enum TranscriptEdits {
    /// Corrects a passage. Nothing changes when the words are the same or empty.
    @discardableResult
    public static func correct(_ segmentID: UUID, text: String, in meetingID: UUID, library: LibraryController,
                               undoManager: UndoManager?) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        return library.update(meetingID, actionName: "Correct Passage", undoManager: undoManager) {
            $0.correctSegment(id: segmentID, text: text)
        }
    }

    /// Renames a speaker everywhere in the conversation. Nothing changes for an empty or unchanged name.
    @discardableResult
    public static func rename(_ speakerID: String, to name: String, in meetingID: UUID, library: LibraryController,
                              undoManager: UndoManager?) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        return library.update(meetingID, actionName: "Rename Speaker", undoManager: undoManager) {
            $0.renameSpeaker(id: speakerID, name: name)
        }
    }

    /// A bookmark at a passage, in the recording it came from.
    public static func bookmark(_ segment: TranscriptSegment, in meetingID: UUID, library: LibraryController) {
        let start = segment.provenance.first { $0.trackID == segment.trackID }?.start ?? segment.start
        library.addBookmark(in: meetingID, trackID: segment.trackID, at: start)
    }
}

/// Correcting a passage in place, on a regular page: the words in a field on the passage's edge. Return saves, Esc
/// cancels, as do the buttons under it.
struct InlinePassageEditor: View {
    @Binding var text: String
    let save: () -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.daybookDensity) private var density
    @Environment(\.readingScale) private var scale

    var body: some View {
        TranscriptMarginRow {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: DaybookSpacing.s2) {
                TextField("Passage", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(DaybookFont.body.font(density, scale: scale))
                    .foregroundStyle(DaybookPalette.Ink.body)
                    .lineSpacing(DaybookFont.bodyLineSpacing(density, scale: scale))
                    .padding(8)
                    .background(DaybookPalette.paper, in: DaybookRadius.shape(4))
                    .overlay(DaybookRadius.shape(4).stroke(DaybookPalette.accent, lineWidth: 1.5))
                    // The words stay on the passage's edge; the field's frame hangs into the gutter.
                    .padding(.horizontal, -8)
                    .focused($focused)
                    .onSubmit(save)
                    #if os(macOS)
                    // The field's own Escape (cancelOperation), which a key handler doesn't see.
                    .onExitCommand(perform: cancel)
                    #else
                    .onKeyPress(.escape) { cancel(); return .handled }
                    #endif
                    .accessibilityLabel("Corrected passage")
                HStack(spacing: DaybookSpacing.s4) {
                    Button("Cancel", action: cancel)
                    Button("Save", action: save).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .buttonStyle(.daybookLink)
                .font(DaybookFont.statusLead.font(density))
            }
        }
        .onAppear { focused = true }
    }
}

/// Correct Passage as a sheet, on a narrow page: who said it and when, and the words, editable. The model's original
/// stays in Version History. While the words differ from the passage's, a swipe can't close it, and Cancel asks first.
public struct CorrectPassageSheet: View {
    private let library: LibraryController
    private let meetingID: UUID
    private let segmentID: UUID
    private let close = SheetDismiss()
    @State private var draft: String?
    @State private var confirmingDiscard = false
    @FocusState private var focused: Bool
    @Environment(\.undoManager) private var undoManager
    @Environment(\.daybookDensity) private var density

    public init(library: LibraryController, meetingID: UUID, segmentID: UUID) {
        self.library = library
        self.meetingID = meetingID
        self.segmentID = segmentID
    }

    private var segment: TranscriptSegment? { library.meeting(meetingID)?.unifiedTranscript.first { $0.id == segmentID } }

    /// The words typed differ from the passage's: closing would lose them.
    static func hasChanges(draft: String?, original: String) -> Bool {
        guard let draft else { return false }
        return draft.trimmingCharacters(in: .whitespacesAndNewlines) != original.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var body: some View {
        NavigationStack {
            if let meeting = library.meeting(meetingID), let segment {
                let changed = Self.hasChanges(draft: draft, original: segment.text)
                VStack(alignment: .leading, spacing: DaybookSpacing.s3) {
                    HStack(spacing: DaybookSpacing.s2) {
                        Text(meeting.speakerName(segment.speakerID) ?? "Unknown speaker")
                            .font(DaybookFont.speaker.font(density))
                            .foregroundStyle(DaybookPalette.speakerInk(meeting.speakerIndex(segment.speakerID)))
                        Text(TimeLabel.short(segment.start)).font(DaybookFont.time.font(density)).foregroundStyle(DaybookPalette.Ink.meta)
                    }
                    TextEditor(text: Binding(get: { draft ?? segment.text }, set: { draft = $0 }))
                        .font(DaybookFont.body.font(density))
                        .foregroundStyle(DaybookPalette.Ink.body)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .background(DaybookPalette.quietFill, in: DaybookRadius.shape(DaybookRadius.box))
                        .overlay(DaybookRadius.shape(DaybookRadius.box).stroke(DaybookPalette.accent, lineWidth: 1.5))
                        .focused($focused)
                        .frame(minHeight: 120)
                        .accessibilityLabel("Corrected passage")
                    Spacer(minLength: 0)
                }
                .padding(density == .touch ? 20 : DaybookSpacing.s5)
                .background(DaybookPalette.paper.ignoresSafeArea())
                .navigationTitle("Correct Passage")
                .touchInlineTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { if changed { confirmingDiscard = true } else { close() } }
                            .keyboardShortcut(.cancelAction)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            if changed, let draft {
                                TranscriptEdits.correct(segmentID, text: draft, in: meetingID, library: library, undoManager: undoManager)
                            }
                            close()
                        }
                        .fontWeight(.semibold)
                        .disabled((draft ?? segment.text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .interactiveDismissDisabled(changed)
                .confirmationDialog("Discard your changes to this passage?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                    Button("Discard Changes", role: .destructive) { close() }
                    Button("Keep Editing", role: .cancel) { }
                }
                .onAppear { focused = true }
            } else {
                ContentUnavailableView("Passage Not Found", systemImage: "text.quote")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { close() } } }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #else
        .frame(minWidth: 460, idealWidth: 520, minHeight: 280)
        #endif
    }
}

/// Which recordings heard a passage, each with what it heard and a way to play it from there.
public struct HeardInRecordings: View {
    private let meeting: Meeting
    private let segment: TranscriptSegment
    private let recordingName: (RecordingTrack) -> String
    private let play: (PlaybackTarget) -> Void
    private let dismiss = SheetDismiss()
    @Environment(\.daybookDensity) private var density

    public init(meeting: Meeting, segment: TranscriptSegment, recordingName: @escaping (RecordingTrack) -> String,
                play: @escaping (PlaybackTarget) -> Void) {
        self.meeting = meeting
        self.segment = segment
        self.recordingName = recordingName
        self.play = play
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DaybookSpacing.s3) {
            HStack(alignment: .firstTextBaseline) {
                Text("Heard in \(segment.provenance.count) Recordings").font(.headline).foregroundStyle(DaybookPalette.Ink.title)
                Spacer()
                #if os(iOS)
                Button("Done") { dismiss() }.buttonStyle(.daybookLink).fontWeight(.semibold).daybookHitTarget()
                #endif
            }
            ForEach(Array(segment.provenance.enumerated()), id: \.offset) { _, source in
                let track = meeting.tracks.first { $0.id == source.trackID }
                VStack(alignment: .leading, spacing: 3) {
                    Button {
                        if let track { play(.source(track, source.start)); dismiss() }
                    } label: {
                        Label("\(track.map(recordingName) ?? "Recording") · \(TimeLabel.short(source.start))", systemImage: "play.fill")
                            .monospacedDigit()
                    }
                    .buttonStyle(.daybookLink)
                    .disabled(track == nil)
                    Text("“\(source.text)”")
                        .font(DaybookFont.status.font(density))
                        .foregroundStyle(DaybookPalette.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(density == .touch ? 20 : 14)
        .frame(width: density == .touch ? nil : 300, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationCompactAdaptation(.sheet)
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }
}

/// Rename Speaker: the name, changed for every passage of theirs in this conversation.
struct RenameSpeakerForm: View {
    let name: String
    let save: (String) -> Void
    private let dismiss = SheetDismiss()
    @Environment(\.daybookDensity) private var density
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: DaybookSpacing.s3) {
            Text("Rename Speaker").font(.headline).foregroundStyle(DaybookPalette.Ink.title)
            TextField("Name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .touchKeyboard(capitalization: .words)
                .focused($focused)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(density == .touch ? 20 : 16)
        .frame(width: density == .touch ? nil : 252, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationCompactAdaptation(.sheet)
        #if os(iOS)
        .presentationDetents([.height(220)])
        #endif
        .onAppear { draft = name; focused = true }
    }

    private func commit() {
        guard !trimmed.isEmpty else { return }
        if trimmed != name { save(trimmed) }
        dismiss()
    }
}
