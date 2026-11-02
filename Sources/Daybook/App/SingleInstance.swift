import AppKit
import Foundation

/// One copy of Daybook at a time on this Mac, whichever build it is: the release or the App Store build
/// (`local.daybook`), an earlier release (`local.daybook.app`), an ad hoc or rehearsal build, or the unbundled `swift run`
/// binary (`AppIdentity.isMacApp`). Two copies would open the library, sync, listen for the iPhone, hold the recorder,
/// and record calls side by side.
///
/// A copy that finds an earlier one, before it starts anything, brings that one forward and quits. Copies that start
/// at the same moment agree on the earlier start (then the lower process ID), so exactly one stays. A copy another one
/// opened to start over (`AppRelaunch`, after a library move) first waits for that one to quit, and never gives way to it.
///
/// It all runs before the app starts, without suspending (`DaybookEntry`): past an `await` there, the app would run
/// inside one main-queue job, and no main-actor task or main-queue block would ever run in it.
enum SingleInstance {
    /// A running process, as much as the check needs of it.
    struct Copy: Equatable {
        var pid: pid_t
        var bundleID: String?
        var executableName: String?
        var launched: Date?
    }

    static func isDaybook(bundleID: String?, executableName: String?) -> Bool {
        AppIdentity.isMacApp(bundleID: bundleID, executableName: executableName)
    }

    /// The copy this one gives way to: the earliest other copy that started before it, except `relaunchedFrom`, the copy
    /// that opened this one and is quitting. Nil when this one is first.
    static func earlierCopy(than current: Copy, among running: [Copy], ignoring relaunchedFrom: pid_t? = nil) -> Copy? {
        func precedes(_ a: Copy, _ b: Copy) -> Bool {
            switch (a.launched, b.launched) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.pid < b.pid
            }
        }
        return running
            .filter { $0.pid != current.pid && $0.pid != relaunchedFrom && isDaybook(bundleID: $0.bundleID, executableName: $0.executableName) }
            .filter { precedes($0, current) }
            .min(by: precedes)
    }

    /// The flag `AppRelaunch` opens the new copy with, followed by its own process ID.
    static let relaunchFlag = "--relaunched-from"

    /// The copy that opened this one to start over (`--relaunched-from <pid>`); nil for an ordinary launch.
    static func relaunchedFrom(arguments: [String]) -> pid_t? {
        guard let index = arguments.firstIndex(of: relaunchFlag), arguments.indices.contains(index + 1),
              let pid = pid_t(arguments[index + 1]), pid > 0 else { return nil }
        return pid
    }

    /// Whether a process is still there (one this user can't signal is still running).
    static func isRunning(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    /// Returns once `pid` has exited (true), or after `limit` (false). It blocks the thread, checking every 20 ms.
    static func waitForExit(of pid: pid_t, within limit: Duration = .seconds(10)) -> Bool {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while isRunning(pid) {
            guard ContinuousClock.now < deadline else { return false }
            usleep(20_000)
        }
        return true
    }

    /// Run before the app starts: returns when this copy is the one, and otherwise brings the earlier copy forward
    /// and exits. A copy opened to start over waits (up to 10 seconds) for the one that opened it to quit, so the two
    /// don't open the library together, and stays even if that one is still quitting.
    @MainActor static func ensureOnlyCopy(arguments: [String] = CommandLine.arguments) {
        // Setting AppKit up checks this copy in with Launch Services. It fills in the running apps (this one included),
        // and it's what answers the launch request of a copy that opened this one, which only then starts to quit: so
        // it comes before the wait for that one.
        _ = NSApplication.shared
        let previous = relaunchedFrom(arguments: arguments)
        if let previous { _ = waitForExit(of: previous) }
        #if DEBUG
        // Screenshots and demos run beside the everyday app, each with a library and preferences of its own.
        if LaunchOptions.libraryURL != nil && !arguments.contains("--single-instance") { return }
        #endif
        let apps = NSWorkspace.shared.runningApplications
        guard let earlier = earlierCopy(than: copy(of: .current), among: apps.map(copy(of:)), ignoring: previous),
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
