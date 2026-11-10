import DaybookDesign
import SwiftUI

// After Stop, on both recorders (docs/interface.md, "After Stop"): Saved, the conversation and your notes, and what's
// becoming of it in the chips. Open takes Bookmark's place and Keep Recording, Record Again, or Record takes Stop's, by
// one rule (`RecordMore`). A recording that stopped short says so in a quiet warning box.

/// What the control in Stop's place does once a recording has ended: one rule on both apps (docs/interface.md, "After
/// Stop"). For two minutes after a Stop, or until something ends the moment sooner (another recording starts, the
/// call's meeting ends, the next meeting starts), Keep Recording records into the same conversation, after what was
/// saved, so a Stop pressed too soon doesn't split a meeting in two. After that, Record starts a new conversation, for
/// the next call. A recording that stopped on its own offers Record Again into the same conversation for as long as
/// it shows.
public enum RecordMore: Equatable, Sendable {
    /// Into the same conversation, within `window` of a Stop.
    case keepRecording
    /// Into the same conversation, after a recording that stopped on its own.
    case recordAgain
    /// A new conversation.
    case record

    /// How long after a Stop Keep Recording records into the same conversation.
    public static let window: TimeInterval = 2 * 60

    /// - Parameters:
    ///   - stoppedShort: The recording ended on its own: the microphone went, the Mac slept, storage couldn't keep up.
    ///   - stoppedAt: When it was stopped; nil when there's nothing to record into (it wasn't saved), or something
    ///     has ended the moment early.
    public init(stoppedShort: Bool, stoppedAt: Date?, now: Date = Date()) {
        if stoppedShort {
            self = .recordAgain
        } else if let stoppedAt, now.timeIntervalSince(stoppedAt) < Self.window {
            self = .keepRecording
        } else {
            self = .record
        }
    }

    /// When Keep Recording gives way to Record, after a Stop at `stoppedAt`.
    public static func windowEnds(after stoppedAt: Date) -> Date { stoppedAt.addingTimeInterval(window) }

    /// The control's words.
    public var title: String {
        switch self {
        case .keepRecording: return "Keep Recording"
        case .recordAgain: return "Record Again"
        case .record: return "Record"
        }
    }

    /// It records into the conversation that ended, after what was saved; Record makes a new one.
    public var recordsIntoSameConversation: Bool { self != .record }
}

/// A state after Stop that needs the person: one box, with at most one action of its own.
public struct RecorderProblem {
    public var title: String
    public var message: String?
    /// The system's own words, in the tooltip (the Mac).
    public var help: String?
    public var actionTitle: String?
    public var actionEnabled: Bool
    public var action: (() -> Void)?

    public init(title: String, message: String? = nil, help: String? = nil, actionTitle: String? = nil, actionEnabled: Bool = true,
                action: (() -> Void)? = nil) {
        self.title = title; self.message = message; self.help = help; self.actionTitle = actionTitle
        self.actionEnabled = actionEnabled; self.action = action
    }
}

/// What the recorder shows after Stop.
public struct RecorderAfterStopState {
    /// "✓ SAVED · 18 min", drawn in the surface; nil when the host draws it.
    public var phase: RecorderPhase?
    public var title: String
    public var rename: ((String) -> Void)?
    public var chips: [RecorderChip]
    /// When it was (and how long, when the band doesn't say).
    public var meta: String?
    public var problem: RecorderProblem?
    /// "Open", or "Open Summary" once there is one.
    public var openTitle: String
    /// There's a conversation to open (it's in the library).
    public var canOpen: Bool
    /// What the control in Stop's place does (`RecordMore`).
    public var recordMore: RecordMore
    public var canRecord: Bool
    public var isStartingRecording: Bool
    public var topInset: CGFloat
    public var keyboardShortcuts: Bool

    public init(phase: RecorderPhase? = nil, title: String, rename: ((String) -> Void)? = nil, chips: [RecorderChip] = [], meta: String? = nil,
                problem: RecorderProblem? = nil, openTitle: String = "Open", canOpen: Bool = true, recordMore: RecordMore = .record,
                canRecord: Bool = true, isStartingRecording: Bool = false, topInset: CGFloat = 0, keyboardShortcuts: Bool = false) {
        self.phase = phase; self.title = title; self.rename = rename; self.chips = chips; self.meta = meta; self.problem = problem
        self.openTitle = openTitle; self.canOpen = canOpen; self.recordMore = recordMore; self.canRecord = canRecord
        self.isStartingRecording = isStartingRecording; self.topInset = topInset; self.keyboardShortcuts = keyboardShortcuts
    }
}

/// What the controls after Stop do.
public struct RecorderAfterStopActions {
    public var open: () -> Void
    public var record: () -> Void
    /// A link at the end of the meta line ("Recent", back to the panel's home).
    public var metaLink: (title: String, help: String, action: () -> Void)?

    public init(open: @escaping () -> Void, record: @escaping () -> Void, metaLink: (title: String, help: String, action: () -> Void)? = nil) {
        self.open = open; self.record = record; self.metaLink = metaLink
    }
}

/// The recorder after Stop.
public struct RecorderAfterStop: View {
    private let state: RecorderAfterStopState
    private let actions: RecorderAfterStopActions
    private let notes: AnyView
    private let menu: (RecorderChip) -> AnyView
    @Environment(\.surfaceLayout) private var layout
    @Environment(\.daybookDensity) private var density

    public init(state: RecorderAfterStopState, actions: RecorderAfterStopActions, notes: AnyView,
                menu: @escaping (RecorderChip) -> AnyView = { _ in AnyView(EmptyView()) }) {
        self.state = state
        self.actions = actions
        self.notes = notes
        self.menu = menu
    }

    private var touch: Bool { density == .touch }
    private var compact: Bool { layout == .compact }
    private var inset: CGFloat { touch ? RecorderInsets.touch : RecorderInsets.panel }
    private var metrics: RecorderControlMetrics { compact ? .panelCompact : touch ? .pocket : .panel }

    public var body: some View {
        if case .spread(let crease) = layout {
            PageSpread(crease: crease) {
                VStack(alignment: .leading, spacing: 0) {
                    header.padding(.horizontal, DaybookSpacing.s6).padding(.top, DaybookSpacing.s5).padding(.bottom, DaybookSpacing.s2)
                    notes.padding(.leading, DaybookSpacing.s3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } trailing: {
                VStack(alignment: .leading, spacing: DaybookSpacing.s4) {
                    problem
                    Spacer(minLength: 0)
                    controls
                }
                .padding(DaybookSpacing.s5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } single: {
                column
            }
        } else {
            column
        }
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, inset)
                .padding(.top, touch ? DaybookSpacing.s3 : state.topInset + (state.chips.isEmpty ? 4 : 10))
                .padding(.bottom, compact ? 4 : 12)
            problem
                .padding(.horizontal, inset)
                .padding(.bottom, state.problem == nil ? 0 : 12)
            if compact {
                Spacer(minLength: 0)
            } else {
                RecorderRule().padding(.horizontal, inset).opacity(touch ? 0.6 : 1)
                notes.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if touch {
                controls
                    .padding(.horizontal, DaybookSpacing.s4)
                    .padding(.top, DaybookSpacing.s2)
                    .padding(.bottom, DaybookSpacing.s3)
            } else {
                PanelControlPadding(compact: compact) { controls }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: touch ? 6 : 3) {
            if let phase = state.phase {
                RecordingPhaseLabel(phase.phase, title: phase.title, detail: phase.detail, detailIsWarning: phase.detailIsWarning)
                    .padding(.bottom, 4)
            }
            if !state.chips.isEmpty {
                // Spacing plus this: the same gap to the title as while recording.
                RecorderChipRow(chips: state.chips) { menu($0) }.padding(.bottom, touch ? 4 : 9)
            }
            RecorderTitle(state.title, rename: state.rename)
            if state.meta != nil || actions.metaLink != nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let meta = state.meta {
                        Text(meta)
                            .foregroundStyle(DaybookPalette.Ink.secondary)
                            .monospacedDigit()
                            .lineLimit(touch ? 2 : 1)
                    }
                    Spacer(minLength: 4)
                    if let link = actions.metaLink {
                        Button(link.title, action: link.action)
                            .buttonStyle(.daybookLink)
                            .help(link.help)
                    }
                }
                .font(touch ? .subheadline : .system(size: 12))
            }
        }
    }

    @ViewBuilder private var problem: some View {
        if let problem = state.problem {
            let message = compact ? nil : problem.message
            Group {
                if let title = problem.actionTitle, let action = problem.action {
                    AttentionBox(title: problem.title, message: message, compact: true) {
                        Button(title, action: action)
                            .buttonStyle(.daybookLink)
                            .font(touch ? .subheadline.weight(.semibold) : .system(size: 12, weight: .medium))
                            .disabled(!problem.actionEnabled)
                    }
                } else {
                    AttentionBox(title: problem.title, message: message, compact: true)
                }
            }
            .help(problem.help ?? "")
        }
    }

    private var controls: some View {
        RecorderControlRow(spacing: metrics.spacing) {
            Button(action: actions.open) {
                OpenControlLabel(title: state.openTitle, size: metrics.size)
                    .frame(maxWidth: .infinity, minHeight: metrics.height)
                    .contentShape(Rectangle())
            }
            .daybookControl(.standard, shape: .roundedRectangle(radius: metrics.radius))
            .disabled(!state.canOpen)
            // ⌘O is the panel's own, whatever it shows; here it's only said.
            .help(state.keyboardShortcuts ? "Open in Daybook (⌘O)" : "")
            .accessibilityShowsLargeContentViewer { Label(state.openTitle, systemImage: "arrow.up.forward") }
        } trailing: {
            Button(action: actions.record) {
                Group {
                    if let size = metrics.size {
                        RecordControlLabel(title: state.isStartingRecording ? "Starting…" : state.recordMore.title, size: size)
                    } else {
                        // Under touch the words keep one line, a little smaller if they must; at the accessibility
                        // sizes they wrap rather than cut ("Keep Recording").
                        HStack(spacing: 8) {
                            Circle().fill(DaybookPalette.Ink.record).frame(width: 12, height: 12)
                                .daybookGlow(DaybookPalette.Ink.record, radius: 3)
                            TouchControlWords(state.isStartingRecording ? "Starting…" : state.recordMore.title)
                        }
                        .font(.headline)
                        .foregroundStyle(DaybookPalette.Ink.title)
                        .padding(.vertical, 6)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: metrics.height)
                .contentShape(Rectangle())
            }
            .daybookControl(.standard, shape: .roundedRectangle(radius: metrics.radius))
            .disabled(!state.canRecord || state.isStartingRecording)
            .modifier(RecorderShortcut(enabled: state.keyboardShortcuts, key: "r", modifiers: [.command, .shift], help: "Start Recording (⇧⌘R)"))
            .accessibilityShowsLargeContentViewer { Label(state.recordMore.title, systemImage: "record.circle") }
        }
    }
}

/// Open: the link teal and the arrow out of the recorder. Under touch the words wrap rather than cut.
public struct OpenControlLabel: View {
    private let title: String
    private let size: CGFloat?

    public init(title: String, size: CGFloat? = nil) {
        self.title = title
        self.size = size
    }

    public var body: some View {
        HStack(spacing: 6) {
            if size == nil {
                TouchControlWords(title)
            } else {
                Text(title).lineLimit(1)
            }
            Image(systemName: "arrow.up.forward").font(size.map { .system(size: $0 * 0.75, weight: .semibold) } ?? .subheadline.weight(.semibold))
        }
        .font(size.map { .system(size: $0, weight: .semibold) } ?? .headline)
        .foregroundStyle(DaybookPalette.Ink.link)
        .padding(.vertical, size == nil ? 6 : 0)
    }
}

/// A large control's words under touch: one line (a little smaller if the tile is narrow), wrapping at the
/// accessibility sizes rather than cutting.
struct TouchControlWords: View {
    private let words: String
    @Environment(\.dynamicTypeSize) private var typeSize

    init(_ words: String) { self.words = words }

    var body: some View {
        if typeSize.isAccessibilitySize {
            Text(words)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(words).lineLimit(1).minimumScaleFactor(0.8)
        }
    }
}
