import Darwin
import Foundation

/// Copies processing makes of a conversation's audio (Parakeet's mono mix of a recording with several channels). They
/// live in `<temporary folder>/Daybook Processing/<process ID>/`, owner-only, and go when the work ends. One a run
/// left when it crashed or was killed is cleared at the next launch, as `ExportFiles` are, so a conversation's audio
/// never outlives it outside the library. A run that's still going (another Daybook beside this one: a development
/// build, a second library) keeps its own. The folder is in no iCloud container, and it's kept out of backups (Time
/// Machine, iPhone backups) by its own flag as well as by being in the temporary folder.
public enum ProcessingScratch {
    public static func root(in directory: URL = FileManager.default.temporaryDirectory) -> URL {
        directory.appendingPathComponent("Daybook Processing", isDirectory: true)
    }

    /// A new file in this run's folder, named for nothing it holds.
    static func file(extension pathExtension: String, in directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        var base = root(in: directory)
        let folder = base.appendingPathComponent(String(getpid()), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Best effort: the temporary folder is outside backups anyway, and no copy is refused for want of the flag.
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        try? base.setResourceValues(excluded)
        return folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(pathExtension)
    }

    /// Removes what runs that have ended left behind.
    public static func clear(in directory: URL = FileManager.default.temporaryDirectory) {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root(in: directory), includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            if let process = pid_t(folder.lastPathComponent), isRunning(process) { continue }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// This run, or another that's still going. A process this one may not signal (another app's) exists.
    static func isRunning(_ process: pid_t) -> Bool {
        guard process > 0 else { return false }
        return process == getpid() || kill(process, 0) == 0 || errno == EPERM
    }
}
