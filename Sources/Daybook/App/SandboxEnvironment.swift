import Foundation
import Security

/// Whether this process runs in the App Sandbox, and where it can reach outside its container. Read from the running
/// app's own code signature, so it answers for this build (docs/sandbox.md).
enum SandboxEnvironment {
    static let isSandboxed: Bool = entitlement("com.apple.security.app-sandbox") as? Bool == true

    /// Folders a temporary exception opens for reading and writing: `/private/tmp/daybook/` in ad hoc builds, for the
    /// debug flags' scratch files. Signed builds have none.
    static let exceptionPaths: [String] = entitlement("com.apple.security.temporary-exception.files.absolute-path.read-write") as? [String] ?? []

    /// Where a sandboxed run can read and write: its container (which holds its temporary folder) and the exceptions.
    static var reachableRoots: [String] { [NSHomeDirectory()] + exceptionPaths }

    private static func entitlement(_ key: String) -> Any? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, key as CFString, nil)
    }
}

/// The launch flags that take a path (`--library`, the diagnostics' `--models`, `--output`, and so on). In the App
/// Sandbox a path outside the container can't be reached: rather than failing later, or quietly writing nowhere, the
/// app stops at launch and says where it may write.
enum LaunchPaths {
    /// Flags whose value is a path, and whether it's a folder.
    static let flags = ["--library", "--snapshot", "--models", "--output", "--audio", "--evaluate", "--speaker-report"]

    /// One message per flag whose path this run can't reach; empty outside the sandbox.
    static func problems(arguments: [String], sandboxed: Bool = SandboxEnvironment.isSandboxed,
                         roots: [String] = SandboxEnvironment.reachableRoots) -> [String] {
        guard sandboxed else { return [] }
        var problems: [String] = []
        for flag in flags {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { continue }
            let value = arguments[index + 1]
            let path = (value as NSString).expandingTildeInPath
            guard !isReachable(path, roots: roots) else { continue }
            let places = roots.map { $0.hasSuffix("/") ? $0 : $0 + "/" }.joined(separator: " or ")
            problems.append("\(flag) \(value): this build runs in the App Sandbox and can’t reach it. Use a path under \(places).")
        }
        return problems
    }

    /// Whether `path` is one of `roots` or inside one. `/tmp`, `/var`, and `/etc` are read as the `/private` folders
    /// they link to, as the sandbox does.
    static func isReachable(_ path: String, roots: [String]) -> Bool {
        let candidate = canonical(path)
        return roots.map(canonical).contains { root in candidate == root || candidate.hasPrefix(root == "/" ? "/" : root + "/") }
    }

    static func canonical(_ path: String) -> String {
        var standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        for link in ["/tmp", "/var", "/etc"] where standardized == link || standardized.hasPrefix(link + "/") {
            standardized = "/private" + standardized
        }
        while standardized.count > 1, standardized.hasSuffix("/") { standardized.removeLast() }
        return standardized
    }
}
