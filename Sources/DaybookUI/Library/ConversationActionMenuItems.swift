import DaybookDesign
import DaybookKit
import SwiftUI

/// Where a search result asks a conversation's page to show it, besides a transcript passage (which goes by the
/// passage's own ID): the notes, for a match found there.
public enum PageAnchor {
    /// "Your notes".
    public static let notes = UUID(uuidString: "6E6F7465-7300-4000-8000-000000000001")!
}

/// A conversation's actions (DaybookKit's `ConversationActions`) as menu items, in their one order, a divider
/// between groups: a row's menu and a selection's on both apps. What doesn't apply now is dimmed on the Mac, with
/// why as its help, and left out on the iPhone. An action with children is a submenu; `custom` draws one itself
/// (the Mac's Move to Folder lists the folders), and returns nil for the rest.
public struct ConversationActionMenuItems: View {
    private let groups: [ConversationActionGroup]
    private let platform: ConversationAction.Platform
    private let perform: (ConversationAction.ID) -> Void
    private let custom: (ConversationAction) -> AnyView?

    public init(_ groups: [ConversationActionGroup], platform: ConversationAction.Platform,
                perform: @escaping (ConversationAction.ID) -> Void, custom: @escaping (ConversationAction) -> AnyView? = { _ in nil }) {
        self.groups = groups
        self.platform = platform
        self.perform = perform
        self.custom = custom
    }

    public var body: some View {
        let shown = Self.shown(groups, on: platform)
        ForEach(Array(shown.enumerated()), id: \.element.id) { index, group in
            if index > 0 { Divider() }
            ForEach(group.actions) { action in item(action) }
        }
    }

    private func item(_ action: ConversationAction) -> AnyView {
        if let view = custom(action) { return view }
        let reason: String? = { if case .unavailable(let why) = action.availability { return why } else { return nil } }()
        if !action.children.isEmpty {
            return AnyView(
                Menu {
                    ForEach(action.children) { child in item(child) }
                } label: {
                    Label(action.title, systemImage: action.symbol)
                }
                .disabled(!action.isAvailable)
                .help(reason ?? "")
            )
        }
        return AnyView(
            Button(role: action.role == .destructive ? .destructive : nil) { perform(action.id) } label: {
                Label(action.title, systemImage: action.symbol)
            }
            .disabled(!action.isAvailable)
            .help(reason ?? "")
        )
    }

    /// The groups as `platform` shows them: on the iPhone without what doesn't apply now (and without a group left
    /// empty by that); on the Mac as they are, to be dimmed.
    public static func shown(_ groups: [ConversationActionGroup], on platform: ConversationAction.Platform) -> [ConversationActionGroup] {
        guard platform == .iPhone else { return groups }
        func keep(_ action: ConversationAction) -> ConversationAction? {
            guard action.isAvailable else { return nil }
            var action = action
            action.children = action.children.compactMap(keep)
            return action
        }
        return groups.compactMap { group in
            let actions = group.actions.compactMap(keep)
            return actions.isEmpty ? nil : ConversationActionGroup(id: group.id, actions: actions)
        }
    }

    /// The first action with `id` in `groups`, at any depth.
    public static func action(_ id: ConversationAction.ID, in groups: [ConversationActionGroup]) -> ConversationAction? {
        func find(_ actions: [ConversationAction]) -> ConversationAction? {
            for action in actions {
                if action.id == id { return action }
                if let child = find(action.children) { return child }
            }
            return nil
        }
        return groups.lazy.compactMap { find($0.actions) }.first
    }

    /// An action's word on a bar or a swipe, where there's room for one: "Move", "Tags", "Personal", "Summarize",
    /// "Trash".
    public static func shortTitle(_ action: ConversationAction) -> String {
        switch action.id {
        case .moveToFolder: return "Move"
        case .tags: return "Tags"
        case .moveTo(.work): return "Work"
        case .moveTo(.personal): return "Personal"
        case .process(.summaryOnly): return "Summarize"
        case .moveToTrash: return "Trash"
        default: return action.title.replacingOccurrences(of: "…", with: "")
        }
    }
}
