import AppKit
import CoreGraphics
import DaybookCore
import Foundation
import Observation

/// A conservative rule: audio activity alone never establishes that a call has begun, except in an app that uses the
/// microphone for nothing but calls.
struct MeetingAppRule: Codable, Equatable, Identifiable, Sendable {
    var id: String { bundleID }
    var bundleID: String
    var displayName: String
    var meetingTitleFragments: [String]
    var isBrowser: Bool = false
    /// Whether a call needs a meeting window to start. An app whose window is there all along (FaceTime, Discord,
    /// WhatsApp, Signal) can't say a call by its window, so its call starts on the microphone alone and ends with its
    /// audio.
    var needsMeetingWindow: Bool = true

    /// Whether its audio plays through a process other apps share (Orion's, WebKit's GPU process, which is Safari's
    /// too): it's a candidate only with a meeting window of its own, so Safari's audio is never Orion's call.
    var sharesAudioProcess: Bool { bundleID.lowercased() == "com.kagi.kagimacos" }

    static let defaults: [MeetingAppRule] = [
        .init(bundleID: "us.zoom.xos", displayName: "Zoom", meetingTitleFragments: ["zoom meeting", "zoom webinar", "zoom workplace meeting"]),
        .init(bundleID: "com.microsoft.teams2", displayName: "Teams", meetingTitleFragments: teamsTitles),
        .init(bundleID: "com.microsoft.teams", displayName: "Teams (classic)", meetingTitleFragments: teamsTitles),
        .init(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack", meetingTitleFragments: ["huddle"]),
        .init(bundleID: "com.cisco.webexmeetingsapp", displayName: "Webex", meetingTitleFragments: ["webex", "meeting"]),
        .init(bundleID: "com.webex.meetingmanager", displayName: "Webex Meetings", meetingTitleFragments: ["webex", "meeting"]),
        .init(bundleID: "com.logmein.GoToMeeting", displayName: "GoTo Meeting", meetingTitleFragments: ["goto", "meeting"]),
        .init(bundleID: "com.amazon.Amazon-Chime", displayName: "Chime", meetingTitleFragments: ["meeting", "call"]),
        .init(bundleID: "com.apple.FaceTime", displayName: "FaceTime", meetingTitleFragments: [], needsMeetingWindow: false),
        .init(bundleID: "com.hnc.Discord", displayName: "Discord", meetingTitleFragments: [], needsMeetingWindow: false),
        .init(bundleID: "net.whatsapp.WhatsApp", displayName: "WhatsApp", meetingTitleFragments: [], needsMeetingWindow: false),
        .init(bundleID: "org.whispersystems.signal-desktop", displayName: "Signal", meetingTitleFragments: [], needsMeetingWindow: false),
        .init(bundleID: "com.google.Chrome", displayName: "Chrome", meetingTitleFragments: browserTitles, isBrowser: true),
        .init(bundleID: "com.apple.Safari", displayName: "Safari", meetingTitleFragments: browserTitles, isBrowser: true),
        .init(bundleID: "org.mozilla.firefox", displayName: "Firefox", meetingTitleFragments: browserTitles, isBrowser: true),
        .init(bundleID: "com.microsoft.edgemac", displayName: "Edge", meetingTitleFragments: browserTitles, isBrowser: true),
        .init(bundleID: "company.thebrowser.Browser", displayName: "Arc", meetingTitleFragments: browserTitles, isBrowser: true),
        .init(bundleID: "company.thebrowser.dia", displayName: "Dia", meetingTitleFragments: browserTitles, isBrowser: true),
        .init(bundleID: "com.brave.Browser", displayName: "Brave", meetingTitleFragments: browserTitles, isBrowser: true),
        .init(bundleID: "com.vivaldi.Vivaldi", displayName: "Vivaldi", meetingTitleFragments: browserTitles, isBrowser: true),
        .init(bundleID: "com.operasoftware.Opera", displayName: "Opera", meetingTitleFragments: browserTitles, isBrowser: true),
        .init(bundleID: "com.kagi.kagimacOS", displayName: "Orion", meetingTitleFragments: browserTitles, isBrowser: true)
    ]
    private static let teamsTitles = ["meeting |", "call |", "(meeting)", "meeting with"]
    private static let browserTitles = ["google meet", "meet.google.com", "meet -", "zoom meeting", "teams.microsoft.com", "microsoft teams meeting",
                                        "webex", "whereby", "jitsi"]
}

struct MeetingCandidate: Equatable, Sendable {
    var bundleID: String
    var appName: String
    var windowTitle: String
    var hasInputActivity: Bool
    var hasOutputActivity: Bool
    var hasMeetingWindow: Bool
    var isBrowser: Bool
    /// False for an app that uses the microphone for nothing but calls (`MeetingAppRule.needsMeetingWindow`).
    var needsMeetingWindow = true

    // Browser audio belongs to the whole process, not a tab. Requiring input at
    // startup avoids recording media from another tab beside a dormant Meet tab.
    var canStart: Bool {
        guard needsMeetingWindow else { return hasInputActivity }
        return hasMeetingWindow && (hasInputActivity || (hasOutputActivity && !isBrowser))
    }
    // A dedicated native meeting window stays meaningful while muted. A browser tab
    // can stay open after a call ends, so browsers must continue using an audio device.
    var canContinue: Bool { hasInputActivity || hasOutputActivity || (hasMeetingWindow && !isBrowser) }
}

/// Pure, clock-injected state machine. A manual stop suppresses re-start for the
/// current call until its evidence has disappeared for the full end debounce.
struct MeetingDetectionStateMachine {
    enum Event: Equatable {
        case started(MeetingCandidate)
        case ended
    }

    var startDelay: TimeInterval = 6
    var endDelay: TimeInterval = 45
    private(set) var activeBundleID: String?
    private(set) var suppressedBundleID: String?
    private var pending: (id: String, since: Date)?
    private var absentSince: Date?

    mutating func suppressCurrentMeeting() {
        suppressedBundleID = activeBundleID ?? pending?.id
        activeBundleID = nil
        pending = nil
        absentSince = nil
    }

    mutating func reset() {
        activeBundleID = nil
        suppressedBundleID = nil
        pending = nil
        absentSince = nil
    }

    /// A look at the Mac that couldn't be made: nothing is known. A pending start waits for the next look, and a
    /// suppressed call stays suppressed. A call being recorded isn't ended by it: unknown counts as missing evidence, so
    /// it ends only once nothing has confirmed the call for the full end debounce, as when its app goes quiet.
    mutating func unknown(at now: Date) -> Event? {
        guard suppressedBundleID == nil, activeBundleID != nil else { return nil }
        let since = absentSince ?? now
        absentSince = since
        guard now.timeIntervalSince(since) >= endDelay else { return nil }
        activeBundleID = nil
        absentSince = nil
        return .ended
    }

    mutating func update(_ candidates: [MeetingCandidate], at now: Date) -> Event? {
        if let suppressedBundleID {
            if candidates.contains(where: { $0.bundleID == suppressedBundleID && $0.canContinue }) {
                absentSince = nil
            } else {
                absentSince = absentSince ?? now
                if now.timeIntervalSince(absentSince!) >= endDelay {
                    self.suppressedBundleID = nil
                    absentSince = nil
                }
            }
            return nil
        }

        if let activeBundleID {
            if candidates.contains(where: { $0.bundleID == activeBundleID && $0.canContinue }) {
                absentSince = nil
            } else {
                absentSince = absentSince ?? now
                if now.timeIntervalSince(absentSince!) >= endDelay {
                    self.activeBundleID = nil
                    absentSince = nil
                    return .ended
                }
            }
            return nil
        }

        guard let candidate = candidates.first(where: \.canStart) else {
            pending = nil
            return nil
        }
        guard let pending, pending.id == candidate.bundleID else {
            pending = (candidate.bundleID, now)
            return nil
        }
        guard now.timeIntervalSince(pending.since) >= startDelay else { return nil }
        activeBundleID = candidate.bundleID
        self.pending = nil
        return .started(candidate)
    }
}

/// What one look at the Mac found (`MeetingActivityReader.read`), made off the main actor.
enum MeetingReading: Equatable, Sendable {
    /// The allowed apps' call evidence. Without Screen & System Audio Recording no window title can be read: nothing new
    /// starts then, and a call already being recorded continues for as long as its app's audio does.
    case seen([MeetingCandidate], windowsReadable: Bool)
    /// The audio server couldn't be asked, so nothing is known.
    case failed
}

/// What became of a call the monitor found: it's being recorded, Daybook is asking about it, or it isn't recorded (the
/// app's Never, or a recording already under way of something else), which pauses the monitor until it ends.
enum CallResponse: Equatable, Sendable {
    case recording, asking, notRecorded
}

/// Watches for calls while "When a call starts" isn't Off. Every two seconds it looks at the Mac off the main actor
/// (`MeetingActivityReader`), and only the state machine's answer comes back here, so a Mac with hundreds of windows
/// never stalls the window it's drawing.
@MainActor
@Observable
final class MeetingMonitor {
    private(set) var isMonitoring = false
    private(set) var isMeetingActive = false
    private(set) var activeCandidate: MeetingCandidate?
    private(set) var statusText = MeetingMonitor.off
    var rules = MeetingAppRule.defaults
    /// A call has started; what became of it. Without a handler it's being recorded.
    @ObservationIgnored var onMeetingStarted: ((MeetingCandidate) -> CallResponse)?
    /// The call ended, with the call it was. Returns whether that stopped a recording (one it started), which the status
    /// line then says.
    @ObservationIgnored var onMeetingEnded: ((MeetingCandidate?) -> Bool)?
    /// Daybook is asking whether to record the active call.
    @ObservationIgnored private var asking = false
    @ObservationIgnored private var machine = MeetingDetectionStateMachine()
    /// A call goes on that the person said not to record (Not Now, Never), until it ends.
    var isLeavingCallAlone: Bool { machine.suppressedBundleID != nil }
    @ObservationIgnored private var sampling: Task<Void, Never>?
    /// Looks in a row that couldn't be made.
    @ObservationIgnored private var failures = 0
    /// What the line says about the call that just ended, until another shows up.
    @ObservationIgnored private var endedLine: String?
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private let read: @Sendable ([MeetingAppRule]) -> MeetingReading

    static let off = "Off"
    static let listening = "Listening for calls"
    static let paused = "Paused until this call ends."
    static let needsPermission = "Needs Screen & System Audio Recording permission."
    static let cantCheck = "Can’t check for calls right now."
    static let endedAndStopped = "The call ended, so recording stopped."
    static let ended = "The call ended."
    /// Failed looks in a row before the line says so; fewer pass unremarked.
    static let failuresBeforeSaying = 3

    /// `read` looks at the Mac; tests pass a script, so nothing reads the real window list or audio server.
    init(interval: Duration = .seconds(2),
         read: @escaping @Sendable ([MeetingAppRule]) -> MeetingReading = { MeetingActivityReader.read(rules: $0) }) {
        self.interval = interval
        self.read = read
    }

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        statusText = Self.listening
        let read = self.read, interval = self.interval
        sampling = Task { [weak self] in
            while !Task.isCancelled {
                guard let rules = self?.rules else { return }
                let reading = await detachedWork(priority: .utility) { read(rules) }
                // Stopped while it looked: what it saw is no longer wanted.
                guard !Task.isCancelled else { return }
                self?.apply(reading, at: Date())
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stopMonitoring() {
        sampling?.cancel()
        sampling = nil
        machine.reset()
        failures = 0
        endedLine = nil
        isMonitoring = false
        isMeetingActive = false
        activeCandidate = nil
        asking = false
        statusText = Self.off
    }

    func suppressCurrentMeeting() {
        machine.suppressCurrentMeeting()
        isMeetingActive = false
        asking = false
        statusText = Self.paused
    }

    /// The call Daybook asked about is being recorded now.
    func callRecordingStarted() {
        asking = false
        if let activeCandidate, isMeetingActive { statusText = "Recording a \(activeCandidate.callName)." }
    }

    /// One look's answer, on the main actor. Internal so tests drive the monitor with scripted looks and times.
    func apply(_ reading: MeetingReading, at now: Date) {
        // The call as it was before this look: the look that ends it has already let it go.
        let previous = activeCandidate
        let event: MeetingDetectionStateMachine.Event?
        switch reading {
        case .failed:
            // A failed look is unknown, never the end of a call (which would split it in two).
            failures += 1
            event = machine.unknown(at: now)
        case .seen(let candidates, let windowsReadable):
            failures = 0
            event = machine.update(candidates, at: now)
            if let active = machine.activeBundleID {
                activeCandidate = candidates.first(where: { $0.bundleID == active }) ?? activeCandidate
            } else if machine.suppressedBundleID == nil {
                activeCandidate = candidates.first(where: \.canStart)
            }
            if activeCandidate != nil || machine.suppressedBundleID != nil { endedLine = nil }
            statusText = line(windowsReadable: windowsReadable)
        }
        switch event {
        case .started(let candidate):
            activeCandidate = candidate
            isMeetingActive = true
            endedLine = nil
            switch onMeetingStarted?(candidate) ?? .recording {
            case .recording:
                asking = false
                statusText = "Recording a \(candidate.callName)."
            case .asking:
                asking = true
                statusText = "Asking whether to record the \(candidate.callName)."
            case .notRecorded:
                suppressCurrentMeeting()
            }
        case .ended:
            let call = previous
            isMeetingActive = false
            activeCandidate = nil
            asking = false
            let line = onMeetingEnded?(call) == true ? Self.endedAndStopped : Self.ended
            endedLine = line
            statusText = line
        case nil:
            if failures >= Self.failuresBeforeSaying { statusText = Self.cantCheck }
        }
    }

    private func line(windowsReadable: Bool) -> String {
        if machine.suppressedBundleID != nil { return Self.paused }
        if let activeCandidate {
            guard isMeetingActive else { return "Checking whether the \(activeCandidate.callName) has started…" }
            return asking ? "Asking whether to record the \(activeCandidate.callName)." : "Recording a \(activeCandidate.callName)."
        }
        if !windowsReadable { return Self.needsPermission }
        return endedLine ?? Self.listening
    }
}

/// Picks the call app to record on its own when a recording starts without a detected meeting.
/// Uses Core Audio activity only (no window titles), which needs no permission.
enum CallAppResolver {
    struct Activity: Equatable {
        var bundleID: String
        var input: Bool
        var output: Bool
    }

    static func activeCallApp(rules: [MeetingAppRule]) -> CallAppTarget? {
        guard let processes = try? AudioProcessCatalog.read() else { return nil }
        let own = getpid()
        return choose(rules: rules, activity: processes.filter { $0.pid != own }.map {
            Activity(bundleID: $0.bundleID, input: $0.isRunningInput, output: $0.isRunningOutput)
        })
    }

    /// A native app using the microphone wins, then a native app playing audio, then a browser
    /// using the microphone. A browser that is only playing audio is not assumed to be a call.
    static func choose(rules: [MeetingAppRule], activity: [Activity]) -> CallAppTarget? {
        var ranked: [(rank: Int, order: Int, rule: MeetingAppRule)] = []
        for (order, rule) in rules.enumerated() {
            let target = CallAppTarget(rule)
            let processes = activity.filter { target.owns(bundleID: $0.bundleID) }
            let input = processes.contains(where: \.input), output = processes.contains(where: \.output)
            let rank: Int?
            if rule.isBrowser { rank = input ? 2 : nil }
            else { rank = input ? 0 : (output ? 1 : nil) }
            if let rank { ranked.append((rank, order, rule)) }
        }
        guard let best = ranked.min(by: { ($0.rank, $0.order) < ($1.rank, $1.order) }) else { return nil }
        return CallAppTarget(best.rule)
    }
}

extension CallAppTarget {
    init(_ rule: MeetingAppRule) {
        self.init(bundleID: rule.bundleID, displayName: rule.displayName, isBrowser: rule.isBrowser)
    }
}

extension MeetingCandidate {
    /// How status lines and notifications name the call: "Zoom call", "Slack huddle", "call in Chrome".
    var callName: String {
        if isBrowser { return "call in \(appName)" }
        return appName == "Slack" ? "Slack huddle" : "\(appName) call"
    }
}

/// Looks at the Mac for calls. Any thread may call it; the monitor runs it off the main actor.
enum MeetingActivityReader {
    /// A titled window in the normal layer, with its app's bundle ID.
    struct Window: Equatable, Sendable {
        var bundleID: String
        var title: String
    }

    /// One look: the audio server's processes once and, when Screen & System Audio Recording lets titles be read, the
    /// window list once.
    static func read(rules: [MeetingAppRule]) -> MeetingReading {
        guard let processes = try? AudioProcessCatalog.read() else { return .failed }
        let own = getpid()
        let windowsReadable = CGPreflightScreenCaptureAccess()
        return .seen(candidates(rules: rules, processes: processes.filter { $0.pid != own },
                                windows: windowsReadable ? titledWindows() : []),
                     windowsReadable: windowsReadable)
    }

    /// Every titled window in the normal layer, including those on other Spaces or minimized (a full-screen call has a
    /// Space of its own). Each app is looked up once, however many windows it has.
    static func titledWindows() -> [Window] {
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var bundles: [pid_t: String?] = [:]
        var windows: [Window] = []
        for window in list {
            guard (window[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  let title = window[kCGWindowName as String] as? String, !title.isEmpty,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t else { continue }
            let bundle: String?
            if let known = bundles[pid] {
                bundle = known
            } else {
                bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                bundles[pid] = bundle
            }
            if let bundle { windows.append(Window(bundleID: bundle, title: title)) }
        }
        return windows
    }

    /// Which allowed apps show call evidence: a meeting window, the microphone in use, or audio playing. An app's
    /// processes are the ones its call is recorded from (`CallAppTarget.owns`: its helpers, and a browser's audio process).
    static func candidates(rules: [MeetingAppRule], processes: [AudioProcessInfo], windows: [Window]) -> [MeetingCandidate] {
        rules.compactMap { rule in
            let target = CallAppTarget(rule)
            let owned = processes.filter { target.owns(bundleID: $0.bundleID) }
            let title = windows.first { window in
                target.owns(bundleID: window.bundleID)
                    && rule.meetingTitleFragments.contains(where: { window.title.localizedCaseInsensitiveContains($0) })
            }?.title
            let input = owned.contains(where: \.isRunningInput)
            let output = owned.contains(where: \.isRunningOutput)
            guard input || output || title != nil, title != nil || !rule.sharesAudioProcess else { return nil }
            return MeetingCandidate(bundleID: rule.bundleID, appName: rule.displayName, windowTitle: title ?? rule.displayName,
                                    hasInputActivity: input, hasOutputActivity: output, hasMeetingWindow: title != nil,
                                    isBrowser: rule.isBrowser, needsMeetingWindow: rule.needsMeetingWindow)
        }
    }
}
