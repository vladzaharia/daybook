#if DEBUG
import AppKit
import Darwin
import DaybookIntelligence
import Foundation
import Metal
import QuartzCore

/// Debug-only: `--perf-log <file>` watches the main thread while the app runs, to see what keeps the
/// window from answering (during processing, say). Once a second it appends a JSON line: how much of
/// that second the main thread spent on the CPU, the longest a ping from another thread waited for it
/// and every wait over 100 ms, what the app was doing (`stage`), and how often each view that calls
/// `PerfProbe.body(_:)` was drawn. A tiny window in the screen's corner presents a Metal frame at
/// every refresh from its own thread, so `frames` (presented), `dropped`, and `maxFrameGapMs` say
/// how promptly the GPU and the window server put anything on screen, whatever the main thread does.
enum PerfProbe {
    static let logURL: URL? = LaunchOptions.value(after: "--perf-log").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    static var isEnabled: Bool { logURL != nil }

    /// What the app is doing, read on the main thread with each ping.
    @MainActor static var stage: () -> String = { "" }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var bodies: [String: Int] = [:]
    nonisolated(unsafe) private static var currentStage = ""
    nonisolated(unsafe) private static var started = false
    nonisolated(unsafe) private static var presented: [CFTimeInterval] = []
    nonisolated(unsafe) private static var dropped = 0
    nonisolated(unsafe) private static var lastPresented: CFTimeInterval = 0

    /// Counts one evaluation of a view's body.
    static func body(_ name: String) {
        guard isEnabled else { return }
        lock.withLock { bodies[name, default: 0] += 1 }
    }

    /// Starts watching, from the main thread. Does nothing without `--perf-log`.
    @MainActor static func start() {
        guard let url = logURL, !lock.withLock({ let was = started; started = true; return was }) else { return }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let main = mach_thread_self()
        let thread = Thread { watch(main: main, log: url) }
        thread.name = "PerfProbe"
        thread.qualityOfService = .userInteractive
        thread.start()
        startFrames()
    }

    @MainActor private static var frameWindow: NSWindow?

    /// `--perf-progress`: reports progress into `activity` from another thread, 50 times a second, as an
    /// engine does: 20 seconds each of transcribing, finding speakers, and listening for music, over and over.
    /// With `--library-demo`, the demo's transcribing conversation shows it without any model running.
    static func driveProgress(_ activity: ActivityProgress) {
        guard isEnabled, CommandLine.arguments.contains("--perf-progress") else { return }
        let thread = Thread {
            sleep(4)
            let begin = Date()
            while true {
                let elapsed = Date().timeIntervalSince(begin)
                let phase = Int(elapsed / 20) % 3, fraction = elapsed.truncatingRemainder(dividingBy: 20) / 20
                let message = ["Transcribed \(Int(fraction * 923)) of 923 seconds", "Detecting speaker turns", "Listening for music and TV"][phase]
                activity.report(IntelligenceProgress(fraction, message))
                usleep(20_000)
            }
        }
        thread.name = "PerfProbe progress"
        thread.start()
    }

    @MainActor private static func startFrames() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let screen = NSScreen.main else { return }
        let window = NSWindow(contentRect: NSRect(x: screen.frame.minX, y: screen.frame.minY, width: 6, height: 6),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.ignoresMouseEvents = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.drawableSize = CGSize(width: 6, height: 6)
        layer.maximumDrawableCount = 3
        let view = NSView()
        view.layer = layer
        view.wantsLayer = true
        window.contentView = view
        window.orderFrontRegardless()
        frameWindow = window
        let thread = Thread {
            var frame = 0
            var next = Date()
            while true {
                // At most 120 frames a second; nothing is presented while the display sleeps.
                next = max(next.addingTimeInterval(1.0 / 120), Date())
                Thread.sleep(until: next)
                if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { Thread.sleep(forTimeInterval: 1); continue }
                autoreleasepool {
                    guard let drawable = layer.nextDrawable(), let buffer = queue.makeCommandBuffer() else { usleep(8_000); return }
                    let pass = MTLRenderPassDescriptor()
                    pass.colorAttachments[0].texture = drawable.texture
                    pass.colorAttachments[0].loadAction = .clear
                    pass.colorAttachments[0].storeAction = .store
                    frame += 1
                    pass.colorAttachments[0].clearColor = MTLClearColor(red: frame % 2 == 0 ? 0.5 : 0.52, green: 0.5, blue: 0.5, alpha: 1)
                    buffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
                    drawable.addPresentedHandler { shown in
                        lock.withLock {
                            if shown.presentedTime == 0 { dropped += 1 } else { presented.append(shown.presentedTime) }
                        }
                    }
                    buffer.present(drawable)
                    buffer.commit()
                }
            }
        }
        thread.name = "PerfProbe frames"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private static func watch(main: mach_port_t, log url: URL) {
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        let begin = Date()
        var lastCPU = cpuTime(main), lastReport = Date()
        var maxWait = 0.0, stalls: [Int] = []
        while true {
            // One ping at a time: how long the main queue takes to run it.
            let sent = Date()
            let answered = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let stage = PerfProbe.stage()
                    lock.withLock { currentStage = stage }
                }
                answered.signal()
            }
            answered.wait()
            let wait = Date().timeIntervalSince(sent)
            maxWait = max(maxWait, wait)
            if wait > 0.1 { stalls.append(Int(wait * 1000)) }
            let now = Date()
            if now.timeIntervalSince(lastReport) >= 1 {
                let cpu = cpuTime(main), elapsed = now.timeIntervalSince(lastReport)
                let (counts, stage, times, drops, previous) = lock.withLock { () -> ([String: Int], String, [CFTimeInterval], Int, CFTimeInterval) in
                    defer {
                        bodies = [:]
                        if let last = presented.max() { lastPresented = last }
                        presented = []; dropped = 0
                    }
                    return (bodies, currentStage, presented.sorted(), dropped, lastPresented)
                }
                var maxGap = 0.0, janks = 0, last = previous
                for time in times {
                    if last > 0 { let gap = time - last; maxGap = max(maxGap, gap); if gap > 0.05 { janks += 1 } }
                    last = time
                }
                let line: [String: Any] = [
                    "t": Double(Int(now.timeIntervalSince(begin) * 10)) / 10,
                    "busy": Int((cpu - lastCPU) / elapsed * 100),
                    "maxWaitMs": Int(maxWait * 1000),
                    "stallsMs": stalls,
                    "stage": stage,
                    "bodies": counts,
                    "frames": times.count,
                    "dropped": drops,
                    "maxFrameGapMs": Int(maxGap * 1000),
                    "frameGapsOver50ms": janks,
                ]
                if let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) {
                    handle.write(data + Data("\n".utf8))
                }
                lastCPU = cpu; lastReport = now; maxWait = 0; stalls = []
            }
            usleep(20_000)
        }
    }

    /// The thread's user and system CPU time, in seconds.
    private static func cpuTime(_ thread: mach_port_t) -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1e6
            + Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1e6
    }
}
#endif
