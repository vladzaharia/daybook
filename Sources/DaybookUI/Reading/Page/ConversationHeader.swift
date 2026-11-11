import DaybookDesign
import DaybookKit
import SwiftUI

/// What a title edit commits, the same on both apps: the draft, trimmed, once editing ends; never an empty title (the
/// earlier one comes back) and nothing when it didn't change.
public enum TitleEdit {
    /// The title to save for `draft`, or nil to keep `current` (and put it back in the field).
    public static func committed(draft: String, current: String) -> String? {
        let title = draft.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != current else { return nil }
        return title
    }

    /// Return ends the title: a draft with a line break in it is the end of editing.
    public static func endsEditing(_ draft: String) -> Bool { draft.contains("\n") }
}

/// A conversation's title and its one byline, the same on Summary and Transcript and on both apps, so switching
/// feels like turning the page. The title is a field: a draft, saved once when editing ends (Return, or leaving it),
/// with Undo, never left empty. The byline is the recording's state (the play pill, "Recording", or "Notes only"),
/// when it was, and who was in it: on one line when it fits, the people on their own line when it doesn't, then a
/// shorter date, then the date under the pill. The pill never shortens and the date never goes. The people open Info.
public struct ConversationHeader<Pill: View>: View {
    private let meeting: Meeting
    private let library: LibraryController
    private let recording: String?
    private let focusTitle: Bool
    private let titleFocused: () -> Void
    private let pill: Pill
    @State private var draft = ""
    @FocusState private var editing: Bool
    @Environment(\.readingContext) private var context
    @Environment(\.readingWidth) private var readingWidth
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.daybookDensity) private var density

    /// - Parameters:
    ///   - recording: The byline's words while this conversation records ("Recording", "Recording on Studio Mac").
    ///   - focusTitle: Put the cursor in the title now (a new note); `titleFocused` says it's done.
    ///   - pill: The play pill (`ConversationPlayPill`), shown when the conversation has a recording and isn't recording.
    public init(meeting: Meeting, library: LibraryController, recording: String? = nil, focusTitle: Bool = false,
                titleFocused: @escaping () -> Void = {}, @ViewBuilder pill: () -> Pill) {
        self.meeting = meeting
        self.library = library
        self.recording = recording
        self.focusTitle = focusTitle
        self.titleFocused = titleFocused
        self.pill = pill()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: density == .touch ? DaybookSpacing.s2 : 6) {
            TextField("Untitled Conversation", text: titleBinding, axis: .vertical)
                .daybookFont(.docTitle)
                .foregroundStyle(DaybookPalette.Ink.title)
                .textFieldStyle(.plain)
                // A long title shows whole; it never stops mid-phrase inside the field.
                .lineLimit(readingWidth == .narrow ? 1...8 : 1...4)
                .focused($editing)
                .touchKeyboard(submit: .done)
                .onSubmit { editing = false }
                .accessibilityLabel("Title")
                .onAppear {
                    draft = meeting.title
                    focusIfAsked()
                }
                .onChange(of: meeting.title) { _, title in if !editing { draft = title } }
                .onChange(of: meeting.id) { old, _ in
                    // Another conversation in the same place: what was typed goes to the one it was typed for.
                    if editing { commit(to: old) }
                    draft = meeting.title
                }
                .onChange(of: editing) { _, now in if !now { commit() } }
                .onChange(of: focusTitle) { _, _ in focusIfAsked() }
                .onDisappear { if editing { commit() } }
            byline
        }
    }

    private var titleBinding: Binding<String> {
        Binding(get: { draft }, set: { value in
            if TitleEdit.endsEditing(value) {
                draft = value.replacingOccurrences(of: "\n", with: "")
                editing = false
            } else {
                draft = value
            }
        })
    }

    private func focusIfAsked() {
        guard focusTitle else { return }
        Task { @MainActor in
            editing = true
            titleFocused()
        }
    }

    private func commit() { commit(to: meeting.id) }

    /// Saves the draft as `id`'s title, once and never empty; otherwise the field shows the title again.
    private func commit(to id: Meeting.ID) {
        let current = library.meeting(id)?.title ?? meeting.title
        guard let title = TitleEdit.committed(draft: draft, current: current) else {
            draft = meeting.title
            return
        }
        draft = title
        library.update(id, actionName: "Rename", undoManager: undoManager) { $0.title = title }
    }

    // MARK: Byline

    private var people: String? { recording == nil ? meeting.peopleLine : nil }

    private var byline: some View {
        ViewThatFits(in: .horizontal) {
            line(month: .wide, people: true)
            line(month: .abbreviated, people: true)
            VStack(alignment: .leading, spacing: DaybookSpacing.s1) {
                // The people go to their own line, the date shortens, and then it goes under the pill: neither is cut.
                ViewThatFits(in: .horizontal) {
                    line(month: .wide, people: false)
                    line(month: .abbreviated, people: false)
                    VStack(alignment: .leading, spacing: DaybookSpacing.s1) {
                        if hasLead { lead.fixedSize() }
                        date(month: .abbreviated).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let people { peopleButton(people).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .daybookFont(.byline)
        .foregroundStyle(DaybookPalette.Ink.secondary)
    }

    private func line(month: Date.FormatStyle.Symbol.Month, people showsPeople: Bool) -> some View {
        HStack(spacing: 0) {
            if hasLead {
                lead
                separator
            }
            date(month: month)
            if showsPeople, let people {
                separator
                peopleButton(people)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    private func date(month: Date.FormatStyle.Symbol.Month) -> Text {
        Text(meeting.date.formatted(.dateTime.weekday(.abbreviated).day().month(month).hour().minute()))
    }

    private var hasLead: Bool { recording != nil || meeting.duration != nil || meeting.presentTracks.isEmpty }

    /// The recording's state: recording now, its play pill, or no recording at all.
    @ViewBuilder private var lead: some View {
        if let recording {
            HStack(spacing: 5) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(DaybookPalette.Ink.record)
                    .symbolEffect(.breathe, options: reduceMotion ? .nonRepeating : .repeating)
                    .daybookGlow(DaybookPalette.Ink.record, radius: 4)
                    .accessibilityHidden(true)
                Text(recording)
            }
        } else if meeting.duration != nil {
            pill
        } else if meeting.presentTracks.isEmpty {
            Text("Notes only")
        }
    }

    private var separator: some View {
        Text("·").foregroundStyle(DaybookPalette.Ink.meta).padding(.horizontal, 6).accessibilityHidden(true)
    }

    private func peopleButton(_ people: String) -> some View {
        Button { context.navigator.showInfo(meeting.id) } label: {
            QuietLink(rest: DaybookPalette.Ink.secondary, touch: DaybookPalette.Ink.secondary) {
                Text(people).multilineTextAlignment(.leading)
            }
        }
        .buttonStyle(.plain)
        .help("Show the people in this conversation")
        .accessibilityHint("Shows the people in this conversation")
    }
}
