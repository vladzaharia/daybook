import DaybookDesign
import DaybookKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

// The small parts of Settings › Models on both apps: a model's label chip, the preset radio, and the model picker (a
// pop-up on the Mac, a menu on the iPhone, each item the model with its state under it).

/// A fact about a model in a quiet capsule: "Non-commercial", "Added by you", "Recommended".
public struct ModelLabelChip: View {
    private let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View { DaybookChip(text, kind: .fact) }
}

/// The radio Settings and Welcome draw for Quick, Balanced, and Detailed.
public struct PresetRadio: View {
    private let isOn: Bool
    public init(isOn: Bool) { self.isOn = isOn }

    public var body: some View {
        ZStack {
            Circle().fill(isOn ? DaybookPalette.prominentFill : Self.control)
            if isOn {
                Circle().fill(.white).frame(width: 6, height: 6)
            } else {
                Circle().strokeBorder(Self.rim, lineWidth: 1)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }

    #if os(macOS)
    private static let control = Color(nsColor: .controlColor)
    private static let rim = Color(nsColor: .tertiaryLabelColor)
    #else
    private static let control = Color(uiColor: .secondarySystemGroupedBackground)
    private static let rim = Color(uiColor: .tertiaryLabel)
    #endif
}

/// Chooses a role's model: on the Mac a pop-up whose items carry their state underneath ("Downloaded", "1.6 GB",
/// "Needs a newer Daybook"); on the iPhone the model's name as a menu with the same items. Models that can't run here
/// are listed last, disabled. With one model there's nothing to choose: just its name.
public struct ModelPicker: View {
    private let options: [ModelOption]
    private let selection: String?
    private let name: String
    private let title: String
    private let select: (String) -> Void

    /// - Parameters:
    ///   - name: The chosen model's name, which the iPhone's menu shows.
    ///   - title: What VoiceOver calls it: "Transcription model".
    public init(options: [ModelOption], selection: String?, name: String, title: String, select: @escaping (String) -> Void) {
        self.options = options
        self.selection = selection
        self.name = name
        self.title = title
        self.select = select
    }

    public var body: some View {
        #if os(macOS)
        ModelPopUpButton(options: options, selection: selection, title: title, select: select)
            .fixedSize()
        #else
        if options.count > 1 {
            Menu {
                Picker(title, selection: Binding(get: { selection ?? "" }, set: { if !$0.isEmpty { select($0) } })) {
                    Section {
                        ForEach(options.filter { $0.isEnabled || $0.key == selection }) { item($0) }
                    }
                    Section {
                        ForEach(options.filter { !$0.isEnabled && $0.key != selection }) { item($0).disabled(true) }
                    }
                }
            } label: {
                // The chevrons follow the name's last word, however it wraps: a no-break space keeps them together.
                Text("\(Text(name).foregroundStyle(DaybookPalette.Ink.title))\u{00A0}\(Self.chevrons)")
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityLabel(title)
            .accessibilityValue(name)
        } else {
            Text(name)
                .foregroundStyle(DaybookPalette.Ink.title)
                .fixedSize(horizontal: false, vertical: true)
        }
        #endif
    }

    #if os(iOS)
    private static var chevrons: Text {
        Text(Image(systemName: "chevron.up.chevron.down")).font(.footnote.weight(.semibold)).foregroundStyle(DaybookPalette.Ink.link)
    }

    private func item(_ option: ModelOption) -> some View {
        // A menu shows the first text as the item and the second under it.
        VStack(alignment: .leading) {
            Text(option.name)
            Text(option.detail)
        }
        .tag(option.key)
    }
    #endif
}

#if os(macOS)
/// A pop-up of models: each item's title is the model, its subtitle the state ("Downloaded", "1.6 GB", "Needs a newer
/// Daybook"); models that can't run here are listed last, disabled.
public struct ModelPopUpButton: NSViewRepresentable {
    let options: [ModelOption]
    let selection: String?
    let title: String
    let select: (String) -> Void
    @Environment(\.isEnabled) private var isEnabled

    public init(options: [ModelOption], selection: String?, title: String, select: @escaping (String) -> Void) {
        self.options = options
        self.selection = selection
        self.title = title
        self.select = select
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    public func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.select = select
        // Items are updated in place when the same models are listed, so an open menu isn't replaced while a
        // download's progress changes their state.
        let keys = options.map(\.key)
        if context.coordinator.keys == keys, let menu = button.menu {
            for item in menu.items {
                guard let key = item.representedObject as? String, let option = options.first(where: { $0.key == key }) else { continue }
                if item.title != option.name { item.title = option.name }
                if item.subtitle != option.detail { item.subtitle = option.detail }
                if item.isEnabled != option.isEnabled { item.isEnabled = option.isEnabled }
            }
        } else {
            let menu = NSMenu()
            menu.autoenablesItems = false
            var separated = false
            for option in options {
                if !option.isEnabled, !separated, option.key != selection, menu.items.contains(where: \.isEnabled) {
                    menu.addItem(.separator())
                    separated = true
                }
                let item = NSMenuItem(title: option.name, action: nil, keyEquivalent: "")
                item.subtitle = option.detail
                item.representedObject = option.key
                item.isEnabled = option.isEnabled
                menu.addItem(item)
            }
            button.menu = menu
            context.coordinator.keys = keys
        }
        button.isEnabled = isEnabled
        if let item = button.menu?.items.first(where: { ($0.representedObject as? String) == selection }), button.selectedItem !== item {
            button.select(item)
        }
        button.setAccessibilityLabel(title)
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    public final class Coordinator: NSObject {
        var select: (String) -> Void = { _ in }
        var keys: [String] = []
        @objc func changed(_ sender: NSPopUpButton) {
            if let key = sender.selectedItem?.representedObject as? String { select(key) }
        }
    }
}
#endif

/// Settings' label words as each platform draws them: sentence case on the Mac, title case on the iPhone
/// (`SettingsWords.titleCased`).
enum ModelSettingsText {
    static func label(_ text: String, _ density: DaybookDensity) -> String {
        density == .touch ? SettingsWords.titleCased(text) : text
    }
}
