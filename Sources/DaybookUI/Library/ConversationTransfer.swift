import CoreTransferable
import DaybookKit
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// A Daybook conversation moving inside Daybook: a row dragged onto a place in the sidebar, or copied. Declared
    /// in the Mac app's Info.plist (`UTExportedTypeDeclarations`).
    public static let daybookConversation = UTType(exportedAs: "local.daybook.conversation")

    /// Markdown: the system's own type where it has one, else the type its `.md` files carry.
    static let daybookMarkdown = UTType("net.daringfireball.markdown") ?? UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText
}

/// A conversation as it travels out of a list: dragged, copied (⌘C), or shared. Inside Daybook it's the
/// conversation itself (its ID, `daybookConversation`), which a sidebar place files; to another app it's the
/// conversation's Markdown as a file named after it (Mail, Finder, Messages), or its title and gist as text (a text
/// field, Notes).
public struct ConversationTransfer: Codable, Identifiable, Sendable, Transferable {
    public let id: UUID
    public let title: String
    /// The Markdown export, named for the file (`MeetingExport.fileName`).
    let markdown: String
    let fileName: String
    /// The title, then the gist.
    let text: String

    private enum CodingKeys: String, CodingKey { case id, title }

    public init(_ meeting: Meeting) {
        id = meeting.id
        title = ConversationRowView.title(meeting)
        markdown = MeetingExport.markdown(meeting)
        fileName = MeetingExport.fileName(for: meeting)
        let gist = meeting.summary?.overview.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        text = gist.isEmpty ? title : "\(title)\n\n\(gist)"
    }

    /// Inside Daybook only the conversation's ID travels; what a drop needs it reads from the library.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        markdown = ""
        fileName = ""
        text = title
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
    }

    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .daybookConversation)
        FileRepresentation(exportedContentType: .daybookMarkdown) { item in
            SentTransferredFile(try item.writeMarkdown())
        }
        .suggestedFileName { $0.fileName + ".md" }
        ProxyRepresentation(exporting: \.text)
    }

    /// Writes the Markdown to a file of its own in a folder of its own under the temporary directory, which the
    /// system clears.
    func writeMarkdown() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Daybook Drag", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent((fileName.isEmpty ? "Conversation" : fileName) + ".md")
        try Data(markdown.utf8).write(to: url, options: .atomic)
        return url
    }
}
