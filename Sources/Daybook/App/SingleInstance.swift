import AppKit
import Foundation

/// One copy of Daybook at a time on this Mac, whichever build it is: the release (`local.daybook.app`), the App Store
/// build (`local.daybook.phone`, `AppIdentity`), an ad hoc or rehearsal build (`local.daybook.app.…`), or the unbundled
/// `swift run` binary. Two copies would open the library, sync, listen for the iPhone, hold the recorder, and record calls
/// side by side.
///
/// A copy that finds an earlier one, before it starts anything, brings that one forward and quits. Copies that start
/// at the same moment agree on the earlier start (then the lower process ID), so exactly one stays.
enum SingleInstance {
    /// A running process, as much as the check needs of it.
    struct Copy: Equatable {
        var pid: pid_t
        var bundleID: String?
        var executableName: String?
        var launched: Date?
    }

    static func isDaybook(bundleID: String?, executableName: String?) -> Bool {
        guard let bundleID else { return executableName == AppIdentity.executable }
        // The sandboxed builds share the iPhone app's bundle ID; the iPhone app itself, run on a Mac, isn't this app.
        if bundleID == AppIdentity.sandboxed { return executableName == AppIdentity.executable }
        return bundleID == AppIdentity.unsandboxed || bundleID.hasPrefix(AppIdentity.unsandboxed + ".")
    }

    /// The copy this one gives way to: the earliest other copy that started before it. Nil when this one is first.
    static func earlierCopy(than current: Copy, among running: [Copy]) -> Copy? {
        func precedes(_ a: Copy, _ b: Copy) -> Bool {
            switch (a.launched, b.launched) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.pid < b.pid
            }
        }
        return running
            .filter { $0.pid != current.pid && isDaybook(bundleID: $0.bundleID, executableName: $0.executableName) }
            .filter { precedes($0, current) }
            .min(by: precedes)
    }

    /// Run before the app starts: returns when this copy is the one, and otherwise brings the earlier copy forward
    /// and exits.
    @MainActor static func ensureOnlyCopy() {
        #if DEBUG
        // Screenshots and demos run beside the everyday app, each with a library and preferences of its own.
        if LaunchOptions.libraryURL != nil && !CommandLine.arguments.contains("--single-instance") { return }
        #endif
        // AppKit fills in the running apps (this one included) only once it's set up.
        _ = NSApplication.shared
        let apps = NSWorkspace.shared.runningApplications
        guard let earlier = earlierCopy(than: copy(of: .current), among: apps.map(copy(of:))),
              let other = apps.first(where: { $0.processIdentifier == earlier.pid }) else { return }
        other.activate(from: .current, options: [.activateAllWindows])
        Darwin.exit(0)
    }

    private static func copy(of app: NSRunningApplication) -> Copy {
        Copy(pid: app.processIdentifier, bundleID: app.bundleIdentifier, executableName: app.executableURL?.lastPathComponent,
             launched: startTime(of: app.processIdentifier) ?? app.launchDate)
    }

    /// When the process started, from the kernel: unlike `launchDate`, known for the unbundled binary too, and to
    /// the microsecond, so copies started together still agree on which came first.
    static func startTime(of pid: pid_t) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }
}
