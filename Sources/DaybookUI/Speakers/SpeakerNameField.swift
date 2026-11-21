import DaybookCore
import DaybookDesign
import DaybookKit
import SwiftUI

/// A speaker's name field with the library's profiles listed under it (`SpeakerNameChoices`). Picking a row names the
/// speaker that profile's name, which attaches it the way naming it by hand does; Return on free text keeps that text.
/// While the name is still the speaker's current one the whole list shows; typing filters it. ↑ and ↓ move the
/// highlight, Return takes it. The list shows while the field has focus.
struct SpeakerNameField<Field: View>: View {
    let current: String
    @Binding var draft: String
    let isFocused: Bool
    let profiles: [SpeakerProfile]
    let me: UUID?
    /// Names the speaker: a picked row's name, or the typed text.
    let commit: (String) -> Void
    /// Draws a glyph at the head of each row (the phone's sheet).
    var showsGlyphs = false
    @ViewBuilder var field: Field
    @State private var highlighted: String?
    @Environment(\.daybookDensity) private var density

    private var touch: Bool { density == .touch }
    private var rows: [SpeakerNameChoice] {
        SpeakerNameChoices.rows(profiles: profiles, me: me, query: draft == current ? "" : draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            field
            if isFocused {
                let rows = rows
                if !rows.isEmpty {
                    let height = CGFloat(min(rows.count, 6)) * (touch ? 44 : 26)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) { ForEach(rows) { row in choiceButton(row) } }
                    }
                    .frame(height: height)
                }
            }
        }
        .onChange(of: draft) { _, _ in highlighted = nil }
        .onSubmit {
            if let row = rows.first(where: { $0.id == highlighted }) { commit(row.name) } else { commit(draft) }
        }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-1) }
    }

    private func choiceButton(_ row: SpeakerNameChoice) -> some View {
        Button { commit(row.name) } label: {
            HStack(spacing: 6) {
                if showsGlyphs {
                    Image(systemName: row.kind == .add ? "plus.circle" : "person.crop.circle")
                        .foregroundStyle(row.kind == .add ? DaybookPalette.Ink.link : DaybookPalette.Ink.secondary)
                        .frame(width: 24)
                }
                Text(row.kind == .add ? "Add “\(row.name)”" : row.name).lineLimit(1)
                if row.isMe { Text(SpeakerProfileWords.you).foregroundStyle(DaybookPalette.Ink.secondary) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(minHeight: touch ? 44 : 26)
            .background(row.id == highlighted ? DaybookPalette.accentWash : Color.clear, in: DaybookRadius.shape(DaybookRadius.row))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.isMe ? "\(row.name), \(SpeakerProfileWords.you)" : (row.kind == .add ? "Add “\(row.name)”" : row.name))
    }

    private func move(_ step: Int) -> KeyPress.Result {
        guard isFocused else { return .ignored }
        let rows = rows
        guard !rows.isEmpty else { return .ignored }
        let at = rows.firstIndex { $0.id == highlighted }
        let next = at.map { min(max($0 + step, 0), rows.count - 1) } ?? (step > 0 ? 0 : rows.count - 1)
        highlighted = rows[next].id
        return .handled
    }
}

#if DEBUG
/// Debug only, for screenshots: `--focus-speaker-name` focuses the first person's name in Info › People,
/// `--rename-speaker` opens the transcript's Rename Speaker at its first turn, and `--speaker-name-draft <text>`
/// types a name into either.
enum SpeakerNamePickerDemo {
    static var focusesInfo: Bool { CommandLine.arguments.contains("--focus-speaker-name") }
    static var marksFirstAsMe: Bool { CommandLine.arguments.contains("--speaker-name-me") }
    static var opensRename: Bool { CommandLine.arguments.contains("--rename-speaker") }
    static var draft: String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--speaker-name-draft"), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
#endif
