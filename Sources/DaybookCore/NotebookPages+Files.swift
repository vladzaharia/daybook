import Foundation

// The files a page's record names, and the one place their paths are derived and checked: the store writes a drawing where
// `PageDrawing.relativePath(page:sha256:)` says, and the sync engine accepts one only where it says.

/// A file a page keeps in its conversation's folder: where, and the digest it must have.
public struct PageFile: Hashable, Sendable {
    public var relativePath: String
    public var sha256: String
}

extension PageDrawing {
    /// Whether the digest is a whole SHA-256 and the path is exactly the one derived from the page and it.
    func isStored(for page: UUID) -> Bool {
        SyncFiles.isHash(sha256) && relativePath == Self.relativePath(page: page, sha256: sha256)
    }
}

extension PageBackground {
    /// Whether the digest is a whole SHA-256, the extension one a path can carry, and the path exactly the one derived from
    /// the page, the digest, and the extension.
    func isStored(for page: UUID) -> Bool {
        SyncFiles.isHash(sha256) && Self.isFileExtension(fileExtension)
            && relativePath == Self.relativePath(page: page, sha256: sha256, fileExtension: fileExtension)
    }
}

extension NotebookPage {
    /// Every file the record names: its drawing, the drawings a merge set aside, and its background.
    public var files: [PageFile] {
        let drawings = (drawing.map { [$0] } ?? []) + (setAside ?? [])
        return drawings.map { PageFile(relativePath: $0.relativePath, sha256: $0.sha256) }
            + (background.map { [PageFile(relativePath: $0.relativePath, sha256: $0.sha256)] } ?? [])
    }

    /// Whether every file's path is the one derived from this page and the file's whole digest.
    var hasDerivedPaths: Bool {
        (drawing.map { [$0] } ?? []).allSatisfy { $0.isStored(for: id) } && (setAside ?? []).allSatisfy { $0.isStored(for: id) }
            && (background?.isStored(for: id) ?? true)
    }
}

extension Meeting {
    /// Every file any page names, deleted pages included (a deleted page keeps its files so it can be put back).
    public var pageFiles: [PageFile] { (pages ?? []).flatMap(\.files) }
}
