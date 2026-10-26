import AppKit
import DaybookCore
import Foundation

/// What a library folder holds, for deciding where a library is (docs/sandbox.md).
enum LibraryContents {
    /// Conversations, models, the Trash, or library settings: anything worth keeping. A folder holding only `Sync/`
    /// (written at launch) and empty folders counts as empty.
    static func hasContent(_ url: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.appendingPathComponent("library.json").path) { return true }
        for folder in ["Meetings", "Models", "Trash"] {
            let entries = (try? fm.contentsOfDirectory(atPath: url.appendingPathComponent(folder, isDirectory: true).path)) ?? []
            if entries.contains(where: { !$0.hasPrefix(".") }) { return true }
        }
        return false
    }

    /// Whether a folder looks like a library, from existence alone: in the App Sandbox a folder outside the container
    /// can't be listed, but whether something exists there can be checked.
    static func looksLikeLibrary(_ url: URL) -> Bool {
        ["library.json", "Meetings", "Models"].contains { FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path) }
    }

    /// When the library last changed, as far as its top-level entries say.
    static func lastChange(_ url: URL) -> Date? {
        ["library.json", "glossary.json", "Meetings", "Sync", "Trash"].compactMap {
            try? url.appendingPathComponent($0).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }.max()
    }

    /// A free name beside `url` for setting it aside: "Daybook (Older Copy 2026-10-26 0912)", then " 2", " 3"….
    static func asideURL(for url: URL, label: String, now: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd HHmm"
        let base = "\(url.lastPathComponent) (\(label) \(formatter.string(from: now)))"
        let parent = url.deletingLastPathComponent()
        var candidate = parent.appendingPathComponent(base, isDirectory: true), number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(base) \(number)", isDirectory: true); number += 1
        }
        return candidate
    }
}

/// Back from the App Sandbox: an unsandboxed Daybook (an earlier release, or a build with the sandbox off) running after
/// a sandboxed one moved the library into its container. It offers to move the library back, with the preferences the
/// sandboxed app kept, so going back to an unsandboxed release loses nothing. Nothing is ever deleted: a library already
/// here that's older is set aside under a new name first.
enum LegacyLibraryReturn {
    struct Plan: Equatable {
        /// The sandboxed app's library, in its container.
        var container: URL
        /// Where this build keeps its library.
        var library: URL
        /// The sandboxed app's preferences, in its container.
        var containerPreferences: URL
        /// A library here too, older than the container's: it's set aside before the move.
        var replacesOlder: Bool
        /// When the container's library last changed, to remember a "Not Now".
        var containerChanged: Date?
    }

    static let declinedKey = "sandboxLibraryReturnDeclined"

    /// What the two places hold.
    struct Facts: Equatable {
        var containerHasContent: Bool
        var libraryHasContent: Bool
        var containerChanged: Date?
        var libraryChanged: Date?
        /// `containerChanged` when the person last chose Not Now.
        var declinedAt: Date?
    }

    enum Kind: Equatable {
        case none
        /// Nothing here: move the container's library back.
        case moveBack
        /// A library here too, but the container's changed more recently: set this one aside and move that one back.
        case replaceOlder
    }

    static func classify(_ facts: Facts) -> Kind {
        guard facts.containerHasContent else { return .none }
        if let declined = facts.declinedAt, (facts.containerChanged ?? .distantPast) <= declined { return .none }
        guard facts.libraryHasContent else { return .moveBack }
        guard let container = facts.containerChanged, let library = facts.libraryChanged, container > library else { return .none }
        return .replaceOlder
    }

    /// The sandboxed app's container for `bundleIdentifier`, under the person's home.
    static func containerData(home: URL, bundleIdentifier: String) -> URL {
        home.appendingPathComponent("Library/Containers", isDirectory: true).appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
    }

    /// A plan when `library` (this unsandboxed app's) should take back the library a sandboxed build of the same app left
    /// in its container; nil otherwise.
    static func plan(library: URL, bundleIdentifier: String, home: URL = UserHome.url, defaults: UserDefaults) -> Plan? {
        let data = containerData(home: home, bundleIdentifier: bundleIdentifier)
        let container = data.appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(library.lastPathComponent, isDirectory: true)
        // Existence first, without reading: most Macs never ran a sandboxed Daybook.
        guard LibraryContents.looksLikeLibrary(container) else { return nil }
        let facts = Facts(containerHasContent: LibraryContents.hasContent(container), libraryHasContent: LibraryContents.hasContent(library),
                          containerChanged: LibraryContents.lastChange(container), libraryChanged: LibraryContents.lastChange(library),
                          declinedAt: defaults.object(forKey: declinedKey) as? Date)
        let kind = classify(facts)
        guard kind != .none else { return nil }
        return Plan(container: container, library: library,
                    containerPreferences: data.appendingPathComponent("Library/Preferences", isDirectory: true)
                        .appendingPathComponent("\(bundleIdentifier).plist"),
                    replacesOlder: kind == .replaceOlder, containerChanged: facts.containerChanged)
    }

    /// Not Now: asked again only once the container's library changes.
    static func decline(_ plan: Plan, defaults: UserDefaults) {
        defaults.set(plan.containerChanged ?? Date(), forKey: declinedKey)
    }

    /// Moves the library back and copies the sandboxed app's preferences. Returns where an older library was set aside.
    @discardableResult
    static func perform(_ plan: Plan, defaults: UserDefaults, now: Date = Date()) throws -> URL? {
        let aside = try move(plan, now: now)
        finish(plan, defaults: defaults)
        return aside
    }

    /// Sets aside whatever is at the library's place (never deleting it) and moves the container's library there (a
    /// rename on the same volume). If the move fails, what was set aside goes back. Returns where it was set aside.
    static func move(_ plan: Plan, now: Date = Date()) throws -> URL? {
        let fm = FileManager.default
        var aside: URL?
        if fm.fileExists(atPath: plan.library.path) {
            let destination = LibraryContents.asideURL(for: plan.library, label: "Older Copy", now: now)
            try fm.moveItem(at: plan.library, to: destination)
            aside = destination
        }
        try fm.createDirectory(at: plan.library.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try fm.moveItem(at: plan.container, to: plan.library) }
        catch {
            // Put back what was set aside, so the Mac is as it was.
            if let aside { try? fm.moveItem(at: aside, to: plan.library) }
            throw error
        }
        return aside
    }

    /// After the move: the sandboxed app's preferences, which are the newer ones.
    static func finish(_ plan: Plan, defaults: UserDefaults) {
        copyPreferences(from: plan.containerPreferences, into: defaults)
        defaults.removeObject(forKey: declinedKey)
    }

    /// Copies the app's own settings from a preferences file (the system's window and panel state stays behind). The
    /// sandboxed app's values are the newer ones. Returns how many were copied.
    @discardableResult
    static func copyPreferences(from plist: URL, into defaults: UserDefaults) -> Int {
        guard let values = NSDictionary(contentsOf: plist) as? [String: Any] else { return 0 }
        var copied = 0
        for (key, value) in values where !systemKey(key) {
            defaults.set(value, forKey: key); copied += 1
        }
        return copied
    }

    static func systemKey(_ key: String) -> Bool {
        ["NS", "Apple", "com.apple.", "WebKit"].contains { key.hasPrefix($0) }
    }
}

/// A library in the wrong place for this build, offered to the person at launch before the library opens.
enum LibraryMoveOffer: Identifiable, Equatable {
    /// Unsandboxed, after a sandboxed Daybook kept the library in its container (`LegacyLibraryReturn`).
    case returnFromContainer(LegacyLibraryReturn.Plan)

    var id: String {
        switch self {
        case .returnFromContainer: return "return"
        }
    }
}

/// Opens a new instance of the app and quits this one: after a library move, everything starts over with the library
/// where it now is.
enum AppRelaunch {
    @MainActor static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
