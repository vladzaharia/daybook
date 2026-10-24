import AppKit
import Combine
import CoreAudio
import CoreGraphics
import Foundation

/// A conservative rule: audio activity alone never establishes that a call has begun.
struct MeetingAppRule: Codable, Equatable, Identifiable {
    var id: String { bundleID }
    var bundleID: String
    var displayName: String
    var meetingTitleFragments: [String]
    var isBrowser: Bool = false

    static let defaults: [MeetingAppRule] = [
        .init(bundleID: "us.zoom.xos", displayName: "Zoom", meetingTitleFragments: ["zoom meeting", "zoom webinar", "zoom workplace meeting"]),
        .init(bundleID: "com.microsoft.teams2", displayName: "Teams", meetingTitleFragments: ["meeting |", "call |", "(meeting)", "meeting with"]),
        .init(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack", meetingTitleFragments: ["huddle"]),
        .init(bundleID: "com.google.Chrome", displayName: "Chrome", meetingTitleFragments: browserTitles, isBrowser: true),
        .init(bundleID: "com.apple.Safari", displayName: "Safari", meetingTitleFragments: browserTitles, isBrowser: true),
        .init(bundleID: "org.mozilla.firefox", displayName: "Firefox", meetingTitleFragments: browserTitles, isBrowser: true),
        .init(bundleID: "com.microsoft.edgemac", displayName: "Edge", meetingTitleFragments: browserTitles, isBrowser: true),
        .init(bundleID: "company.thebrowser.Browser", displayName: "Arc", meetingTitleFragments: browserTitles, isBrowser: true)
    ]
    private static let browserTitles = ["google meet", "meet.google.com", "meet -", "zoom meeting", "teams.microsoft.com", "microsoft teams meeting"]
}

struct MeetingCandidate: Equatable {
    var bundleID: String
    var appName: String
    var windowTitle: String
    var hasInputActivity: Bool
    var hasOutputActivity: Bool
    var hasMeetingWindow: Bool
    var isBrowser: Bool

    // Browser audio belongs to the whole process, not a tab. Requiring input at
    // startup avoids recording media from another tab beside a dormant Meet tab.
    var canStart: Bool { hasMeetingWindow && (hasInputActivity || (hasOutputActivity && !isBrowser)) }
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

@MainActor
final class MeetingMonitor: ObservableObject {
    @Published private(set) var isMonitoring = false
    @Published private(set) var isMeetingActive = false
    @Published private(set) var activeCandidate: MeetingCandidate?
    @Published private(set) var statusText = "Off"
    private static let listening = "Listening for calls"
    var rules = MeetingAppRule.defaults
    var onMeetingStarted: ((MeetingCandidate) -> Void)?
    var onMeetingEnded: (() -> Void)?
    private var machine = MeetingDetectionStateMachine()
    private var timer: Timer?

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        statusText = Self.listening
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        machine.reset()
        isMonitoring = false
        isMeetingActive = false
        activeCandidate = nil
        statusText = "Off"
    }

    func suppressCurrentMeeting() {
        machine.suppressCurrentMeeting()
        isMeetingActive = false
        statusText = "Paused until this call ends."
    }

    private func sample() {
        guard isMonitoring else { return }
        guard CGPreflightScreenCaptureAccess() else {
            endOnDetectionFailure()
            statusText = "Needs Screen & System Audio Recording permission."
            return
        }
        do {
            let candidates = try MeetingActivityReader.candidates(rules: rules)
            let event = machine.update(candidates, at: Date())
            if let active = machine.activeBundleID {
                activeCandidate = candidates.first(where: { $0.bundleID == active }) ?? activeCandidate
            } else if machine.suppressedBundleID == nil {
                activeCandidate = candidates.first(where: \.canStart)
            }
            if machine.suppressedBundleID != nil {
                statusText = "Paused until this call ends."
            } else if let activeCandidate {
                statusText = isMeetingActive ? "Recording a \(activeCandidate.callName)." : "Checking whether the \(activeCandidate.callName) has started…"
            } else {
                statusText = Self.listening
            }
            switch event {
            case .started(let candidate):
                activeCandidate = candidate
                isMeetingActive = true
                statusText = "Recording a \(candidate.callName)."
                onMeetingStarted?(candidate)
            case .ended:
                isMeetingActive = false
                activeCandidate = nil
                statusText = "The call ended, so recording stopped."
                onMeetingEnded?()
            case nil: break
            }
        } catch {
            endOnDetectionFailure()
            statusText = "Can’t check for calls right now."
        }
    }

    private func endOnDetectionFailure() {
        let wasActive = isMeetingActive
        machine.reset()
        isMeetingActive = false
        activeCandidate = nil
        if wasActive { onMeetingEnded?() }
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
        guard let activity = try? MeetingActivityReader.audioActivity() else { return nil }
        return choose(rules: rules, activity: activity.map { Activity(bundleID: $0.bundleID, input: $0.input, output: $0.output) })
    }

    /// A native app using the microphone wins, then a native app playing audio, then a browser
    /// using the microphone. A browser that is only playing audio is not assumed to be a call.
    static func choose(rules: [MeetingAppRule], activity: [Activity]) -> CallAppTarget? {
        var ranked: [(rank: Int, order: Int, rule: MeetingAppRule)] = []
        for (order, rule) in rules.enumerated() {
            let target = CallAppTarget(bundleID: rule.bundleID, displayName: rule.displayName, isBrowser: rule.isBrowser)
            let processes = activity.filter { target.owns(bundleID: $0.bundleID) }
            let input = processes.contains(where: \.input), output = processes.contains(where: \.output)
            let rank: Int?
            if rule.isBrowser { rank = input ? 2 : nil }
            else { rank = input ? 0 : (output ? 1 : nil) }
            if let rank { ranked.append((rank, order, rule)) }
        }
        guard let best = ranked.min(by: { ($0.rank, $0.order) < ($1.rank, $1.order) }) else { return nil }
        return CallAppTarget(bundleID: best.rule.bundleID, displayName: best.rule.displayName, isBrowser: best.rule.isBrowser)
    }
}

private extension MeetingCandidate {
    /// How status lines name the call: "Zoom call", "Slack huddle", "call in Chrome".
    var callName: String {
        if isBrowser { return "call in \(appName)" }
        return appName == "Slack" ? "Slack huddle" : "\(appName) call"
    }
}

private enum MeetingActivityReader {
    struct AudioActivity {
        var bundleID: String
        var input: Bool
        var output: Bool
    }

    static func candidates(rules: [MeetingAppRule]) throws -> [MeetingCandidate] {
        let activity = try audioActivity()
        let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return rules.compactMap { rule in
            let processes = activity.filter { belongs($0.bundleID, to: rule.bundleID) }
            let matchingTitle = windows.compactMap { window -> String? in
                guard (window[kCGWindowLayer as String] as? Int ?? 0) == 0,
                      let pid = window[kCGWindowOwnerPID as String] as? Int32,
                      let app = NSRunningApplication(processIdentifier: pid),
                      let bundle = app.bundleIdentifier, belongs(bundle, to: rule.bundleID),
                      let title = window[kCGWindowName as String] as? String,
                      rule.meetingTitleFragments.contains(where: { title.localizedCaseInsensitiveContains($0) })
                else { return nil }
                return title
            }.first
            let input = processes.contains(where: \.input)
            let output = processes.contains(where: \.output)
            guard input || output || matchingTitle != nil else { return nil }
            return MeetingCandidate(bundleID: rule.bundleID, appName: rule.displayName,
                windowTitle: matchingTitle ?? rule.displayName, hasInputActivity: input,
                hasOutputActivity: output, hasMeetingWindow: matchingTitle != nil, isBrowser: rule.isBrowser)
        }
    }

    private static func belongs(_ processBundle: String, to bundle: String) -> Bool {
        processBundle == bundle || processBundle.hasPrefix(bundle + ".")
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    static func audioActivity() throws -> [AudioActivity] {
        var property = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size)
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard !objects.isEmpty else { return [] }
        status = objects.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, bytes.baseAddress!)
        }
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return objects.compactMap { object in
            guard let pid: pid_t = scalar(object, selector: kAudioProcessPropertyPID), pid != ProcessInfo.processInfo.processIdentifier else { return nil }
            var bundleProperty = address(kAudioProcessPropertyBundleID)
            var bundle: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(object, &bundleProperty, 0, nil, &bundleSize, &bundle) == noErr else { return nil }
            let id = (bundle?.takeRetainedValue() as String?) ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
            let input: UInt32 = scalar(object, selector: kAudioProcessPropertyIsRunningInput) ?? 0
            let output: UInt32 = scalar(object, selector: kAudioProcessPropertyIsRunningOutput) ?? 0
            return AudioActivity(bundleID: id, input: input != 0, output: output != 0)
        }
    }

    private static func scalar<T: FixedWidthInteger>(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> T? {
        var property = address(selector)
        var value: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}
