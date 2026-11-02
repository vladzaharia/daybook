import DaybookDesign
import DaybookKit
import SwiftUI

/// Tags as chips, then a field for more, on both apps (Info's Tags). Typing takes the tags the way both apps do
/// (`TagInput`: "client, beta" is two). A chip shows the conversations with its tag; its × removes it: on the Mac it
/// appears over the chip's corner while the pointer is on the chip, so the chip never changes size; under touch it's
/// always there, with a 44 pt target that never lays out narrower than its glyph.
public struct TagEditor: View {
    let tags: [String]
    let save: ([String]) -> Void
    let show: ((String) -> Void)?
    @State private var draft = ""
    /// The width of what the field shows, under touch.
    @State private var typedWidth: CGFloat = 0
    /// Add Tag… asked for the tag in an alert (the largest text sizes).
    @State private var adding = false
    @FocusState private var focused: Bool
    @Environment(\.daybookDensity) private var density
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(tags: [String], save: @escaping ([String]) -> Void, show: ((String) -> Void)? = nil) {
        self.tags = tags
        self.save = save
        self.show = show
    }

    public var body: some View {
        let touch = density == .touch
        FlowLayout(spacing: touch ? 6 : 4, lineSpacing: touch ? 6 : 4) {
            ForEach(tags, id: \.self) { tag in
                TagChip(tag: tag, remove: { save(tags.filter { $0 != tag }) }, show: show.map { show in { show(tag) } })
            }
            field
        }
    }

    @ViewBuilder private var field: some View {
        #if os(iOS)
        if dynamicTypeSize.isAccessibilitySize {
            // At the largest sizes a field in a form keeps its words far from the chips and cuts them short, so Add
            // Tag… asks for the tag in an alert.
            Button("Add Tag…") { adding = true }
                .buttonStyle(.daybookLink)
                .font(.subheadline)
                .alert("Add Tag", isPresented: $adding) {
                    TextField("Tag", text: $draft)
                        .textInputAutocapitalization(.never)
                    Button("Add", action: commit)
                    Button("Cancel", role: .cancel) { draft = "" }
                }
        } else {
            // As wide as what it shows ("Add Tag…", or what's typed), never wider than the row.
            let width = max(90, typedWidth + 6)
            textField
                .font(.subheadline)
                .submitLabel(.done)
                .textInputAutocapitalization(.never)
                .frame(minWidth: 0, idealWidth: width, maxWidth: width, alignment: .leading)
                .background(alignment: .leading) {
                    Text(draft.isEmpty ? "Add Tag…" : draft).font(.subheadline).lineLimit(1).fixedSize().hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { typedWidth = $0 }
                }
        }
        #else
        textField
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .frame(minWidth: 80, alignment: .leading)
        #endif
    }

    private var textField: some View {
        TextField("Add Tag…", text: $draft)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, active in if !active { commit() } }
            .accessibilityLabel("Add Tag")
    }

    private func commit() {
        let next = TagInput.adding(draft, to: tags)
        draft = ""
        if next != tags { save(next) }
    }
}

/// One tag: link ink on the accent wash (`DaybookChip`'s tag colours), its name, and its ×.
private struct TagChip: View {
    let tag: String
    let remove: () -> Void
    let show: (() -> Void)?
    @State private var hovering = false
    @Environment(\.daybookDensity) private var density

    var body: some View {
        let colors = DaybookChip.colors(.tag)
        if density == .touch {
            HStack(spacing: 6) {
                name
                Button(action: remove) {
                    Image(systemName: "xmark").font(.caption2.weight(.bold))
                        .daybookHitTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove tag \(tag)")
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(colors.ink.color)
            .padding(.leading, 10).padding(.trailing, 8).padding(.vertical, 4)
            .background(colors.wash.color, in: DaybookRadius.chip)
        } else {
            name
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(colors.ink.color)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(colors.wash.color, in: DaybookRadius.chip)
                .contentShape(DaybookRadius.chip)
                // Over the corner, so showing it never moves the chip or its neighbours.
                .overlay(alignment: .topTrailing) {
                    if hovering {
                        Button(action: remove) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Color.white, DaybookPalette.Ink.secondary)
                                .frame(width: 14, height: 14)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .offset(x: 6, y: -6)
                        .transition(.opacity)
                        .accessibilityLabel("Remove tag \(tag)")
                    }
                }
                .zIndex(hovering ? 1 : 0)
                .onHover { inside in withAnimation(DaybookMotion.hover) { hovering = inside } }
                .contextMenu {
                    if let show { Button("Show Conversations Tagged “\(tag)”", action: show) }
                    Button("Remove Tag", action: remove)
                }
                .accessibilityAction(named: "Remove Tag", remove)
        }
    }

    @ViewBuilder private var name: some View {
        if let show {
            Button(action: show) { Text(tag).lineLimit(1) }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the conversations with this tag")
        } else {
            Text(tag).lineLimit(1)
        }
    }
}
