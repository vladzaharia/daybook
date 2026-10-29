import Darwin
import Foundation

/// What `MeetingStore.loadLibraryMetadata()` found in `library.json`.
public struct LibraryMetadataFile: Sendable {
    /// The library's settings, or nil when it has none saved yet.
    public var metadata: LibraryMetadata?
    /// False when `library.json` couldn't be read, or a newer Daybook wrote it: it's never
    /// overwritten, and changes stay in this session (and in sync) until Daybook can read it.
    public var isWritable: Bool
    /// What happened, in a sentence for the person, when it wasn't simply read.
    public var warnings: [String]
}

/// Whether `library.json` may be written, and whether it holds the last settings this store
/// validated (so it can become the recovery copy when it's replaced).
enum LibraryFileState: Sendable {
    case unknown, writable(primaryIsValid: Bool), readOnly
}

/// The library's settings (`library.json`, with `library.recovery.json` beside it), recovered like a
/// conversation's metadata: a damaged file is kept aside and the last saved copy used; a file that
/// can't be read, or that a newer Daybook wrote, is never overwritten; and settings that a newer
/// version added (an unknown template kind) are left out rather than closing the library.
extension MeetingStore {
    private var libraryURL: URL { rootURL.appendingPathComponent("library.json") }
    private var libraryRecoveryURL: URL { rootURL.appendingPathComponent("library.recovery.json") }

    public func loadLibraryMetadata() -> LibraryMetadataFile {
        let primary = Self.readLibraryFile(libraryURL)
        switch primary {
        case .valid(let metadata):
            libraryFile = .writable(primaryIsValid: true)
            return LibraryMetadataFile(metadata: metadata, isWritable: true, warnings: [])
        case .newer(let partial):
            libraryFile = .readOnly
            return LibraryMetadataFile(metadata: partial, isWritable: false, warnings: [
                "Your folders and templates were saved by a newer Daybook. Update Daybook to change them on this device."])
        case .unreadable:
            libraryFile = .readOnly
            let recovered = Self.readLibraryFile(libraryRecoveryURL).metadata
            return LibraryMetadataFile(metadata: recovered, isWritable: false, warnings: [
                "Your folders and templates couldn’t be read, so changes to them won’t be saved until Daybook can read them."])
        case .missing, .damaged:
            if case .damaged = primary { keepDamagedLibraryFile() }
            if case .valid(let metadata) = Self.readLibraryFile(libraryRecoveryURL),
               let bytes = try? Data(contentsOf: libraryRecoveryURL), (try? LocalFiles.atomicWrite(bytes, to: libraryURL)) != nil {
                noteWrite(libraryURL)
                libraryFile = .writable(primaryIsValid: true)
                return LibraryMetadataFile(metadata: metadata, isWritable: true, warnings: [
                    "Recovered your folders and templates from their last saved copy."])
            }
            libraryFile = .writable(primaryIsValid: false)
            guard case .damaged(let partial) = primary else {
                return LibraryMetadataFile(metadata: nil, isWritable: true, warnings: [])
            }
            return LibraryMetadataFile(metadata: partial, isWritable: true, warnings: [
                "Some of your folders and templates couldn’t be read. A copy of the file was kept in the library folder."])
        }
    }

    /// Writes the library's settings, keeping the file it replaces as the recovery copy.
    public func saveLibraryMetadata(_ metadata: LibraryMetadata) throws {
        if case .unknown = libraryFile { _ = loadLibraryMetadata() }
        guard case .writable(let primaryIsValid) = libraryFile else { throw LibraryError.unreadableLibrarySettings }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try encoder.encode(metadata)
        if primaryIsValid, FileStamp(libraryURL) != nil {
            let temporary = rootURL.appendingPathComponent(".library-\(UUID().uuidString).json")
            try bytes.write(to: temporary, options: .withoutOverwriting)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if renamex_np(temporary.path, libraryURL.path, UInt32(RENAME_SWAP)) == 0 {
                guard rename(temporary.path, libraryRecoveryURL.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
            } else {
                try LocalFiles.atomicWrite(Data(contentsOf: libraryURL), to: libraryRecoveryURL)
                guard rename(temporary.path, libraryURL.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
            }
        } else {
            try LocalFiles.atomicWrite(bytes, to: libraryURL)
            if !FileManager.default.fileExists(atPath: libraryRecoveryURL.path) || Self.readLibraryFile(libraryRecoveryURL).metadata == nil {
                try LocalFiles.atomicWrite(bytes, to: libraryRecoveryURL)
            }
        }
        libraryFile = .writable(primaryIsValid: true)
        noteWrite(libraryURL); noteWrite(libraryRecoveryURL)
    }

    private func keepDamagedLibraryFile() {
        let damaged = rootURL.appendingPathComponent("library.damaged-\(UUID().uuidString).json")
        try? FileManager.default.copyItem(at: libraryURL, to: damaged)
    }

    private enum LibraryFileRead {
        case missing, unreadable, valid(LibraryMetadata), newer(LibraryMetadata?), damaged(LibraryMetadata?)

        var metadata: LibraryMetadata? {
            if case .valid(let metadata) = self { return metadata }
            return nil
        }
    }

    /// Missing and unreadable are different: a file that exists but can't be read (permissions, an
    /// I/O error) must not be mistaken for a library without settings and overwritten.
    private static func readLibraryFile(_ url: URL) -> LibraryFileRead {
        let bytes: Data
        do { bytes = try Data(contentsOf: url) }
        catch {
            let missing = (error as? CocoaError)?.code == .fileReadNoSuchFile || (error as? POSIXError)?.code == .ENOENT
            return missing && !FileManager.default.fileExists(atPath: url.path) ? .missing : .unreadable
        }
        let decoder = JSONDecoder()
        if let metadata = try? decoder.decode(LibraryMetadata.self, from: bytes) {
            return metadata.schemaVersion == 1 ? .valid(metadata) : metadata.schemaVersion > 1 ? .newer(lenient(bytes)) : .damaged(lenient(bytes))
        }
        if let header = try? decoder.decode(LibrarySchemaHeader.self, from: bytes), header.schemaVersion > 1 { return .newer(lenient(bytes)) }
        return .damaged(lenient(bytes))
    }

    /// Every entry that decodes; an entry this version can't read (a newer template kind) is left out.
    private static func lenient(_ bytes: Data) -> LibraryMetadata? {
        (try? JSONDecoder().decode(LenientLibraryMetadata.self, from: bytes))?.value
    }
}

private struct LibrarySchemaHeader: Decodable { var schemaVersion: Int }

private struct LenientLibraryMetadata: Decodable {
    var value = LibraryMetadata()

    private enum Keys: String, CodingKey { case folders, templates, vocabulary, recorders, handoffs, speakerProfiles, voiceprints }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        value.folders = Self.entries(container, .folders) ?? []
        value.templates = Self.entries(container, .templates) ?? []
        value.vocabulary = Self.entries(container, .vocabulary) ?? []
        value.recorders = Self.entries(container, .recorders)
        value.handoffs = Self.entries(container, .handoffs)
        value.speakerProfiles = Self.entries(container, .speakerProfiles)
        value.voiceprints = Self.entries(container, .voiceprints)
    }

    private static func entries<Value: Codable & Equatable & Sendable>(_ container: KeyedDecodingContainer<Keys>, _ key: Keys) -> [LibraryValue<Value>]? {
        (try? container.decodeIfPresent([Lenient<LibraryValue<Value>>].self, forKey: key))?.flatMap { $0.compactMap(\.value) }
    }
}

private struct Lenient<Value: Decodable>: Decodable {
    var value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}
