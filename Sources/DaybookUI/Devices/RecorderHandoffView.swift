import DaybookDesign
import DaybookKit
import SwiftUI

// Moving a recorder between devices (docs/devices.md, "Handing a recorder over"), by one set of rules on both: at
// rest, "Use on This Mac" while another device manages it, or "Use on Alex’s iPhone" for each device it could go
// to; under way, a bare line with a spinner and its detail, and Stop Waiting wherever waiting can be called off;
// refused, or waiting too long, a warning box with at most two actions. The words are DaybookKit's
// `RecorderHandoff.Words`. The Mac keeps the same moves in its menus (`RecorderHandoffMenuItems`).

/// What the handoff shows for a recorder now, as plain values.
public enum RecorderHandoffPresentation: Equatable {
    /// One way the recorder can move, at rest.
    public struct Move: Equatable, Identifiable {
        public enum Kind: Equatable { case here, give(UUID) }
        public var kind: Kind
        /// "Use on This Mac", "Use on Alex’s iPhone".
        public var title: String
        public var symbol: String
        public var id: String { if case .give(let link) = kind { return link.uuidString } else { return "here" } }
    }

    public enum Action: Hashable { case takeOverAnyway, stopWaiting, ok }

    case nothing
    /// At rest: the moves it can make.
    case moves([Move])
    /// Under way: the headline, what it waits for, and how to call it off.
    case line(headline: String, detail: String?, actions: [Action])
    /// It moved here.
    case done(headline: String)
    /// Needs the person: refused, or waiting through iCloud past its patience. The first action leads.
    case box(headline: String, detail: String?, actions: [Action])

    /// The handoff's rules. `targets` are the devices this one could hand it to; `thisDeviceSymbol` its own glyph.
    public static func make(state: RecorderHandoff.State, recorder: String, managedElsewhere: Bool, targets: [RecorderHandoff.Peer],
                            overdue: Bool, place: RecorderStatusWords.Place, thisDeviceSymbol: String, now: Date = Date()) -> Self {
        let headline = RecorderHandoff.Words.headline(state, recorder: recorder, here: place.here) ?? ""
        let detail = RecorderHandoff.Words.detail(state, recorder: recorder, here: place.here, overdue: overdue, now: now)
        switch state {
        case .idle:
            if managedElsewhere {
                return .moves([Move(kind: .here, title: "Use on \(place.hereTitle)", symbol: thisDeviceSymbol)])
            }
            let moves = targets.map { peer in
                Move(kind: .give(peer.linkID), title: "Use on \(peer.name)", symbol: SettingsWords.deviceSymbol(peer.deviceClass, name: peer.name))
            }
            return moves.isEmpty ? .nothing : .moves(moves)
        case .done:
            return .done(headline: headline)
        case .refused:
            return .box(headline: headline, detail: detail, actions: managedElsewhere ? [.ok, .takeOverAnyway] : [.ok])
        case .waitingForSync:
            return overdue ? .box(headline: headline, detail: detail, actions: [.takeOverAnyway, .stopWaiting])
                : .line(headline: headline, detail: detail, actions: [.takeOverAnyway, .stopWaiting])
        case .asking, .ownerFinishing, .offering:
            return .line(headline: headline, detail: detail, actions: [.stopWaiting])
        case .connecting, .handingOver:
            return .line(headline: headline, detail: detail, actions: [])
        }
    }

    /// The device a take-over waits on, for its confirmation: who has it, else "the other device".
    public static func owner(_ state: RecorderHandoff.State, managedBy: String?) -> String {
        switch state {
        case .waitingForSync(let owner, _), .asking(let owner), .ownerFinishing(let owner, _): return owner
        case .refused(let by, _): return by
        default: return managedBy ?? "the other device"
        }
    }
}

/// A recorder's handoff: on its page, in the column (`.page`); in the iPhone's status card, as the card's rows
/// (`.card`).
public struct RecorderHandoffView: View {
    public enum Style: Sendable { case page, card }

    private let session: DeviceSession
    private let style: Style
    @Environment(\.recorderServices) private var services
    @State private var confirmingTakeOver = false

    public init(session: DeviceSession, style: Style) {
        self.session = session
        self.style = style
    }

    /// Whether there's anything to show: a handoff under way or answered, or a move to offer.
    @MainActor
    public static func shows(_ session: DeviceSession, handoff: RecorderHandoff) -> Bool {
        guard session.direct is any ManagedConnection, session.recorderSerial != nil else { return false }
        return handoff.state(of: session) != .idle || session.managedElsewhere != nil || !handoff.peersToGive(session).isEmpty
    }

    public var body: some View {
        if let services, Self.shows(session, handoff: services.handoff) {
            let handoff = services.handoff
            let state = handoff.state(of: session)
            TimelineView(.periodic(from: .now, by: 15)) { context in
                let presentation = RecorderHandoffPresentation.make(
                    state: state, recorder: session.device.name, managedElsewhere: session.managedElsewhere != nil,
                    targets: handoff.peersToGive(session), overdue: handoff.isOverdue(state, now: context.date),
                    place: services.place, thisDeviceSymbol: services.thisDeviceSymbol, now: context.date)
                content(presentation, state: state, services: services)
            }
            .daybookMotion(DaybookMotion.fade, value: state)
            .confirmationDialog("Take over \(session.device.name) now?", isPresented: $confirmingTakeOver, titleVisibility: .visible) {
                Button("Take Over Anyway") { handoff.takeOverAnyway(session) }
                Button("Keep Waiting", role: .cancel) {}
            } message: {
                Text(RecorderHandoff.Words.takeOverRisk(owner: RecorderHandoffPresentation.owner(state, managedBy: session.managedElsewhere?.ownerName),
                                                        recorder: session.device.name, here: services.place.here))
            }
        }
    }

    @ViewBuilder
    private func content(_ presentation: RecorderHandoffPresentation, state: RecorderHandoff.State, services: RecorderServices) -> some View {
        switch presentation {
        case .nothing:
            EmptyView()
        case .moves(let moves):
            switch style {
            case .page:
                VStack(alignment: .leading, spacing: DaybookSpacing.s2) {
                    ForEach(moves) { move in
                        Button { perform(move, services: services) } label: {
                            HandoffLine(glyph: { Image(systemName: move.symbol) }) { Text(move.title).daybookFont(.body) }
                        }
                        .buttonStyle(.daybookLink)
                        .accessibilityHint(hint(move))
                    }
                }
                .padding(.top, DaybookSpacing.s4)
            case .card:
                ForEach(moves) { move in
                    if move.id != moves.first?.id { StatusDivider() }
                    Button { perform(move, services: services) } label: {
                        StatusRow {
                            Image(systemName: move.symbol).font(.body.weight(.medium)).foregroundStyle(DaybookPalette.Ink.link)
                                .accessibilityHidden(true)
                        } content: {
                            Text(move.title).font(.subheadline.weight(.medium)).foregroundStyle(DaybookPalette.Ink.link)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(hint(move))
                }
            }
        case .done(let headline):
            switch style {
            case .page:
                HandoffLine(glyph: { Image(systemName: "checkmark.circle") }) {
                    Text(headline).daybookFont(.status).foregroundStyle(DaybookPalette.Ink.secondary)
                }
                .foregroundStyle(DaybookPalette.Ink.secondary)
                .padding(.top, DaybookSpacing.s4)
            case .card:
                StatusRow {
                    Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.hierarchical)
                        .foregroundStyle(DaybookPalette.Ink.secondary).accessibilityHidden(true)
                } content: {
                    Text(headline).font(.subheadline).foregroundStyle(DaybookPalette.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .line(let headline, let detail, let actions):
            // Handing over after an import, the import's own progress on the page says what's left.
            let showsDetail = style == .card || !(isHandingOver(state) && session.queue.isActive)
            switch style {
            case .page:
                HandoffLine(glyph: { ProgressView().controlSize(.mini) }) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(headline).daybookFont(.statusLead).foregroundStyle(DaybookPalette.Ink.body)
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail, showsDetail {
                            Text(detail).daybookFont(.status).foregroundStyle(DaybookPalette.Ink.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !actions.isEmpty { actionLinks(actions).padding(.top, 2) }
                    }
                }
                .padding(.top, DaybookSpacing.s4)
            case .card:
                StatusRow(alignment: .top) {
                    ProgressView().controlSize(.small).frame(height: 20).accessibilityHidden(true)
                } content: {
                    VStack(alignment: .leading, spacing: DaybookSpacing.s1) {
                        Text(headline).font(.subheadline).foregroundStyle(DaybookPalette.Ink.title)
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail {
                            Text(detail).font(.footnote).foregroundStyle(DaybookPalette.Ink.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !actions.isEmpty { actionLinks(actions).font(.footnote).padding(.top, 2) }
                    }
                }
            }
        case .box(let headline, let detail, let actions):
            switch style {
            case .page:
                AttentionBox(kind: .problem, title: headline, message: detail) {
                    ForEach(Array(actions.dropFirst().reversed()), id: \.self) { action in
                        Button(title(action)) { perform(action, services: services) }.buttonStyle(.daybookLink)
                    }
                    if let first = actions.first {
                        Button(title(first)) { perform(first, services: services) }.buttonStyle(.daybookProminent)
                    }
                }
                .padding(.top, DaybookSpacing.s4)
            case .card:
                StatusRow(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.body).foregroundStyle(DaybookPalette.Ink.warning)
                        .frame(height: 20).accessibilityHidden(true)
                } content: {
                    VStack(alignment: .leading, spacing: DaybookSpacing.s1) {
                        Text(headline).font(.subheadline.weight(.semibold)).foregroundStyle(DaybookPalette.Ink.warning)
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail {
                            Text(detail).font(.footnote).foregroundStyle(DaybookPalette.Ink.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        actionLinks(actions).font(.footnote.weight(.semibold)).padding(.top, 2)
                    }
                }
            }
        }
    }

    private func actionLinks(_ actions: [RecorderHandoffPresentation.Action]) -> some View {
        HStack(spacing: DaybookSpacing.s4) {
            ForEach(actions, id: \.self) { action in
                if let services { Button(title(action)) { perform(action, services: services) } }
            }
        }
        .buttonStyle(.daybookLink)
        .daybookFont(.status)
    }

    private func title(_ action: RecorderHandoffPresentation.Action) -> String {
        switch action {
        case .takeOverAnyway: return "Take Over Anyway…"
        case .stopWaiting: return "Stop Waiting"
        case .ok: return "OK"
        }
    }

    private func perform(_ action: RecorderHandoffPresentation.Action, services: RecorderServices) {
        switch action {
        case .takeOverAnyway: confirmingTakeOver = true
        case .stopWaiting: services.handoff.cancel(session)
        case .ok: services.handoff.dismiss(session)
        }
    }

    private func perform(_ move: RecorderHandoffPresentation.Move, services: RecorderServices) {
        switch move.kind {
        case .here: services.handoff.useHere(session)
        case .give(let link):
            if let peer = services.handoff.peersToGive(session).first(where: { $0.linkID == link }) { services.handoff.give(session, to: peer) }
        }
    }

    private func hint(_ move: RecorderHandoffPresentation.Move) -> String {
        switch move.kind {
        case .here: return "Asks \(session.managedElsewhere?.ownerName ?? "the other device") to let go, then connects here"
        case .give: return "\(services?.place.hereTitle ?? "This device") finishes any import first"
        }
    }

    private func isHandingOver(_ state: RecorderHandoff.State) -> Bool {
        if case .handingOver = state { return true } else { return false }
    }
}

/// A handoff line on the page: its glyph in a fixed column (a box's width), so a detail under it starts where its
/// words do.
private struct HandoffLine<Glyph: View, Content: View>: View {
    @ViewBuilder var glyph: Glyph
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DaybookSpacing.s2) {
            glyph.frame(width: 18).accessibilityHidden(true)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }
}
