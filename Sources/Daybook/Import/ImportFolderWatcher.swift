import Foundation

/// Watches only an explicitly chosen directory. A file must be unchanged on two scans
/// before import, so AirDrop and network-copy partial files are not ingested.
@MainActor
final class ImportFolderWatcher: ObservableObject {
    static let audioExtensions: Set<String> = ["wav", "mp3", "m4a", "aac", "aiff", "aif", "caf", "flac", "mp4", "ogg"]
    @Published private(set) var folder: URL?
    @Published private(set) var status = "Choose a folder for Soundcore exports."
    var onImport: ((URL) async throws -> Void)?
    private var task: Task<Void, Never>?
    private var observations: [String: FileFingerprint] = [:]
    private var completed: Set<String> = []
    private var failures: Set<String> = []
    private var securityScope = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func restore() {
        guard let data = defaults.data(forKey: "importFolderBookmark") else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], bookmarkDataIsStale: &stale)
            try watch(url)
        } catch { status = "Choose your import folder again: \(error.localizedDescription)" }
    }

    func watch(_ url: URL) throws {
        stop()
        securityScope = url.startAccessingSecurityScopedResource()
        let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(bookmark, forKey: "importFolderBookmark")
        folder = url
        completed = Set(defaults.stringArray(forKey: "importedFileFingerprints") ?? [])
        observations = [:]
        failures = []
        status = "Watching \(url.lastPathComponent)"
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.scan()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stop(forget: Bool = false) {
        task?.cancel(); task = nil
        if securityScope { folder?.stopAccessingSecurityScopedResource() }
        securityScope = false
        folder = nil
        status = "Folder import is off."
        if forget { defaults.removeObject(forKey: "importFolderBookmark") }
    }

    func retry() { failures.removeAll(); status = "Retrying pending imports…" }

    private func scan() async {
        guard let folder, let onImport else { return }
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles])
            for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard !Task.isCancelled else { return }
                guard Self.audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                guard values.isRegularFile == true, let size = values.fileSize, size > 0,
                      let modified = values.contentModificationDate else { continue }
                let fingerprint = FileFingerprint(path: url.path, size: size, modified: modified.timeIntervalSince1970)
                let prior = observations.updateValue(fingerprint, forKey: url.path)
                guard prior == fingerprint, !completed.contains(fingerprint.key), !failures.contains(fingerprint.key) else { continue }
                do {
                    try await onImport(url)
                    completed.insert(fingerprint.key)
                    defaults.set(Array(completed).sorted(), forKey: "importedFileFingerprints")
                    status = "Imported \(url.lastPathComponent)"
                } catch {
                    failures.insert(fingerprint.key)
                    status = "Couldn’t import \(url.lastPathComponent): \(error.localizedDescription). Use Retry to try again."
                }
            }
        } catch { status = "Import folder unavailable: \(error.localizedDescription)" }
    }
}

struct FileFingerprint: Equatable {
    let path: String
    let size: Int
    let modified: TimeInterval
    var key: String { "\(path)|\(size)|\(modified)" }
}
