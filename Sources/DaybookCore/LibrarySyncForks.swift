import Foundation

// A deletion is final for its conversation ID (docs/icloud-sync.md, "Conflicts and deletion"). What a device
// added that the deletion never saw — a recording made while it was deleted elsewhere, notes or photos added
// offline — is kept under a new ID instead: as a new conversation, or when a conversation is restored from
// the Trash after its deletion was synced.

extension Meeting {
    /// Whether this copy holds person-made or captured content that `seen` (the copy a deletion was made
    /// from) didn't: a recording, a photo, a bookmark, or a paragraph of notes. Derived work (transcripts,
    /// summaries) alone isn't. With no `seen`, anything of those counts.
    func hasContent(notIn seen: Meeting?) -> Bool {
        let tracks = Set(seen?.tracks.map(\.id) ?? []), photos = Set((seen?.photos ?? []).map(\.id))
        let marks = Set(seen?.highlights.map(\.id) ?? [])
        if self.tracks.contains(where: { !tracks.contains($0.id) }) { return true }
        if visiblePhotos.contains(where: { !photos.contains($0.id) }) { return true }
        if highlights.contains(where: { !marks.contains($0.id) }) { return true }
        let seenParagraphs = Set(Self.paragraphs(seen?.notes ?? ""))
        return Self.paragraphs(notes).contains { !seenParagraphs.contains($0) }
    }

    private static func paragraphs(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// This conversation as a new one with `id`: the same content and history, a Version History entry saying
    /// why, and its open requests asked again for the new conversation. Deterministic for the same input.
    public func keptAs(_ id: UUID, field: String, title: String) -> Meeting {
        var kept = self
        kept.id = id
        let open = openProcessingRequests.map { request -> ProcessingRequest in
            var copy = request
            copy.id = SyncEncoding.uuid("\(id.uuidString):request:\(request.id.uuidString)")
            copy.meetingID = id; copy.claim = nil
            return copy
        }
        kept.processingRequests = open.isEmpty ? nil : open
        kept.revisions.append(MeetingRevision(id: SyncEncoding.uuid("\(id.uuidString):\(field)"), date: updatedAt,
                                              field: "\(field):\(self.id.uuidString)", oldValue: self.id.uuidString, newValue: title))
        return kept
    }
}

/// Copies a conversation's files (originals, photos, sidecars) to another conversation's folder, leaving out
/// its `meeting.json` and recovery copies. Files already there are kept. On APFS a copy is a clone.
public enum MeetingFolderCopy {
    public static func copyFiles(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try LocalFiles.directory(destination)
        guard let items = try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) else { return }
        for item in items {
            let name = item.lastPathComponent
            if name == "meeting.json" || name == "meeting.recovery.json" || name.hasPrefix("meeting.corrupt-") { continue }
            if (try? fm.destinationOfSymbolicLink(atPath: item.path)) != nil { continue }
            let target = destination.appendingPathComponent(name)
            if fm.fileExists(atPath: target.path) {
                var isDirectory: ObjCBool = false
                if fm.fileExists(atPath: item.path, isDirectory: &isDirectory), isDirectory.boolValue { try copyFiles(from: item, to: target) }
                continue
            }
            try fm.copyItem(at: item, to: target)
        }
    }
}
