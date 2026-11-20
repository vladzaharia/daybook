import DaybookWatchLink
import Foundation
import Observation
import SwiftUI
import WatchKit

/// Daybook on the watch (docs/watch.md): the recorder, the recordings it holds, and the iPhone's word, tied together.
/// It records along with the iPhone's shared recording as one of its recorders: joining it when Daybook opens here,
/// starting and stopping when the iPhone asks, and sending each segment as it closes. What the iPhone's context and
/// messages mean is `WatchFollowing`'s, which the Mac tests; this does what it decides.
@MainActor
@Observable
final class WatchModel {
    // What the screen shows.
    private(set) var recording: WatchRecordingInfo?
    private(set) var isCapturing = false
    private(set) var level: Float = 0
    /// Why the last start failed or the recording ended on its own, until the next start.
    private(set) var problem: String?
    private(set) var isReachable = false
    /// Finished recordings have segments the iPhone doesn't have yet.
    private(set) var isSending = false
    private(set) var phoneName: String?

    @ObservationIgnored private let store = WatchStore.standard
    @ObservationIgnored private let recorder: WatchRecorder
    @ObservationIgnored private let link: PhoneLink
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var following: WatchFollowing
    /// Finished recordings the iPhone hasn't imported, oldest first.
    @ObservationIgnored private var held: [WatchRecordingJournal] = []
    @ObservationIgnored private var phase: ScenePhase = .background
    @ObservationIgnored private var launched = false
    /// A recording is starting (waiting for the microphone): nothing else starts, and the iPhone's `.start` and `.stop`
    /// wait in `waiting` until it has.
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var waiting: [(WatchMessage, PhoneLink.Reply?)] = []
    /// A change to report once the link is up (recordings closed at launch).
    @ObservationIgnored private var changeAtActivation: WatchChange?

    private static let followingKey = "following"
    private static let watchIDKey = "watchID"

    init() {
        recorder = WatchRecorder(store: store)
        link = PhoneLink(store: store)
        following = defaults.data(forKey: Self.followingKey).flatMap { try? JSONDecoder().decode(WatchFollowing.self, from: $0) }
            ?? WatchFollowing()
        phoneName = following.context?.phoneName
        recorder.onEvent = { [weak self] event in self?.recorderEvent(event) }
        link.onActivated = { [weak self] in self?.linkActivated() }
        link.onSettled = { [weak self] in self?.sendUnsent() }
        link.onMessage = { [weak self] message, reply in self?.handle(message, reply: reply) }
        link.onContext = { [weak self] context, answered in self?.contextArrived(context, answered: answered) }
        link.onReachability = { [weak self] reachable in self?.reachabilityChanged(reachable) }
        link.onTransferred = { [weak self] segment in self?.transferred(segment) }
    }

    /// At launch (in the foreground or the background): closes what the app was ended during, and reaches the iPhone.
    /// A recording closed here keeps its conversation unleft, so with Record Along on the watch joins the shared recording
    /// again as Daybook opens, if it's still going (the iPhone imports both recordings into that conversation).
    func launch() {
        guard !launched else { return }
        launched = true
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
        let (journals, recovered) = store.recoverAll()
        held = journals.filter(\.recording.isFinished)
        if !recovered.isEmpty { changeAtActivation = .recovered }
        refresh()
        link.activate()
    }

    /// Holds a WatchConnectivity background task until what arrived has been handled.
    func hold(_ task: WKWatchConnectivityRefreshBackgroundTask) { link.hold(task) }

    func scenePhaseChanged(_ phase: ScenePhase) {
        launch()
        self.phase = phase
        recorder.setMetering(phase == .active)
        guard phase == .active else {
            level = 0
            return
        }
        if recorder.isRecording, !recorder.isCapturing { resume() }
        followPhone()
    }

    /// The record button.
    func toggleRecording() {
        if recorder.isRecording {
            stopRecording(.stoppedOnWatch)
        } else {
            beginStart(conversationID: nil, startedAt: nil, change: .startedOnWatch)
        }
    }

    /// The words under the button, only when they matter.
    var statusLine: String? {
        if let problem { return problem }
        if let recording {
            if !isCapturing { return "Paused" }
            if recording.conversationID != nil { return "With \(phoneName ?? "your iPhone")" }
            return isReachable ? nil : "Can't reach iPhone"
        }
        if isSending { return isReachable ? "Sending to iPhone…" : "Can't reach iPhone" }
        return nil
    }

    // MARK: Recording

    /// Recording starts only with Daybook in the foreground (`WKApplication`'s state, active or inactive).
    private var canStart: Bool { WKApplication.shared().applicationState != .background }

    private var followed: WatchFollowing.Recording? {
        recorder.journal.map {
            WatchFollowing.Recording(id: $0.recording.id, conversationID: $0.recording.conversationID,
                                     conversationStartedAt: $0.conversationStartedAt, startedAt: $0.recording.startedAt, isOwn: $0.isOwn)
        }
    }

    /// Starts a recording, unless one is recording or starting already; `reply` answers the iPhone's `.start` once it has.
    private func beginStart(conversationID: UUID?, startedAt: Date?, change: WatchChange, reply: PhoneLink.Reply? = nil) {
        guard !recorder.isRecording, !starting else {
            reply?.callAsFunction(.state(state(nil)))
            return
        }
        starting = true
        Task { await startRecording(conversationID: conversationID, startedAt: startedAt, change: change, reply: reply) }
    }

    private func startRecording(conversationID: UUID?, startedAt: Date?, change: WatchChange, reply: PhoneLink.Reply?) async {
        do {
            guard await WatchRecorder.microphoneAllowed() else { throw WatchRecorderError.microphoneDenied }
            var journal = WatchRecordingJournal(recording: WatchRecordingInfo(id: UUID().uuidString, conversationID: conversationID,
                                                                               startedAt: Date()))
            journal.conversationStartedAt = conversationID == nil ? nil : startedAt
            // The iPhone's Record with nothing recording there: the watch's own, which no context of the iPhone's stops.
            journal.isOwn = conversationID == nil && change == .startedByPhone
            try recorder.start(journal)
            problem = nil
            WKInterfaceDevice.current().play(.start)
            recorder.setMetering(phase == .active)
            // Started on the wrist (or for no conversation), it adopts the shared recording from the context the iPhone
            // sends once it hears of it here, never from one the watch already had.
            push(change)
            reply?.callAsFunction(.state(state(change)))
        } catch {
            problem = (error as? WatchRecorderError)?.line ?? "Couldn't start recording"
            refresh()
            reply?.callAsFunction(.refused((error as? WatchRecorderError)?.phoneWords ?? WatchFollowing.openToRecord))
        }
        startFinished()
    }

    /// After a start, whether it recorded or not: the iPhone's messages that waited for it are handled as if they came
    /// after it (a `.stop` for it stops it), then the newest context, which may have changed meanwhile.
    private func startFinished() {
        starting = false
        let waited = waiting
        waiting = []
        for (message, reply) in waited { handle(message, reply: reply) }
        if recorder.isRecording, !starting { apply(following.follow(recording: followed, canStart: canStart)) }
    }

    private func stopRecording(_ change: WatchChange) {
        guard let journal = recorder.stop() else { return }
        // Not joined again on its own (a context-driven stop's conversation is over anyway). With no conversation, nor is
        // a shared recording the iPhone started for it before it stopped.
        following.leave(journal.recording.conversationID)
        saveFollowing()
        held.append(journal)
        // The last segment, and any that closed without going out.
        link.send(journal.unsent)
        WKInterfaceDevice.current().play(.stop)
        push(change)
    }

    private func resume() {
        do {
            try recorder.resume()
            push(.resumed)
        } catch {
            refresh()
        }
    }

    private func recorderEvent(_ event: WatchRecorder.Event) {
        switch event {
        case .closed(let segment):
            link.send([segment])
            push(nil)
        case .level(let level):
            self.level = level
        case .interrupted(let segment):
            if let segment { link.send([segment]) }
            level = 0
            push(.interrupted)
        case .interruptionEnded:
            if phase == .active { resume() }
        case .failed(let message):
            problem = message
            stopRecording(.endedOnItsOwn)
        }
    }

    // MARK: The iPhone

    private func linkActivated() {
        isReachable = link.isReachable
        push(changeAtActivation)
        changeAtActivation = nil
        if phase == .active { followPhone() }
    }

    /// Asks the iPhone what it records (its answer comes to `contextArrived`), or reads its last word when it's out of reach.
    /// Only when there's something to join or adopt: a recording's end comes with the iPhone's next context anyway.
    private func followPhone() {
        guard link.isActivated, recorder.journal?.recording.conversationID == nil else { return }
        if link.isReachable {
            link.askContext()
        } else if let context = link.receivedContext {
            contextArrived(context, answered: false)
        } else {
            apply(following.follow(recording: followed, canStart: canStart))
        }
    }

    private func reachabilityChanged(_ reachable: Bool) {
        isReachable = reachable
        guard reachable else { return }
        sendUnsent()
        if phase == .active { followPhone() }
    }

    /// Every segment the iPhone still needs: no receipt names it and no transfer of it finished (`PhoneLink.send` skips
    /// those on their way). Only once the link has settled, so what finished while the app wasn't running counts first.
    private func sendUnsent() {
        guard link.isSettled else { return }
        link.send(held.flatMap(\.unsent) + (recorder.journal?.unsent ?? []))
    }

    private func contextArrived(_ context: PhoneContext, answered: Bool) {
        let decision = following.received(context, answered: answered, recording: followed, canStart: canStart)
        saveFollowing()
        phoneName = following.context?.phoneName ?? phoneName
        apply(decision)
    }

    private func apply(_ decision: WatchFollowing.Decision) {
        switch decision {
        case .none:
            break
        case .join(let shared):
            beginStart(conversationID: shared.conversationID, startedAt: shared.startedAt, change: .joined)
        case .adopt(let shared):
            recorder.adopt(shared.conversationID, startedAt: shared.startedAt)
            push(nil)
        case .stop:
            stopRecording(.stoppedByPhone)
            // The iPhone moved on to another shared recording: follow it when Daybook is open here.
            apply(following.follow(recording: nil, canStart: canStart))
        }
    }

    private func handle(_ message: WatchMessage, reply: PhoneLink.Reply?) {
        switch message {
        case .start(let start):
            if starting { waiting.append((message, reply)) } else { handleStart(start, reply: reply) }
        case .stop(let stop):
            if starting { waiting.append((message, reply)) } else { handleStop(stop, reply: reply) }
        case .status:
            reply?.callAsFunction(.state(state(nil)))
        case .clock(let phoneTime):
            reply?.callAsFunction(.clock(WatchClockSample(phoneSent: phoneTime, watchTime: Date())))
        case .received(let receipt):
            received(receipt)
        case .context, .state:
            // The watch's own messages to the iPhone.
            break
        }
    }

    private func handleStart(_ start: WatchStart, reply: PhoneLink.Reply?) {
        let decision = following.start(start, recording: followed, canStart: canStart)
        saveFollowing()
        switch decision {
        case .recording:
            reply?.callAsFunction(.state(state(nil)))
        case .adopt:
            if let conversation = start.conversationID { recorder.adopt(conversation, startedAt: start.startedAt) }
            push(.startedByPhone)
            reply?.callAsFunction(.state(state(.startedByPhone)))
        case .start, .replace:
            if case .replace = decision { stopRecording(.stoppedByPhone) }
            beginStart(conversationID: start.conversationID, startedAt: start.startedAt, change: .startedByPhone, reply: reply)
        case .refuse(let words):
            reply?.callAsFunction(.refused(words))
        }
    }

    private func handleStop(_ stop: WatchStop, reply: PhoneLink.Reply?) {
        let stops = following.stops(stop, recording: followed)
        if stops { stopRecording(.stoppedByPhone) }
        reply?.callAsFunction(.state(state(stops ? .stoppedByPhone : nil)))
    }

    /// The iPhone's receipt: the segments it holds of a recording. When it asks (`requestsMissing`), those of a finished
    /// recording it leaves out go again, but for any whose transfer finished moments ago or that are on their way
    /// (`WatchRecordingJournal.receive`, `PhoneLink.send`); once the recording is in its library, the watch forgets it.
    private func received(_ receipt: WatchReceipt) {
        if recorder.journal?.recording.id == receipt.recordingID {
            link.send(recorder.receive(receipt))
        } else if let index = held.firstIndex(where: { $0.recording.id == receipt.recordingID }) {
            if receipt.imported {
                store.delete(receipt.recordingID)
                held.remove(at: index)
            } else {
                let resend = held[index].receive(receipt)
                try? store.save(held[index])
                link.send(resend)
            }
        }
        push(nil)
    }

    /// A segment's transfer finished: it isn't sent again unless the iPhone asks for it.
    private func transferred(_ segment: WatchSegment) {
        if recorder.journal?.recording.id == segment.recordingID {
            recorder.sent(segment.index)
        } else if let index = held.firstIndex(where: { $0.recording.id == segment.recordingID }) {
            held[index].sent(segment.index)
            try? store.save(held[index])
        }
    }

    // MARK: State

    private func state(_ change: WatchChange?) -> WatchState {
        let device = WKInterfaceDevice.current()
        var current = recorder.journal?.recording
        if let recording = current { current?.duration = max(recording.duration, recorder.recorded) }
        let space = WatchStore.space()
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String).map { "\($0) (\(info?["CFBundleVersion"] as? String ?? "?"))" }
        return WatchState(watchID: watchID, recording: current, isCapturing: recorder.isCapturing, finished: held.map(\.recording),
                          change: change,
                          battery: device.batteryLevel >= 0 ? Int((device.batteryLevel * 100).rounded()) : nil,
                          charging: device.batteryState == .charging || device.batteryState == .full,
                          freeBytes: space.free, totalBytes: space.total, appVersion: version, model: device.model)
    }

    /// Tells the iPhone (`PhoneLink.push`), and the screen.
    private func push(_ change: WatchChange?) {
        link.push(state(change))
        refresh()
    }

    private func refresh() {
        recording = recorder.journal?.recording
        isCapturing = recorder.isCapturing
        isSending = held.contains { !$0.undelivered.isEmpty }
        isReachable = link.isReachable
    }

    /// The watch app's installation ID: its tracks' serial on the iPhone.
    private var watchID: String {
        if let id = defaults.string(forKey: Self.watchIDKey) { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: Self.watchIDKey)
        return id
    }

    private func saveFollowing() {
        if let data = try? JSONEncoder().encode(following) { defaults.set(data, forKey: Self.followingKey) }
    }
}
