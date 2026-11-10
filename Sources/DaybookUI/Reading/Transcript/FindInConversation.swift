#if os(macOS)
import AppKit
#endif
import DaybookDesign
import DaybookKit
import Observation
import SwiftUI

/// Find in Conversation (⌘F): a bar over the transcript with what's typed and how many passages, notes, and photos
/// hold it, stepping through them with Find Next (⌘G) and Find Previous (⇧⌘G). Matches are marked as the library
/// search marks them, and the one shown now is washed. The app keeps one per window, so its menu items reach it.
@MainActor
@Observable
public final class ConversationFind {
    public private(set) var isShown = false
    public var query = "" {
        didSet { if query != oldValue { recount() } }
    }
    public private(set) var matches = TranscriptFindMatches()
    /// Bumped to move the page to the current match.
    public private(set) var stepToken = 0
    /// Bumped to put the keyboard in the field.
    public private(set) var focusToken = 0
    @ObservationIgnored private var rows: [TranscriptRow] = []
    /// The conversation it finds in: another one starts it over.
    @ObservationIgnored private var meetingID: UUID?

    public init() {}

    /// What the page marks: the query while the bar shows.
    public var highlight: String { isShown ? query : "" }
    /// "3 of 12", "No matches", or nothing before anything is typed.
    public var label: String? { matches.label(query: query) }
    public var canStep: Bool { matches.count > 0 }

    /// Shows the bar with the keyboard in it, for a conversation when it's said (another one starts it over).
    public func show(in meetingID: UUID? = nil) {
        if let meetingID, meetingID != self.meetingID { reset(to: meetingID) }
        isShown = true
        focusToken += 1
        if matches.count > 0 { stepToken += 1 }
    }

    /// Hides the bar and its marks; what was typed stays for next time.
    public func close() { isShown = false }

    public func next() { step(1) }
    public func previous() { step(-1) }

    private func step(_ delta: Int) {
        guard isShown else { return show() }
        guard matches.count > 0 else { return }
        matches.step(delta)
        stepToken += 1
    }

    /// The transcript shows, or changed (a correction): count again, staying on the same row when it still matches.
    /// Another conversation's starts it over, closed.
    func use(_ rows: [TranscriptRow], in meetingID: UUID) {
        if meetingID != self.meetingID { reset(to: meetingID) }
        self.rows = rows
        matches = matches.refreshed(query: query, in: rows)
    }

    private func reset(to meetingID: UUID) {
        self.meetingID = meetingID
        rows = []
        isShown = false
        query = ""
        matches = TranscriptFindMatches()
    }

    private func recount() {
        matches = TranscriptFindMatches(query: query, in: rows)
        if matches.count > 0 { stepToken += 1 }
    }
}

/// The find bar: the field, the count, Previous and Next, and Done.
struct ConversationFindBar: View {
    @Bindable var find: ConversationFind
    @FocusState private var focused: Bool
    @Environment(\.daybookDensity) private var density

    var body: some View {
        HStack(spacing: DaybookSpacing.s2) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Find in Conversation", text: $find.query)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { find.next() }
                #if os(macOS)
                // The field's own Escape (cancelOperation), which a key handler doesn't see.
                .onExitCommand { find.close() }
                #else
                .onKeyPress(.escape) { find.close(); return .handled }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    find.previous()
                    return .handled
                }
                #endif
                .accessibilityLabel("Find in Conversation")
            if let label = find.label {
                Text(label)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityLabel(find.canStep ? label : "No matches")
            }
            Button { find.previous() } label: { Image(systemName: "chevron.up") }
                .disabled(!find.canStep)
                .accessibilityLabel("Find Previous")
                .macHelp("Find Previous (⇧⌘G)")
            Button { find.next() } label: { Image(systemName: "chevron.down") }
                .disabled(!find.canStep)
                .accessibilityLabel("Find Next")
                .macHelp("Find Next (⌘G)")
            Button("Done") { find.close() }
        }
        .buttonStyle(.borderless)
        .controlSize(density == .touch ? .regular : .small)
        .padding(.horizontal, DaybookSpacing.s3)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onChange(of: find.focusToken, initial: true) { _, _ in focused = true }
    }
}

extension View {
    /// The find bar pinned over the page while it shows; on macOS 26 it joins the toolbar's scroll edge. The page keeps
    /// its identity (and its place) as the bar comes and goes.
    @ViewBuilder
    func conversationFindBar(_ find: ConversationFind?) -> some View {
        #if os(macOS)
        if #available(macOS 26, *) {
            safeAreaBar(edge: .top, spacing: 0) { FindBarSlot(find: find) }
        } else {
            safeAreaInset(edge: .top, spacing: 0) { FindBarSlot(find: find) }
        }
        #else
        safeAreaBar(edge: .top, spacing: 0) { FindBarSlot(find: find) }
        #endif
    }

    /// ⌘F, ⌘G, and ⇧⌘G while the page shows: the window's own keys come before the menu's. On the Mac, text with a find
    /// bar of its own that has the keyboard (the notes on the summary beside the transcript) finds in itself, as it
    /// does with the summary alone (`FocusedTextFinder`).
    func conversationFindKeys(_ find: ConversationFind?) -> some View {
        background {
            if let find {
                Group {
                    Button("Find in Conversation") { if !FocusedTextFinder.perform(.show) { find.show() } }.keyboardShortcut("f")
                    Button("Find Next") { if !FocusedTextFinder.perform(.next) { find.next() } }.keyboardShortcut("g")
                    Button("Find Previous") { if !FocusedTextFinder.perform(.previous) { find.previous() } }
                        .keyboardShortcut("g", modifiers: [.command, .shift])
                }
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
        }
    }
}

/// The text view with a find bar of its own that has the keyboard in the key window (on the Mac, the notes editor), which
/// Find, Find Next, and Find Previous reach before the conversation's find. A field (the find bar's, a passage being
/// corrected) has none.
@MainActor
enum FocusedTextFinder {
    enum Step { case show, next, previous }

    /// Asks the focused text to find; false when there's none, for the conversation's find to answer.
    static func perform(_ step: Step) -> Bool {
        #if os(macOS)
        guard let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.usesFindBar, !text.isFieldEditor else { return false }
        let sender = NSMenuItem()
        switch step {
        case .show: sender.tag = NSTextFinder.Action.showFindInterface.rawValue
        case .next: sender.tag = NSTextFinder.Action.nextMatch.rawValue
        case .previous: sender.tag = NSTextFinder.Action.previousMatch.rawValue
        }
        text.performTextFinderAction(sender)
        return true
        #else
        return false
        #endif
    }
}

/// The bar while Find shows, else nothing; the page keeps its identity (and its place) as the bar comes and goes.
private struct FindBarSlot: View {
    let find: ConversationFind?

    var body: some View {
        if let find, find.isShown {
            ConversationFindBar(find: find)
                .daybookTransition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}
