import DaybookDesign
import DaybookKit
import SwiftUI

// Settings › Models' rows, the same on both apps: a role's model, a model in the library, the row that downloads what's
// chosen, and a quality preset. Each speaks only when something isn't ready; a download fills the brand gradient, and
// one that finishes turns into a checkmark for a moment (`DaybookMotion.hold`), with the success haptic on the iPhone.

/// What a role's row can do: choose a model, download it, and cancel its download.
public struct ModelRowActions {
    public var select: (String) -> Void
    public var download: (String) -> Void
    public var cancel: (String) -> Void

    public init(select: @escaping (String) -> Void, download: @escaping (String) -> Void, cancel: @escaping (String) -> Void) {
        self.select = select; self.download = download; self.cancel = cancel
    }
}

/// One role's model. In a window: the label with the chosen model's state under it, then what to do and the pop-up,
/// in one row. Under touch, or where that doesn't fit: the model's name is the menu, its state under it, and what to
/// do beside it.
public struct ModelRoleRow: View {
    private let label: String?
    private let choice: ModelRoleChoice
    private let space: ModelSpace
    private let pickerTitle: String
    private let actions: ModelRowActions
    @Environment(\.daybookDensity) private var density
    @Environment(\.dynamicTypeSize) private var typeSize
    private var stack: AnyLayout { ModelRowStack.layout(typeSize) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var justDownloaded = false
    @State private var downloads = 0

    /// - Parameters:
    ///   - label: What the row is ("Model", "Voice profiles"); nil where the section already says it.
    ///   - pickerTitle: What VoiceOver calls its pop-up or menu: the role's ("Transcription model"), unless the row is
    ///     another choice for the role ("Other languages model").
    public init(label: String?, choice: ModelRoleChoice, space: ModelSpace = .unknown, pickerTitle: String? = nil,
                actions: ModelRowActions) {
        self.label = label
        self.choice = choice
        self.space = space
        self.pickerTitle = pickerTitle ?? "\(choice.title) model"
        self.actions = actions
    }

    public var body: some View {
        Group {
            if density == .touch {
                compact
            } else {
                ViewThatFits(in: .horizontal) {
                    wide
                    compact
                }
            }
        }
        .onChange(of: choice.standing) { old, new in
            guard ModelRoleChoice.finishedDownloading(from: old, to: new) else { return }
            withAnimation(DaybookMotion.resolved(DaybookMotion.land, reduceMotion: reduceMotion)) { justDownloaded = true }
            downloads += 1
        }
        .task(id: justDownloaded) {
            guard justDownloaded else { return }
            try? await Task.sleep(for: DaybookMotion.hold)
            withAnimation(DaybookMotion.resolved(DaybookMotion.fade, reduceMotion: reduceMotion)) { justDownloaded = false }
        }
        #if os(iOS)
        .sensoryFeedback(.success, trigger: downloads)
        #endif
    }

    private var wide: some View {
        HStack(alignment: .center, spacing: DaybookSpacing.s2) {
            VStack(alignment: .leading, spacing: 2) {
                if let label { Text(label) }
                status(barWidth: 160)
            }
            .layoutPriority(1)
            Spacer(minLength: DaybookSpacing.s2)
            action
            picker
        }
    }

    private var compact: some View {
        stack {
            VStack(alignment: .leading, spacing: 2) {
                if let label, density != .touch { Text(label).font(lineFont).foregroundStyle(.secondary) }
                picker
                status(barWidth: nil)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            action
        }
    }

    private var picker: some View {
        ModelPicker(options: choice.options, selection: choice.selection, name: choice.selectionName,
                    title: pickerTitle, select: actions.select)
    }

    private var lineFont: Font { density == .touch ? .footnote : .subheadline }

    /// The state under the label or name, the bar while it downloads, and the checkmark once it's done.
    @ViewBuilder private func status(barWidth: CGFloat?) -> some View {
        if justDownloaded {
            ModelDoneLine(font: lineFont)
        } else if let line = choice.line(space: space) {
            Text(line.text)
                .font(lineFont)
                .foregroundStyle(line.needsAttention ? DaybookPalette.Ink.warning : Color.secondary)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
        if !justDownloaded, case .downloading(let fraction)? = choice.status {
            ProgressView(value: fraction)
                .progressViewStyle(.brand(width: barWidth))
                .padding(.top, 2)
                .accessibilityLabel("Downloading \(choice.selectionName)")
        }
    }

    @ViewBuilder private var action: some View {
        if let key = choice.selectedModel?.key, let status = choice.status {
            if status.isTransferring {
                ModelActionButton("Cancel") { actions.cancel(key) }
            } else if status.canDownload {
                ModelActionButton("Download") { actions.download(key) }
                    .disabled(!choice.canDownload(space: space))
            }
        }
    }
}

/// A row's words and what it offers side by side; at the accessibility text sizes the actions go under the words, which
/// beside them would be left a letter a line.
enum ModelRowStack {
    static func layout(_ typeSize: DynamicTypeSize) -> AnyLayout {
        typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: DaybookSpacing.s2))
            : AnyLayout(HStackLayout(alignment: .center, spacing: DaybookSpacing.s3))
    }
}

/// "✓ Downloaded", for a moment after a download finishes, where its bar was.
struct ModelDoneLine: View {
    let font: Font

    var body: some View {
        HStack(spacing: 4) {
            DoneMark()
            Text("Downloaded").foregroundStyle(.secondary)
        }
        .font(font)
        .accessibilityElement(children: .combine)
    }
}

/// Download and Cancel: one style wherever a model row offers them.
struct ModelActionButton: View {
    private let title: String
    private let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .fixedSize()
    }
}

/// One model in the library: its name and labels, then its maker, size, and state, and what can be done with it. While
/// it downloads, the bar fills before the actions; when it's done, a checkmark stands there for a moment.
public struct ModelListRow<Actions: View>: View {
    private let name: String
    private let labels: [String]
    private let detail: String
    private let status: ModelStatus
    private let note: ModelLine?
    private let actions: Actions
    @Environment(\.daybookDensity) private var density
    @Environment(\.dynamicTypeSize) private var typeSize
    private var stack: AnyLayout { ModelRowStack.layout(typeSize) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var justDownloaded = false
    @State private var downloads = 0

    /// - Parameters:
    ///   - detail: The maker and size: "OpenAI · 487 MB".
    ///   - note: Said in place of the state: why Download waits ("Needs 632 MB · 300 MB free").
    public init(name: String, labels: [String], detail: String, status: ModelStatus, note: ModelLine? = nil,
                @ViewBuilder actions: () -> Actions) {
        self.name = name
        self.labels = labels
        self.detail = detail
        self.status = status
        self.note = note
        self.actions = actions()
    }

    public var body: some View {
        stack {
            VStack(alignment: .leading, spacing: 3) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { title; chips }
                    VStack(alignment: .leading, spacing: 3) { title; HStack(spacing: 6) { chips } }
                }
                statusLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if justDownloaded {
                DoneMark().daybookTransition(.opacity)
            } else if case .downloading(let fraction) = status {
                ProgressView(value: fraction)
                    .progressViewStyle(.brand(width: 72))
                    .accessibilityLabel("Downloading \(name)")
            }
            // What it offers once it's here (Use, or nothing for one in use) arrives rather than snaps in.
            actions
                .id(status.isReady)
                .daybookTransition(.opacity.combined(with: .scale(scale: 0.9)))
        }
        .animation(DaybookMotion.resolved(DaybookMotion.state, reduceMotion: reduceMotion), value: status.isReady)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .onChange(of: status) { old, new in
            guard ModelStatus.finishedDownloading(from: old, to: new) else { return }
            withAnimation(DaybookMotion.resolved(DaybookMotion.land, reduceMotion: reduceMotion)) { justDownloaded = true }
            downloads += 1
        }
        .task(id: justDownloaded) {
            guard justDownloaded else { return }
            try? await Task.sleep(for: DaybookMotion.hold)
            withAnimation(DaybookMotion.resolved(DaybookMotion.fade, reduceMotion: reduceMotion)) { justDownloaded = false }
        }
        #if os(iOS)
        .sensoryFeedback(.success, trigger: downloads)
        #endif
    }

    private var title: some View {
        Text(name)
            .foregroundStyle(density == .touch ? DaybookPalette.Ink.title : Color.primary)
            .lineLimit(density == .touch ? nil : 1)
            .truncationMode(.tail)
    }

    private var chips: some View {
        ForEach(labels, id: \.self) { ModelLabelChip($0) }
    }

    private var statusLine: some View {
        HStack(spacing: 0) {
            if !detail.isEmpty { Text(detail + " · ").foregroundStyle(.secondary) }
            if let note {
                Text(note.text)
                    .foregroundStyle(note.needsAttention ? DaybookPalette.Ink.warning : Color.secondary)
                    .monospacedDigit()
            } else {
                if status == .inUse {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DaybookPalette.Ink.link)
                        .imageScale(.small)
                        .padding(.trailing, 3)
                        .accessibilityHidden(true)
                }
                Text(status.label)
                    .foregroundStyle(statusColor)
                    .monospacedDigit()
            }
        }
        .font(density == .touch ? .footnote : .subheadline)
        .lineLimit(density == .touch ? 2 : 1)
    }

    /// "In use" and "Update available" in the link's teal, because you can act on them; what needs you in the warning ink.
    private var statusColor: Color {
        switch status {
        case .inUse, .updateAvailable: return DaybookPalette.Ink.link
        default: return status.needsAttention ? DaybookPalette.Ink.warning : Color.secondary
        }
    }
}

/// Downloads what a section's choices still need: "Not downloaded yet · 852 MB" with Download, then the bar with what's
/// arrived and Cancel. Where there isn't room, it says how much is needed and Download waits.
public struct ModelDownloadRow: View {
    private let summary: ModelDownloadSummary
    private let space: ModelSpace
    private let download: () -> Void
    private let cancel: () -> Void
    @Environment(\.daybookDensity) private var density
    @Environment(\.dynamicTypeSize) private var typeSize
    private var stack: AnyLayout { ModelRowStack.layout(typeSize) }

    public init(_ summary: ModelDownloadSummary, space: ModelSpace = .unknown, download: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.summary = summary
        self.space = space
        self.download = download
        self.cancel = cancel
    }

    public var body: some View {
        let line = summary.line(space: space)
        stack {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title)
                Text(line.text)
                    .font(density == .touch ? .footnote : .subheadline)
                    .foregroundStyle(line.needsAttention ? DaybookPalette.Ink.warning : Color.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                if case .downloading = summary {
                    ProgressView(value: summary.fraction)
                        .progressViewStyle(.brand(width: nil))
                        .padding(.top, 2)
                        .accessibilityLabel("Downloading models")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            switch summary {
            case .missing:
                ModelActionButton("Download", action: download)
                    .disabled(!summary.canDownload(space: space))
            case .downloading:
                ModelActionButton("Cancel", action: cancel)
            }
        }
    }
}

/// Quick, Balanced, or Detailed: its models (two lines, the ones that set it apart first), what it downloads, and the
/// memory it wants, with this device's recommendation marked. Custom is what the choices below add up to, so it isn't
/// a button. `note` says when its download wouldn't fit.
public struct ModelQualityRow: View {
    private let option: ModelQualityOption
    private let note: ModelLine?
    private let choose: () -> Void
    @Environment(\.daybookDensity) private var density

    public init(_ option: ModelQualityOption, note: ModelLine? = nil, choose: @escaping () -> Void) {
        self.option = option
        self.note = note
        self.choose = choose
    }

    public var body: some View {
        if option.isCustom {
            content
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isSelected)
        } else {
            Button(action: choose) { content.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(option.isCurrent ? [.isSelected, .isButton] : .isButton)
                .accessibilityHint(option.isRecommended ? "Recommended for this device" : "")
        }
    }

    private var lineFont: Font { density == .touch ? .footnote : .subheadline }

    private var content: some View {
        HStack(alignment: .center, spacing: DaybookSpacing.s3) {
            PresetRadio(isOn: option.isCurrent)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(option.title).foregroundStyle(.primary)
                    if option.isRecommended { ModelLabelChip(ModelLabels.recommended) }
                }
                Text(option.names.joined(separator: ", "))
                    .font(lineFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    Text(note.text)
                        .font(lineFont)
                        .foregroundStyle(note.needsAttention ? DaybookPalette.Ink.warning : Color.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: DaybookSpacing.s2)
            VStack(alignment: .trailing, spacing: 2) {
                Text(ByteSize.format(option.bytes)).monospacedDigit()
                Text(option.memory).font(lineFont).foregroundStyle(.secondary)
            }
            .fixedSize()
        }
    }
}
