import Foundation

/// A stop one device owes another it couldn't reach (multipoint, docs/multipoint.md), with when it
/// was first owed.
public protocol OwedStop: Codable, Equatable {
    var owedAt: Date { get }
}

/// Stops a device owes devices it couldn't reach, kept where the device keeps its own local state
/// (its preferences, or a file in its library that never syncs), so that after a relaunch they're
/// still sent when the other device reconnects. Each is kept `lifetime` from when it was first owed:
/// by then the other device has stopped by its own rule (following the device that asked it, or
/// after 30 minutes out of reach), or the person has, and a late stop names the recording it means,
/// so it never stops another.
public struct OwedStopsStore<Stop: OwedStop> {
    private enum Backing {
        case defaults(UserDefaults, key: String)
        case file(URL)
    }

    private let backing: Backing
    public let lifetime: TimeInterval

    /// A day.
    public static var defaultLifetime: TimeInterval { 86_400 }

    /// Kept in preferences under `key`.
    public init(defaults: UserDefaults, key: String, lifetime: TimeInterval = defaultLifetime) {
        backing = .defaults(defaults, key: key)
        self.lifetime = lifetime
    }

    /// Kept in a file of its own (in the library's folder, beside other state that never syncs).
    public init(file: URL, lifetime: TimeInterval = defaultLifetime) {
        backing = .file(file)
        self.lifetime = lifetime
    }

    /// The stops still owed, oldest first: none older than `lifetime`, and none when what's kept
    /// can't be read (a stop is a courtesy; the other device stops by its own rule).
    public func load(now: Date = Date()) -> [Stop] {
        let data: Data?
        switch backing {
        case .defaults(let defaults, let key): data = defaults.data(forKey: key)
        case .file(let url): data = try? Data(contentsOf: url)
        }
        guard let data, let stops = try? JSONDecoder().decode([Stop].self, from: data) else { return [] }
        return stops.filter { now.timeIntervalSince($0.owedAt) < lifetime }.sorted { $0.owedAt < $1.owedAt }
    }

    /// Keeps exactly these (none: removes what was kept).
    public func save(_ stops: [Stop]) {
        let data = stops.isEmpty ? nil : try? JSONEncoder().encode(stops.sorted { $0.owedAt < $1.owedAt })
        switch backing {
        case .defaults(let defaults, let key):
            if let data { defaults.set(data, forKey: key) } else { defaults.removeObject(forKey: key) }
        case .file(let url):
            if let data {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
