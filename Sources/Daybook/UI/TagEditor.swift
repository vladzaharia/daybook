import SwiftUI

/// Tags as removable chips followed by a field for adding another.
struct TagEditor: View {
    let tags: [String]
    let save: ([String]) -> Void
    var showTag: ((String) -> Void)?
    var alignment: HorizontalAlignment = .leading
    @State private var draft = ""
    @FocusState private var focused: Bool
    var body: some View {
        FlowLayout(spacing: 4, alignment: alignment) {
            ForEach(tags, id: \.self) { tag in
                TagChip(tag: tag, remove: { save(tags.filter { $0 != tag }) }, show: showTag.map { show in { show(tag) } })
            }
            TextField("Tag", text: $draft, prompt: Text("Add Tag…"))
                .textFieldStyle(.plain).font(.system(size: 12)).frame(width: 80)
                .labelsHidden()
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, active in if !active { commit() } }
        }
    }
    private func commit() {
        let tag = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        guard !tag.isEmpty else { return }
        save(tags + [tag])
    }
}

private struct TagChip: View {
    let tag: String
    let remove: () -> Void
    let show: (() -> Void)?
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 2) {
            Text(tag)
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
                .accessibilityLabel("Remove tag \(tag)")
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Ink.link)
        .padding(.leading, 7).padding(.trailing, 5).padding(.vertical, 2)
        .background(DaybookStyle.accent.opacity(0.14), in: Capsule())
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .onTapGesture { show?() }
        .contextMenu {
            if let show { Button("Show Conversations Tagged “\(tag)”", action: show) }
            Button("Remove Tag", action: remove)
        }
    }
}
