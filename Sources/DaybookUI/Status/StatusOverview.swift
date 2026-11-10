import DaybookDesign
import SwiftUI

// What's going on, at a glance and then in depth, the same on both apps (docs/interface.md, "Status overview"): the
// iPhone's status sheet and the open Duo's status panel draw it at each of their sizes, and Floating Notes' home at
// `.lines`. One line each for what's there (`StatusLines`, from DaybookKit's `StatusOverviewModel`); below them, at
// more depth, a group per kind of thing (`StatusGroup`), each a heading and a card, with the queue as rows
// (`StatusQueueRow`).

/// How deep the overview goes.
public enum StatusDensity: Int, CaseIterable, Comparable, Hashable, Sendable {
    /// One line each: the iPhone sheet's compact size and the Duo panel's.
    case lines
    /// The lines, then a card per kind of thing: what each device is doing, its handoff, the queue under the device
    /// doing it, with the choices they offer.
    case cards
    /// The cards with what can be done there: a recorder's storage, its actions, and the recordings waiting on it; this
    /// device's storage.
    case manage

    public static func < (lhs: StatusDensity, rhs: StatusDensity) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Below the lines, the groups show.
    public var showsGroups: Bool { self > .lines }
    /// The cards offer what can be done with each device.
    public var manages: Bool { self == .manage }
}

/// The overview: the lines, then (past `.lines`) the groups the caller gives, with the room between them the
/// surface's density sets.
public struct StatusOverview<Groups: View>: View {
    private let lines: [StatusLineItem]
    private let density: StatusDensity
    private let hint: (StatusLineItem) -> String?
    private let leads: (StatusLineItem) -> Bool
    private let choose: ((StatusLineItem) -> Void)?
    private let groups: Groups
    @Environment(\.daybookDensity) private var surface

    /// - Parameters:
    ///   - hint: What choosing a line does, for VoiceOver ("Shows more", "Opens iCloud settings").
    ///   - leads: Whether a line leads anywhere; one that doesn't is words only (Floating Notes' queue and iCloud lines).
    ///   - choose: What a line leads to; nil draws the lines as words only.
    public init(lines: [StatusLineItem], density: StatusDensity, hint: @escaping (StatusLineItem) -> String? = { _ in nil },
                leads: @escaping (StatusLineItem) -> Bool = { _ in true }, choose: ((StatusLineItem) -> Void)? = nil,
                @ViewBuilder groups: () -> Groups) {
        self.lines = lines
        self.density = density
        self.hint = hint
        self.leads = leads
        self.choose = choose
        self.groups = groups()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: surface == .touch ? DaybookSpacing.s5 : DaybookSpacing.s4) {
            if !lines.isEmpty {
                StatusLines(lines, hint: hint, leads: leads, choose: choose)
            }
            if density.showsGroups {
                groups
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension StatusOverview where Groups == EmptyView {
    /// Lines alone.
    public init(lines: [StatusLineItem], hint: @escaping (StatusLineItem) -> String? = { _ in nil },
                leads: @escaping (StatusLineItem) -> Bool = { _ in true }, choose: ((StatusLineItem) -> Void)? = nil) {
        self.init(lines: lines, density: .lines, hint: hint, leads: leads, choose: choose) { EmptyView() }
    }
}

/// Status lines, one per thing, each one element for VoiceOver ("Soundcore Work, Connected · 80%"). A line that
/// leads somewhere is a button: to its device's page, to the fix for what needs the person, or to more of the
/// overview. One that leads nowhere is its words only.
public struct StatusLines: View {
    private let lines: [StatusLineItem]
    private let hint: (StatusLineItem) -> String?
    private let leads: (StatusLineItem) -> Bool
    private let choose: ((StatusLineItem) -> Void)?
    @Environment(\.daybookDensity) private var density

    public init(_ lines: [StatusLineItem], hint: @escaping (StatusLineItem) -> String? = { _ in nil },
                leads: @escaping (StatusLineItem) -> Bool = { _ in true }, choose: ((StatusLineItem) -> Void)? = nil) {
        self.lines = lines
        self.hint = hint
        self.leads = leads
        self.choose = choose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: density == .touch ? DaybookSpacing.s2 : 7) {
            ForEach(lines) { line in
                if let choose, leads(line) {
                    Button { choose(line) } label: { StatusLineView(line) }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(line.accessibilityLabel)
                        .accessibilityHint(hint(line) ?? "")
                        .accessibilityAddTraits(.isButton)
                } else {
                    StatusLineView(line)
                }
            }
        }
    }
}
