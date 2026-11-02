import Foundation

/// The software an app ships and the notices its licenses require, as the app's bundle carries them: the
/// repository's THIRD_PARTY_NOTICES.md as `ThirdPartyNotices.md`, and each resolved package's license and NOTICE
/// files under `Licenses/` as `<package>-<file>.txt` (the projects' "Copy third-party notices" step).
public struct SoftwareNotices: Equatable, Sendable {
    /// One package's license and notice files.
    public struct Package: Identifiable, Equatable, Sendable {
        public var name: String
        public var files: [File]
        public var id: String { name }

        public init(name: String, files: [File]) {
            self.name = name
            self.files = files
        }
    }

    public struct File: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case license, notice }
        public var kind: Kind
        public var text: String

        public init(kind: Kind, text: String) {
            self.kind = kind
            self.text = text
        }
    }

    /// THIRD_PARTY_NOTICES.md: the libraries, what each is for, their licenses, and the models' notices.
    public var notices: String?
    /// Each package's files, by name.
    public var packages: [Package]

    public init(notices: String?, packages: [Package]) {
        self.notices = notices
        self.packages = packages
    }

    public var isEmpty: Bool { (notices ?? "").isEmpty && packages.isEmpty }

    /// What the app's bundle carries, read once.
    public static let bundled = load()

    /// What `bundle` carries; nothing for a development build that wasn't packaged.
    public static func load(from bundle: Bundle = .main) -> SoftwareNotices {
        let notices = bundle.url(forResource: "ThirdPartyNotices", withExtension: "md").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let urls = bundle.urls(forResourcesWithExtension: "txt", subdirectory: "Licenses") ?? []
        let files = urls.compactMap { url -> (String, File)? in
            guard let (name, kind) = packageFile(url.lastPathComponent),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return (name, File(kind: kind, text: text))
        }
        return SoftwareNotices(notices: notices, packages: packages(files))
    }

    /// The names the copy step gives a package's files, and what each is.
    static let fileNames: [(name: String, kind: File.Kind)] = [
        ("LICENSE-MIT", .license), ("LICENSE.md", .license), ("LICENSE.txt", .license), ("LICENSE", .license), ("COPYING", .license),
        ("NOTICE.txt", .notice), ("NOTICES", .notice), ("NOTICE", .notice)
    ]

    /// "swift-transformers-LICENSE.txt" → ("swift-transformers", .license); nil for a name the step doesn't make.
    static func packageFile(_ fileName: String) -> (package: String, kind: File.Kind)? {
        guard fileName.hasSuffix(".txt") else { return nil }
        let stem = String(fileName.dropLast(".txt".count))
        for (name, kind) in fileNames where stem.hasSuffix("-" + name) {
            let package = String(stem.dropLast(name.count + 1))
            guard !package.isEmpty else { return nil }
            return (package, kind)
        }
        return nil
    }

    /// Files grouped by package, packages by name (as Finder sorts them), a license before a notice.
    static func packages(_ files: [(String, File)]) -> [Package] {
        Dictionary(grouping: files, by: { $0.0 })
            .map { name, files in
                Package(name: name, files: files.map(\.1).sorted { $0.kind == .license && $1.kind == .notice })
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The libraries THIRD_PARTY_NOTICES.md lists, with their licenses: "FluidAudio 0.17.7", "Apache-2.0". For
    /// the Mac's About panel credits.
    public var libraries: [(name: String, license: String)] {
        guard let notices else { return [] }
        for block in NoticesDocument.blocks(notices) {
            guard case .table(let header, let rows) = block, header.first == "Library" else { continue }
            let licenseColumn = header.firstIndex { $0.hasPrefix("License") } ?? header.count - 1
            return rows.compactMap { row in
                guard let name = row.first, row.indices.contains(licenseColumn) else { return nil }
                // "MIT · https://…": the license, without its source.
                let license = row[licenseColumn].components(separatedBy: " · ").first ?? row[licenseColumn]
                return (name, license)
            }
        }
        return []
    }
}

/// THIRD_PARTY_NOTICES.md as blocks a screen can draw: headings, paragraphs, its table, and the license texts in
/// code blocks, read without a Markdown library.
public enum NoticesDocument {
    public enum Block: Equatable, Sendable {
        case heading(String)
        case paragraph(String)
        case table(header: [String], rows: [[String]])
        case code(String)
    }

    public static func blocks(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var table: [[String]] = []
        var code: [String]?

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        func flushTable() {
            guard let header = table.first else { return }
            blocks.append(.table(header: header, rows: Array(table.dropFirst())))
            table = []
        }

        for line in markdown.components(separatedBy: .newlines) {
            if var lines = code {
                if line.hasPrefix("```") {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    lines.append(line)
                    code = lines
                }
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flushParagraph(); flushTable()
                code = []
            } else if trimmed.hasPrefix("#") {
                flushParagraph(); flushTable()
                blocks.append(.heading(trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else if trimmed.hasPrefix("|") {
                flushParagraph()
                let cells = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                // The row under the header: | --- | --- |.
                if cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-:".contains($0) } }) { continue }
                table.append(cells)
            } else if trimmed.isEmpty {
                flushParagraph(); flushTable()
            } else {
                flushTable()
                paragraph.append(trimmed)
            }
        }
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        flushParagraph(); flushTable()
        return blocks
    }
}
