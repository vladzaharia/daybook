#if DEBUG
import DaybookCaptions
import DaybookCore
import DaybookDevices
import DaybookKit
import DaybookLink
import Foundation

// The debug launch scripts (`DebugLaunch`): a scripted recording, a paired Mac, the simulated recorder
// added and importing, its handoff states, and a Mac's presence in a sync folder, for screenshots. Nothing
// here reaches the network or a real device, and none of it is in a release build.
extension PhoneAppModel {
    /// `--demo-ink`: typed paragraphs and handwriting in one note, one block already read and one left for the recognizer.
    func runInkDemo() async {
        try? await Task.sleep(for: .seconds(1))
        editNotes("Agenda: what the phone app records")
        addInk(NoteInk(drawing: SyntheticInk.drawing("hello world").dataRepresentation(), width: 440, height: 96, recognized: "hello world"), after: nil)
        editNotes(recorder.notes + "\nTyped again, right after the handwriting")
        addInk(NoteInk(drawing: SyntheticInk.drawing("world hello").dataRepresentation(), width: 440, height: 96), after: nil)
    }

    /// What the launch arguments ask for, once the library, sync, and the link are up.
    func runLaunchDemos() {
        if options.deviceAutopilot { runDeviceAutopilot() }
        if options.handoffDemo != nil || options.demoLiveCaptions || options.demoTransfer != nil { runStatusDemo() }
        if PhonePlacementDemo.scenario != nil { Task { await PhonePlacementDemo.apply(to: self) } }
        if PhoneUpgradeDemo.scenario != nil { Task { await PhoneUpgradeDemo.apply(to: self) } }
        Task {
            if options.startRecording, !recorder.isActive {
                try? await startRecording()
                runDemoScript()
                if options.demoInk { await runInkDemo() }
            }
            if let name = options.demoRecorderOnly, !recorder.isActive {
                // After the scene has come forward, which would otherwise record along at once.
                try? await Task.sleep(for: .seconds(1))
                multipoints.recorderOnly = RecorderOnlyRecording(conversationID: UUID(), title: Meeting.defaultTitle(),
                                                                 startedAt: Date(), recorderID: "demo", recorderName: name)
            }
        }
    }

    /// `--demo-notes`, `--simulate-interruption`, and `--stop-after`: a scripted recording for
    /// screenshots, with synthetic audio.
    func runDemoScript() {
        let notes = options.demoNotes
        let stopAfter = options.stopAfter
        let interruptAfter = options.interruptAfter
        if let mac = options.demoMultipointMac, let id = recorder.captureID {
            // The paired Mac `applyLinkDemo` made, so its chip is the one Mac recording along.
            let macID = link.macs.first { $0.name == mac }?.id ?? UUID()
            multipoints.session = MultipointSession(conversationID: id, role: .phoneLed,
                                                    macs: [MultipointSession.Mac(id: macID, name: mac, state: .recording, startedAt: Date(), startedByPhone: true)])
            updateActivity()
            if options.demoLevels { runLevelsDemo(from: macID, conversation: id) }
        }
        if options.demoLevels, options.deviceAutopilot, let id = recorder.captureID {
            // With the simulated recorder: once the autopilot has it, it records along, metered from its live audio.
            Task { [weak self] in
                for _ in 0..<300 {
                    if let session = self?.devices.sessions.first, session.isLinked, session.recorderSerial != nil { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard let self, self.recorder.captureID == id, let session = self.devices.sessions.first else { return }
                _ = await self.devices.cascade.start(session, for: id)
            }
        }
        demo = Task { [weak self] in
            if notes {
                let script: [(TimeInterval, String?)] = [
                    (2, "Agenda: what the phone app records, and what waits for the Mac."),
                    (2.5, nil),
                    (3, "Recording keeps going with the screen locked; calls pause it."),
                    (2.5, "Next: measure both iPhone Duo displays before fixing layout constants."),
                    (1.5, nil),
                ]
                var text = ""
                for (delay, line) in script {
                    try? await Task.sleep(for: .seconds(delay))
                    guard let self, !Task.isCancelled, self.recorder.isActive else { return }
                    if let line {
                        text += (text.isEmpty ? "" : "\n") + line
                        self.editNotes(text)
                    } else {
                        _ = try? await self.addBookmark()
                    }
                }
            }
            if let interruptAfter {
                try? await Task.sleep(for: .seconds(max(0, interruptAfter - (notes ? 11.5 : 0))))
                guard let self, !Task.isCancelled, self.recorder.isActive else { return }
                self.demoAudioSession?.send(.interruptionBegan(reason: nil))
                // The call ends four seconds later; iOS doesn't ask to resume, so Resume is offered.
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                self.demoAudioSession?.send(.interruptionEnded(shouldResume: false))
            }
            if let stopAfter {
                try? await Task.sleep(for: .seconds(max(0, stopAfter - (notes ? 11.5 : 0))))
                guard let self, !Task.isCancelled, self.recorder.isActive else { return }
                try? await self.stopRecording()
            }
        }
    }

    /// `--demo-levels`: the Mac recording along sends its level as the link would, a few readings about five times a
    /// second, as a stand-in conversation: the room through its microphone, softer than this iPhone hears it, and the
    /// call on its computer audio taking turns with it.
    private func runLevelsDemo(from mac: UUID, conversation: UUID) {
        Task { [weak self] in
            var tick = 0
            while let self, self.recorder.isActive, self.recorder.captureID == conversation {
                let values = (0..<3).map { offset -> Double in
                    let t = Double(tick + offset) / 15
                    let room = Self.demoSpeech(t, phase: 0.4) * 0.7, call = Self.demoSpeech(t, phase: 7.4)
                    return min(1, 0.04 + max(room, call))
                }
                tick += values.count
                let message = LinkLevels(conversationID: conversation, values: values, interval: PhoneRecorder.levelInterval)
                self.sharing.macLevelled(message, from: mac)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    /// Syllables in phrases, taking turns: a deterministic stand-in for speech, as Floating Notes' simulated meters draw it.
    private static func demoSpeech(_ t: Double, phase: Double) -> Double {
        let turn = sin((t + phase) * 0.45) > -0.2 ? 1.0 : 0.15
        let phrase = sin((t + phase) * 1.3) > -0.55 ? 1.0 : 0.1
        let syllable = abs(sin((t + phase) * 7.7)) * (0.6 + 0.4 * abs(sin((t + phase) * 2.9 + 0.7)))
        return min(1, 0.06 + turn * phrase * (0.25 + 0.7 * syllable))
    }

    /// `--demo-link`: paired Macs and a Mac to pair with, with nothing on the network.
    func applyLinkDemo() {
        var studio = PhoneLink.Mac(id: UUID(), name: options.demoMultipointMac ?? "Studio Mac", pairedAt: Date().addingTimeInterval(-86_400 * 12),
                                   state: .connected, canProcess: true, appVersion: "1.0",
                                   clock: LinkClockEstimate(offset: 0.012, roundTrip: 0.008, sampleCount: 6, measuredAt: Date()),
                                   lastConnectedAt: Date())
        studio.handsOffRecorders = true
        // `--demo-levels`: a Mac that sends its level, so the recorder gives it a meter.
        studio.sendsLevels = options.demoLevels
        let laptop = PhoneLink.Mac(id: UUID(), name: "MacBook Air", pairedAt: Date().addingTimeInterval(-86_400 * 40),
                                   state: .idle, canProcess: false, lastConnectedAt: Date().addingTimeInterval(-3 * 86_400))
        let progress = library.conversations.first.map {
            LiveProgress(LinkProcessingProgress(meetingID: $0.id, phase: .transcribing, fraction: 0.4, macName: studio.name))
        }
        let office = PhoneLink.PairingCandidate(id: "Office iMac", name: "Office iMac", endpoint: LinkEndpoint(host: "192.0.2.10", port: 7000),
                                                isPairing: true, isPaired: false, sharesLibrary: true)
        link.applyDemo(macs: options.demoMultipointMac != nil ? [studio] : [studio, laptop],
                       candidates: [office], progress: progress.map { [$0] } ?? [])
    }

    /// `--device-autopilot`: Add Device › Soundcore Work against the simulated recorder, connect,
    /// and import what it holds, as a person would.
    private func runDeviceAutopilot() {
        Task { [weak self] in
            guard let self, let kind = DeviceCatalog.kind(SoundcoreWorkIntegration.id) else { return }
            guard self.devices.sessions.isEmpty, let session = self.devices.beginSetup(kind),
                  let soundcore = session.direct as? SoundcoreConnection else { return }
            soundcore.search()
            for _ in 0..<100 where soundcore.discovered.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
            guard let recorder = soundcore.discovered.first else { return }
            soundcore.connect(to: recorder)
            for _ in 0..<100 where !soundcore.state.isConnected { try? await Task.sleep(for: .milliseconds(100)) }
            guard soundcore.state.isConnected else { return }
            self.devices.commitSetup()
            for _ in 0..<50 where session.newRecordings.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
            session.importRecordings(Array(session.newRecordings.prefix(1)), automatic: true)
        }
    }

    /// `--handoff-demo <state>` and `--demo-live-captions`, after the device autopilot has set up
    /// the simulated recorder: a recorder handoff state, or the recorder recording and streaming
    /// scripted captions, for screenshots. Nothing reaches the network.
    private func runStatusDemo() {
        Task { [weak self] in
            guard let self else { return }
            for _ in 0..<300 {
                if let session = self.devices.sessions.first, session.isLinked, session.recorderSerial != nil, !session.links.recent.isEmpty { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let session = self.devices.sessions.first, let serial = session.recorderSerial else { return }
            if self.options.demoLiveCaptions, let soundcore = session.direct as? SoundcoreConnection {
                soundcore.startRecording()
                for _ in 0..<50 where session.status?.isRecording != true { try? await Task.sleep(for: .milliseconds(100)) }
                let lines = ["So the launch moves to the 14th, and Priya owns the checklist.",
                             "We still need legal to sign off on the pricing page before Friday.",
                             "Can someone check the date with the venue"]
                soundcore.live.isListening = true
                soundcore.live.captionState = .listening
                soundcore.live.receivedSeconds = 236
                for index in lines.indices {
                    // Demo captions: the earlier lines final, the newest still tentative.
                    soundcore.live.captions = lines.prefix(index + 1).enumerated().map { offset, line in
                        LiveCaptionSegment(start: Double(offset) * 4, end: Double(offset) * 4 + 3.5, text: line,
                                           isTentative: offset == index)
                    }
                    try? await Task.sleep(for: .seconds(1.5))
                }
            }
            if let demo = self.options.demoTransfer, let recorder = self.devices.simulatedRecorder,
               let next = session.newRecordings.first, let id = UInt32(next.id) {
                // Slow enough to see: the import over Wi‑Fi, or another app's long transfer it waits for.
                recorder.pace = .milliseconds(400)
                if demo == .otherApp {
                    recorder.beginAnotherAppsTransfer(recordingID: id &+ 1, slices: 30_000, pace: .milliseconds(60))
                    try? await Task.sleep(for: .milliseconds(300))
                }
                // Held where iOS would ask to join the recorder's network, for what the page says meanwhile.
                if demo == .joining { self.devices.simulatedHotspot?.answersAfter = .seconds(600) }
                session.importRecordings([next], automatic: true, overWiFi: demo == .wifi || demo == .joining)
            }
            guard let state = self.options.handoffDemo else { return }
            let mac = ProcessingRequest.Device(id: "demo-studio-mac", name: "Studio Mac")
            if state.startsManagedByMac {
                self.library.controller.claimRecorder(kind: session.kind.id, serial: serial, deviceClass: .mac, by: mac)
                self.devices.applyOwnership()
                // This iPhone lets go first (it was taken over); the demo state goes on top of that.
                for _ in 0..<60 where session.isLinked || session.isHandingOff { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .milliseconds(600))
            }
            let now = Date()
            let demo: RecorderHandoff.State
            switch state {
            case .asking: demo = .asking(owner: mac.name)
            case .finishing: demo = .ownerFinishing(owner: mac.name, finishing: .importing(title: "Today, 10:02 AM", secondsLeft: 140))
            case .waiting: demo = .waitingForSync(owner: mac.name, since: now.addingTimeInterval(-20))
            case .overdue: demo = .waitingForSync(owner: mac.name, since: now.addingTimeInterval(-14 * 60))
            case .refused: demo = .refused(by: mac.name, message: "Studio Mac is already handing Soundcore Work to another device.")
            case .connecting: demo = .connecting(from: mac.name)
            case .done: demo = .done(at: now)
            case .handing: demo = .handingOver(to: mac.name, finishing: .importing(title: "Today, 10:02 AM", secondsLeft: 140))
            case .managed: demo = .idle
            }
            try? await Task.sleep(for: .milliseconds(400))
            self.devices.handoff.applyDemo(demo, for: session)
        }
    }

    /// `--demo-mac`: a Mac's presence record in the sync folder (DaybookCore's `SyncPresenceRecord`), as if
    /// it last synced `hoursAgo` hours ago.
    static func writeDemoPresence(name: String, hoursAgo: Double, in folder: URL) {
        let deviceID = "demo-mac-" + name.lowercased().filter { $0.isLetter || $0.isNumber }
        try? SyncPresenceRecord.write(deviceID: deviceID, displayName: name, deviceClass: .mac, canProcess: true, audioPolicy: .eager,
                                      lastSeen: Date().addingTimeInterval(-hoursAgo * 3_600), intoSyncFolder: folder)
    }
}
#endif
