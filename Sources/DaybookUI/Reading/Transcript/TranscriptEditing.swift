import DaybookCore
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

    /// Renames a speaker everywhere in the conversation. Nothing changes for an empty or unchanged name. The person's own
    /// profile (its row, `picked`, or its name typed) marks the speaker as them, as This Is Me does.
    @discardableResult
    public static func rename(_ speakerID: String, to name: String, picked: UUID? = nil, in meetingID: UUID, library: LibraryController,
                              undoManager: UndoManager?) -> Bool {
        library.renameSpeakers([speakerID], to: name, picked: picked, in: meetingID, undoManager: undoManager)
    }

    /// Gives passages to another speaker of the conversation (`LibraryController.giveSpeaker`); Undo gives each back.
    @discardableResult
    public static func changeSpeaker(of passageIDs: [UUID], to speakerID: String, in meetingID: UUID, library: LibraryController,
                                     undoManager: UndoManager?) -> Bool {
        library.giveSpeaker(speakerID, toPassages: passageIDs, in: meetingID, undoManager: undoManager)
    }

    /// Gives passages to a new speaker called `name`, or the one that has that name already (`giveNewSpeaker`).
    @discardableResult
    public static func changeSpeaker(of passageIDs: [UUID], toNew name: String, picked: UUID? = nil, in meetingID: UUID,
                                     library: LibraryController, undoManager: UndoManager?) -> Bool {
        library.giveNewSpeaker(named: name, picked: picked, toPassages: passageIDs, in: meetingID, undoManager: undoManager)
    }

    /// Keeps words marked unsure as they are: the mark goes, on every device. The transcript doesn't change. Undo takes
    /// the answer back (`Meeting.withdrawFlagAnswer`), that answer alone, and Redo gives it again.
    @discardableResult
    public static func keep(_ flagID: UUID, in meetingID: UUID, library: LibraryController, undoManager: UndoManager?) -> Bool {
        var kept = false
        library.update(meetingID) { kept = $0.keepFlaggedWords(flagID) }
        guard kept else { return false }
        registerUndo(library, meetingID, undoManager, "Keep Words",
                     undo: { $0.withdrawFlagAnswer(flagID) }, redo: { $0.keepFlaggedWords(flagID) })
        return true
    }

    /// Puts the earlier reading in place of words marked unsure: a correction, in Version History. Undo puts back that
    /// passage's words and takes back that answer, nothing else (`Meeting.takeBackFlagAlternative`); Redo uses it again.
    @discardableResult
    public static func useAlternative(_ flagID: UUID, in meetingID: UUID, library: LibraryController,
                                      undoManager: UndoManager?) -> Bool {
        guard let before = library.meeting(meetingID) else { return false }
        var used = false
        library.update(meetingID) { used = $0.useFlagAlternative(flagID) }
        guard used, let after = library.meeting(meetingID),
              let changed = after.unifiedTranscript.first(where: { passage in before.unifiedTranscript.first { $0.id == passage.id }?.text != passage.text }),
              let original = before.unifiedTranscript.first(where: { $0.id == changed.id })?.text else { return used }
        registerUndo(library, meetingID, undoManager, "Correct Passage",
                     undo: { $0.takeBackFlagAlternative(flagID, in: changed.id, from: changed.text, to: original) },
                     redo: { $0.useFlagAlternative(flagID) })
        return true
    }

    /// An edit that Undo takes back with `undo` and Redo does again with `redo`, each a change of its own that touches
    /// only what it names, so whatever arrived meanwhile (another device's answers) stays.
    private static func registerUndo(_ library: LibraryController, _ meetingID: UUID, _ undoManager: UndoManager?, _ actionName: String,
                                     undo: @escaping (inout Meeting) -> Void, redo: @escaping (inout Meeting) -> Void) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: library) { library in
            library.update(meetingID) { undo(&$0) }
            registerUndo(library, meetingID, undoManager, actionName, undo: redo, redo: undo)
        }
        undoManager.setActionName(actionName)
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
        content
        .presentationCompactAdaptation(.sheet)
        #if os(iOS)
        .presentationDetents(density == .touch ? [.medium] : [.medium, .large])
        #endif
    }

    private var title: String { "Heard in \(segment.provenance.count) Recordings" }

    @ViewBuilder private var content: some View {
        #if os(iOS)
        if density == .touch {
            NavigationStack {
                List {
                    ForEach(Array(segment.provenance.enumerated()), id: \.offset) { _, source in
                        let track = meeting.tracks.first { $0.id == source.trackID }
                        VStack(alignment: .leading, spacing: 3) {
                            Button {
                                if let track { play(.source(track, source.start)); dismiss() }
                            } label: {
                                Label("\(track.map(recordingName) ?? "Recording") · \(TimeLabel.short(source.start))", systemImage: "play.fill")
                                    .monospacedDigit()
                                    .foregroundStyle(DaybookPalette.Ink.link)
                            }
                            .disabled(track == nil)
                            Text("“\(source.text)”")
                                .font(DaybookFont.status.font(density))
                                .foregroundStyle(DaybookPalette.Ink.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(role: .close) { dismiss() }.tint(DaybookPalette.Ink.title) } }
            }
        } else {
            popover
        }
        #else
        popover
        #endif
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: DaybookSpacing.s3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline).foregroundStyle(DaybookPalette.Ink.title)
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
    }
}

/// Rename Speaker: the name, changed for every passage of theirs in this conversation.
struct RenameSpeakerForm: View {
    /// "Rename Speaker", or "New Speaker" where the name is a speaker to be made.
    var title = "Rename Speaker"
    /// The button that saves it.
    var action = "Rename"
    let name: String
    let profiles: [SpeakerProfile]
    let me: UUID?
    /// The name, and the profile when it's a row of the name list that was picked.
    let save: (String, UUID?) -> Void
    private let dismiss = SheetDismiss()
    @Environment(\.daybookDensity) private var density
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    @ViewBuilder private var form: some View {
        if density == .touch {
            NavigationStack {
                VStack(alignment: .leading, spacing: DaybookSpacing.s3) {
                    SpeakerNameField(current: name, draft: $draft, isFocused: focused, profiles: profiles, me: me, commit: commit, showsGlyphs: true) {
                        TextField("Name", text: $draft)
                            .touchKeyboard(capitalization: .words)
                            .focused($focused)
                            .padding(.horizontal, DaybookSpacing.s3)
                            .frame(minHeight: 44)
                            .background(DaybookPalette.quietFill, in: DaybookRadius.shape(DaybookRadius.box))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DaybookSpacing.s4)
                .padding(.top, DaybookSpacing.s3)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(DaybookPalette.paper.ignoresSafeArea())
                .navigationTitle(title)
                .touchInlineTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(action) { commit(draft, nil) }.fontWeight(.semibold).disabled(trimmed.isEmpty)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: DaybookSpacing.s3) {
                Text(title).font(.headline).foregroundStyle(DaybookPalette.Ink.title)
                SpeakerNameField(current: name, draft: $draft, isFocused: focused, profiles: profiles, me: me, commit: commit) {
                    TextField("Name", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .touchKeyboard(capitalization: .words)
                        .focused($focused)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(action) { commit(draft, nil) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(trimmed.isEmpty)
                }
            }
            .padding(16)
            .frame(width: 252, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var body: some View {
        form
        .presentationCompactAdaptation(.sheet)
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
        .onAppear {
            draft = name; focused = true
            #if DEBUG
            if let typed = SpeakerNamePickerDemo.draft { draft = typed }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                focused = true
            }
            #endif
        }
    }

    private func commit(_ chosen: String, _ picked: UUID?) {
        let value = chosen.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if value != name { save(value, picked) }
        dismiss()
    }
}
