import DaybookKit
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
