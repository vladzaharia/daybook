import DaybookCaptions
import DaybookKit
import Foundation
import Observation
import os

/// "Protect while iPhone is locked" (Settings › Storage; docs/iphone.md, "File protection"): the class each of the
/// library's files takes, on and off.
///
/// On, the library's text is `complete` (class A), unreadable from shortly after the iPhone locks until it's unlocked:
/// each conversation's `meeting.json` and its recovery copy, the highlights beside its audio, the library's settings
/// (`library.json`, `glossary.json`, their copies), this iPhone's own records, sync's bases and checkpoint, the
/// courier's copies, and saved captions; and so are the widgets' snapshots. Audio and photos are `completeUnlessOpen`
/// (class B), so one being played or transcribed as the iPhone locks goes on. Off, the classes are as before: text
/// class C (`completeUntilFirstUserAuthentication`), saved captions class B (`LiveCaptionStore.defaultProtection`),
/// audio and photos class C, but for those recorded or taken on this iPhone, which stay class B as they were filed
/// (`StagingProtection`).
///
/// Left as they are either way: recordings in progress (`Staging/`, class B whatever this says; the folder itself is
/// made class B while it's on, so nothing made in it takes the library's class A), the captions of a recording in
/// progress or waiting for an unlock, and the few files that say how things stand rather than what was said, which
/// Daybook reads and writes while locked, kept class C: what sync sealed (`Sync/sealing.json`, which keeps an
/// encrypted library out of backups, `BackupExclusion`), the audio cache's record, the courier's ledgers, the stops owed
/// to Macs, and which recordings were brought in here. A folder takes its files' class, so what a save makes in it is
/// made with it.
enum LibraryProtection {
    /// What a file or folder is, for its class.
    enum Kind: Equatable, Sendable {
        /// What was said, written, and decided: class A on, C off.
        case text
        /// A saved caption file.
        case captions
        /// Audio and photos: class B on; off, B if made on this iPhone, else C.
        case media
        /// A folder of audio and photos.
        case mediaFolder
        /// How things stand: always class C.
        case state
        /// The staging folder itself: class B on, untouched off.
        case staging
    }

    /// What a pass leaves alone or treats as this iPhone's own, by path in the library.
    struct Exemptions: Equatable, Sendable {
        /// Paths beginning with one of these stay as they are (the captions of a recording in progress).
        var skipped: [String] = []
        /// Audio and photos recorded or taken on this iPhone (class B when it's off, as filed).
        var madeHere: Set<String> = []
    }

    /// Files that say how things stand, read and written while locked: read as Daybook starts, which may be in the
    /// background while locked, a file that couldn't be read would be taken for an empty one and written over.
    static let stateFiles: Set<String> = ["owed-stops.json", "brought-in-recordings.json", "Sync/sealing.json", "Sync/audio-cache.json",
                                          "Sync/Courier/outbox.json", "Sync/Courier/cloudkit-state.json"]
    static let stateFolders: Set<String> = ["Sync/Courier"]
    /// Audio, video, and photos, by extension.
    static let mediaExtensions: Set<String> = ["m4a", "mp4", "m4v", "mov", "caf", "wav", "aif", "aiff", "aifc", "mp3", "aac",
                                               "flac", "ogg", "opus", "amr", "3gp", "heic", "heif", "jpg", "jpeg", "png"]
    /// Folders of audio and photos, by name.
    static let mediaFolders: Set<String> = ["Originals", "Photos", "Blobs"]

    /// What the file or folder at `path` (relative to the library) is; nil for what a pass never touches: what's
    /// inside `Staging/`, and model downloads.
    static func kind(_ path: String, isDirectory: Bool) -> Kind? {
        let parts = path.split(separator: "/").map(String.init)
        guard let first = parts.first else { return .text }
        if first == "Staging" { return parts.count == 1 && isDirectory ? .staging : nil }
        if first == "Models" { return nil }
        if isDirectory {
            if stateFolders.contains(path) { return .state }
            return mediaFolders.contains(parts[parts.count - 1]) ? .mediaFolder : .text
        }
        if stateFiles.contains(path) { return .state }
        if first == "LiveCaptions" { return .captions }
        let ext = (path as NSString).pathExtension.lowercased()
        if mediaExtensions.contains(ext) || parts.dropLast().contains("Blobs") { return .media }
        return .text
    }

    /// The class `kind` takes; nil to leave it as it is.
    static func target(_ kind: Kind, protects: Bool, madeHere: Bool = false) -> FileProtectionType? {
        switch kind {
        case .text: return protects ? .complete : .completeUntilFirstUserAuthentication
        case .captions: return protects ? .complete : LiveCaptionStore.defaultProtection
        case .media: return protects || madeHere ? .completeUnlessOpen : .completeUntilFirstUserAuthentication
        case .mediaFolder: return protects ? .completeUnlessOpen : .completeUntilFirstUserAuthentication
        case .state: return .completeUntilFirstUserAuthentication
        case .staging: return protects ? StagingProtection.type : nil
        }
    }

    /// The class of the file at `path`: nil when a pass leaves it alone.
    static func target(_ path: String, isDirectory: Bool, protects: Bool, exemptions: Exemptions) -> FileProtectionType? {
        guard let kind = kind(path, isDirectory: isDirectory) else { return nil }
        if exemptions.skipped.contains(where: { path.hasPrefix($0) }) { return nil }
        return target(kind, protects: protects, madeHere: exemptions.madeHere.contains(path))
    }

    // MARK: Units

    /// A part of the library a run re-protects at once, noted as done when it's through: each conversation's folder (in
    /// the library and in the Trash), each other folder, the library's own files, and the widgets' snapshots.
    struct Unit: Hashable, Sendable {
        enum Scope: Hashable, Sendable {
            /// The folder only.
            case itself
            /// The folder and the files in it, not its folders.
            case files
            /// The folder and everything in it.
            case tree
        }

        /// Its name in the record of a run (`Meetings/<id>`, `Sync`, `.`, `#widgets`).
        var name: String
        var url: URL
        var scope: Scope
        /// What its files are: the library's, or the widgets' snapshots (all text).
        var inLibrary = true
    }

    static let widgetsUnit = "#widgets"

    /// Every unit, in a fixed order: the library's folder and its own files, then each folder in it, a conversation's
    /// at a time, then the widgets' snapshots.
    static func units(libraryRoot root: URL, widgets: URL?) -> [Unit] {
        let fileManager = FileManager.default
        var units = [Unit(name: ".", url: root, scope: .files)]
        let top = ((try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
        for name in top {
            let url = root.appendingPathComponent(name)
            guard isDirectory(url) else { continue }
            switch name {
            case "Models":
                continue
            case "Staging":
                units.append(Unit(name: name, url: url, scope: .itself))
            case "Meetings", "Trash":
                units.append(Unit(name: name, url: url, scope: .itself))
                let children = ((try? fileManager.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
                for child in children where isDirectory(url.appendingPathComponent(child)) {
                    units.append(Unit(name: "\(name)/\(child)", url: url.appendingPathComponent(child, isDirectory: true), scope: .tree))
                }
            default:
                units.append(Unit(name: name, url: url, scope: .tree))
            }
        }
        if let widgets, isDirectory(widgets) {
            units.append(Unit(name: widgetsUnit, url: widgets, scope: .tree, inLibrary: false))
        }
        return units
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    /// How a unit's pass went.
    enum Outcome: Equatable, Sendable {
        /// Every file has its class (or went meanwhile).
        case done
        /// A file couldn't be opened to change it: the iPhone may be locked.
        case couldNotOpen
    }

    /// Gives every file and folder in `unit` its class (`protects`), leaving alone what has it already. Blocking: run
    /// it off the main actor.
    static func apply(_ unit: Unit, libraryRoot root: URL, protects: Bool, exemptions: Exemptions) -> Outcome {
        var outcome = Outcome.done
        func visit(_ url: URL, isDirectory: Bool) {
            let wanted = unit.inLibrary
                ? target(relativePath(url, in: root), isDirectory: isDirectory, protects: protects, exemptions: exemptions)
                : target(.text, protects: protects)
            guard let wanted, ProtectionClass.of(url) != wanted else { return }
            do { try ProtectionClass.set(wanted, on: url) } catch let error as POSIXError {
                switch error.code {
                case .ENOENT, .ENOTDIR, .ELOOP: break
                case .EPERM, .EACCES: outcome = .couldNotOpen
                default: log.error("Couldn’t protect a file (\(error.code.rawValue, privacy: .public))")
                }
            } catch {}
        }
        visit(unit.url, isDirectory: true)
        guard unit.scope != .itself else { return outcome }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
        if unit.scope == .files {
            let names = (try? FileManager.default.contentsOfDirectory(at: unit.url, includingPropertiesForKeys: keys)) ?? []
            for url in names.sorted(by: { $0.path < $1.path }) {
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isRegularFile == true { visit(url, isDirectory: false) }
            }
            return outcome
        }
        guard let walk = FileManager.default.enumerator(at: unit.url, includingPropertiesForKeys: keys) else { return outcome }
        for case let url as URL in walk {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                if unit.inLibrary, kind(relativePath(url, in: root), isDirectory: true) == nil { walk.skipDescendants(); continue }
                visit(url, isDirectory: true)
            } else if values?.isRegularFile == true {
                visit(url, isDirectory: false)
            }
        }
        return outcome
    }

    /// `url`'s path inside the library ("Meetings/<id>/meeting.json"); "" for the library's folder.
    static func relativePath(_ url: URL, in root: URL) -> String {
        func inside(_ path: String, _ base: String) -> String? {
            guard path == base || path.hasPrefix(base + "/") else { return nil }
            return String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        if let path = inside(url.standardizedFileURL.path, root.standardizedFileURL.path) { return path }
        // One side named through a symbolic link (`/var` and `/private/var`).
        return inside(url.resolvingSymlinksInPath().path, root.resolvingSymlinksInPath().path) ?? url.lastPathComponent
    }

    static let log = Logger(subsystem: "local.daybook.phone", category: "Protection")
}

/// Switches the library's files between the classes "Protect while iPhone is locked" asks for (`LibraryProtection`):
/// in the background, a unit at a time, each noted as done in this iPhone's preferences as it's through, so a run that
/// Daybook didn't finish (it was killed, or the iPhone was locked) goes on where it stopped (`resume`). Changing a file's
/// class needs it readable, so a run waits while the iPhone is locked. While it's on, files a save made since are given
/// their class (`keep`), and what's made in the library's folders takes theirs.
@MainActor
@Observable
final class LibraryProtector {
    /// How far a run has come, while one runs (Settings › Storage's bar); nil otherwise.
    private(set) var progress: Double?

    /// A run, as kept in the preferences: the classes it gives, the units it's through, and whether it finished.
    struct Record: Codable, Equatable, Sendable {
        var protects: Bool
        var done: [String]
        var finished: Bool
    }

    static let recordKey = "phone.libraryProtection"

    @ObservationIgnored let libraryRoot: URL
    /// The widgets' snapshots' folder (`SharedWidgetCache`); nil without one (tests).
    @ObservationIgnored let widgets: URL?
    @ObservationIgnored private let defaults: UserDefaults
    /// The last run's record; nil when the library was never switched (its classes are off's).
    @ObservationIgnored private(set) var record: Record?
    /// Whether files kept until unlock can be read now, and a wait until they can.
    @ObservationIgnored var isAvailable: @MainActor () -> Bool = { true }
    @ObservationIgnored var untilAvailable: @MainActor () async -> Void = {}
    /// What a pass leaves alone, and what's this iPhone's own, read as each unit starts.
    @ObservationIgnored var exemptions: @MainActor () -> LibraryProtection.Exemptions = { LibraryProtection.Exemptions() }
    /// A run has finished.
    @ObservationIgnored var settled: @MainActor () -> Void = {}
    /// Each unit, as a run is about to re-protect it (tests stop a run there, as a kill would).
    @ObservationIgnored var willProtect: @MainActor (String) -> Void = { _ in }
    /// How long `keep` waits for saves to settle.
    @ObservationIgnored var keepDelay: Duration = .seconds(2)
    @ObservationIgnored private var run: Task<Void, Never>?
    @ObservationIgnored private var keeping: Task<Void, Never>?

    init(libraryRoot: URL, widgets: URL?, defaults: UserDefaults) {
        self.libraryRoot = libraryRoot.standardizedFileURL
        self.widgets = widgets
        self.defaults = defaults
        record = Self.record(in: defaults)
    }

    static func record(in defaults: UserDefaults) -> Record? {
        defaults.data(forKey: recordKey).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
    }

    /// The library's files have the classes `protects` asks for: a run toward them finished, or, off, none ever began.
    func isSettled(protects: Bool) -> Bool {
        guard let record else { return !protects }
        return record.protects == protects && record.finished
    }

    /// A run is under way (or waiting for an unlock).
    var isRunning: Bool { run != nil }

    /// The person switched (and at launch, with the switch as it is): every file gets the classes `protects` asks for,
    /// from the start, unless a run toward them finished or goes on where it stopped. A library never switched is off's
    /// already.
    func protect(_ protects: Bool) {
        if let record, record.protects == protects {
            if !record.finished { resume() }
            return
        }
        if record == nil, !protects { return }
        save(Record(protects: protects, done: [], finished: false))
        start()
    }

    /// At launch, and once the iPhone is unlocked: a run that didn't finish goes on where it stopped.
    func resume() {
        guard let record, !record.finished, run == nil else { return }
        start()
    }

    /// Stops a run where it is, as a kill would (tests): its record says how far it came.
    func stop() {
        run?.cancel()
        run = nil
        progress = nil
    }

    private func start() {
        run?.cancel()
        let previous = run
        run = Task { [weak self] in
            await previous?.value
            await self?.work()
        }
    }

    private func work() async {
        guard var record else { return }
        // The bar shows at once; how far it came, once the parts are listed.
        if progress == nil { progress = 0 }
        let root = libraryRoot, widgets = self.widgets
        let units = await Task.detached(priority: .utility) { LibraryProtection.units(libraryRoot: root, widgets: widgets) }.value
        var done = Set(record.done)
        func fraction() -> Double { units.isEmpty ? 1 : Double(units.filter { done.contains($0.name) }.count) / Double(units.count) }
        progress = fraction()
        for unit in units where !done.contains(unit.name) {
            while true {
                await untilAvailable()
                guard !Task.isCancelled else { return }
                willProtect(unit.name)
                guard !Task.isCancelled else { return }
                let exemptions = self.exemptions(), protects = record.protects
                let outcome = await Task.detached(priority: .utility) {
                    LibraryProtection.apply(unit, libraryRoot: root, protects: protects, exemptions: exemptions)
                }.value
                guard !Task.isCancelled else { return }
                // A file it couldn't open while the iPhone is locked: the unit again, once it's unlocked.
                if outcome == .couldNotOpen, !isAvailable() { continue }
                break
            }
            done.insert(unit.name)
            record.done = done.sorted()
            save(record)
            progress = fraction()
        }
        record.finished = true
        save(record)
        progress = nil
        run = nil
        settled()
    }

    /// While it's on: files a save made since with another class are given theirs, shortly after (`keepDelay`), or at
    /// once (`now`: the iPhone is locking). Only while the iPhone is unlocked and no run is under way.
    func keep(now: Bool = false) {
        guard let record, record.protects, record.finished, run == nil else { return }
        keeping?.cancel()
        let delay = now ? Duration.zero : keepDelay
        keeping = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self, self.isAvailable(), self.run == nil else { return }
            await self.sweep()
            self.keeping = nil
        }
    }

    /// Waits for what `keep` started (tests).
    func settle() async {
        await run?.value
        await keeping?.value
    }

    private func sweep() async {
        let root = libraryRoot, widgets = self.widgets, exemptions = self.exemptions()
        await Task.detached(priority: .utility) {
            for unit in LibraryProtection.units(libraryRoot: root, widgets: widgets) {
                _ = LibraryProtection.apply(unit, libraryRoot: root, protects: true, exemptions: exemptions)
            }
        }.value
    }

    private func save(_ record: Record) {
        self.record = record
        defaults.set(try? JSONEncoder().encode(record), forKey: Self.recordKey)
    }
}
