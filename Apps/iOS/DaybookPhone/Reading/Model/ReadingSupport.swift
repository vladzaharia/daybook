import DaybookKit
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Marks what changed between two versions word by word (`WordChanges`): removed words struck through
/// in magenta, inserted words washed in mint, over the text's own styling. The Mac's Version History
/// draws the same marks.
enum WordDiff {
    static func tokens(_ text: String) -> [Substring] { WordChanges.tokens(text) }
    static func changes(old: [Substring], new: [Substring]) -> (removed: IndexSet, inserted: IndexSet) { WordChanges.changes(old: old, new: new) }

    static func marked(old: String, new: String, dark: Bool = false) -> (old: AttributedString, new: AttributedString) {
        marked(old: AttributedString(old), new: AttributedString(new), dark: dark)
    }

    /// In dark mode the washes are stronger and an inserted word is itself neon mint.
    static func marked(old: AttributedString, new: AttributedString, dark: Bool = false) -> (old: AttributedString, new: AttributedString) {
        var removed = AttributeContainer(), inserted = AttributeContainer()
        removed.strikethroughStyle = Text.LineStyle(pattern: .solid, color: PhoneStyle.neonMagenta)
        removed.backgroundColor = PhoneStyle.neonMagenta.opacity(dark ? 0.20 : 0.16)
        inserted.backgroundColor = PhoneStyle.neonMint.opacity(dark ? 0.22 : 0.16)
        if dark { inserted.foregroundColor = PhoneStyle.neonMint }
        return WordChanges.marked(old: old, new: new, removed: removed, inserted: inserted)
    }
}

/// Words for a recording in Info › Audio, as the Mac's inspector says them from its side
/// (`RecordingWords`): its name, where it was made when the name doesn't say ("Your Mac"), and,
/// only when the conversation has several recordings, how it lines up.
@MainActor
enum SourceDescription {
    static func name(_ track: RecordingTrack, in meeting: Meeting) -> String {
        RecordingWords.name(track, in: meeting)
    }

    static func symbol(_ track: RecordingTrack) -> String {
        if track.deviceKind == PhoneDevice.kind { return "iphone" }
        switch track.source {
        case .microphone: return "mic"
        case .systemAudio: return "desktopcomputer"
        case .soundcore: return "recordingtape"
        case .imported: return "doc"
        }
    }

    /// "Your Mac · The main recording", "Lined up by sound · starts 0:12"; nil when there's nothing to say.
    static func line(_ track: RecordingTrack, in meeting: Meeting) -> String? {
        RecordingWords.line(track, in: meeting, mac: "Your Mac", pending: "Lines up when your Mac processes it")
    }

    static func isUnaligned(_ track: RecordingTrack, in meeting: Meeting) -> Bool {
        RecordingWords.isUnaligned(track, in: meeting)
    }
}

// The files the share sheet is handed (`ExportFiles`) are DaybookKit's, shared with the Mac's Share menu.

/// Copy for conversation content: it stays on this iPhone (`.localOnly`) rather than going to
/// Universal Clipboard on nearby devices signed in to the same Apple Account.
enum LocalPasteboard {
    static func copy(_ text: String, to pasteboard: some LocalPasteboardWriting = UIPasteboard.general) {
        pasteboard.setItems([[UTType.utf8PlainText.identifier: text]], options: [.localOnly: true])
    }
}

/// What copying needs of a pasteboard, so tests can watch it.
protocol LocalPasteboardWriting {
    func setItems(_ items: [[String: Any]], options: [UIPasteboard.OptionsKey: Any])
}

extension UIPasteboard: LocalPasteboardWriting {}
