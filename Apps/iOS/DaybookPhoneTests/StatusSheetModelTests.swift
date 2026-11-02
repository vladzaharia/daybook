import DaybookDesign
import DaybookKit
import DaybookLink
import DaybookUI
import SwiftUI
import XCTest
@testable import DaybookPhone

/// The status sheet's view model (docs/iphone.md, "Status sheet"): what each line says in each
/// state, and what each detent shows.
@MainActor
final class StatusSheetModelTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func recorder(_ change: (inout StatusInputs.Recorder) -> Void = { _ in }) -> StatusInputs.Recorder {
        var recorder = StatusInputs.Recorder(id: "sc", name: "Soundcore Work", shortName: "Soundcore", isDirect: true,
                                             state: .connected, isLinked: true, batteryLevel: 80)
        change(&recorder)
        return recorder
    }

    private func line(_ recorder: StatusInputs.Recorder?) -> StatusLineItem { StatusSheetModel.recorderLine(recorder, now: now) }

    // MARK: The recorder line

    func testARecorderThatIsntLiveHereSaysWhatItWasLastKnownToDo() {
        let managed = line(recorder { $0.managedBy = "Studio Mac"; $0.isLinked = false; $0.state = .notConnected
            $0.lastKnown = "Recording since 10:02, as of 10:14" })
        XCTAssertEqual(managed.text, "Managed by Studio Mac · Recording since 10:02, as of 10:14")
        XCTAssertEqual(line(recorder { $0.managedBy = "Studio Mac"; $0.isLinked = false }).text, "Managed by Studio Mac",
                       "nothing said, or too old to say")
        let away = line(recorder { $0.isLinked = false; $0.state = .notConnected; $0.lastKnown = "Not recording, as of 10:14" })
        XCTAssertEqual(away.text, "Not recording, as of 10:14")
        XCTAssertEqual(away.tone, .calm)

        // What it says is shown with its age, then not at all.
        let asOf = Date()
        let state = LinkRecorderState(kind: "soundcore.work", isRecording: true, startedAt: asOf.addingTimeInterval(-600), asOf: asOf)
        XCTAssertEqual(state.summary(now: asOf), "Recording since \(asOf.addingTimeInterval(-600).formatted(date: .omitted, time: .shortened))")
        XCTAssertTrue(state.summary(now: asOf.addingTimeInterval(120))?.hasSuffix("as of \(asOf.formatted(date: .omitted, time: .shortened))") == true)
        XCTAssertNil(state.summary(now: asOf.addingTimeInterval(21 * 60)))
    }

    func testRecorderLineSaysWhatTheRecorderIsDoing() {
        XCTAssertEqual(line(nil).text, "None added")
        XCTAssertEqual(line(nil).tone, .calm)

        let connected = line(recorder { $0.newCount = 2 })
        XCTAssertEqual(connected.title, "Soundcore Work")
        XCTAssertEqual(connected.text, "Connected · 80% · 2 new")
        XCTAssertEqual(connected.tone, .linked)

        XCTAssertEqual(line(recorder { $0.batteryCharging = true }).text, "Connected · 80%, charging")
        let recording = line(recorder { $0.isRecording = true })
        XCTAssertEqual(recording.text, "Recording · 80%")
        XCTAssertEqual(recording.tone, .recording, "the red dot: recording right now")

        // Too narrow for all of it, the line keeps what matters instead of cutting the end off.
        XCTAssertEqual(connected.shortText, "80% · 2 new", "a battery level and new recordings say it's connected")
        XCTAssertEqual(line(recorder { $0.batteryCharging = true; $0.newCount = 1 }).shortText, "80%, charging · 1 new")
        XCTAssertEqual(line(recorder { $0.isRecording = true; $0.newCount = 2 }).text, "Recording · 80% · 2 new")
        XCTAssertEqual(line(recorder { $0.isRecording = true; $0.newCount = 2 }).shortText, "Recording · 80%")
        XCTAssertNil(recording.shortText, "nothing to drop")
        XCTAssertNil(line(recorder { $0.batteryLevel = nil }).shortText, "Connected alone stays")

        let importing = line(recorder { $0.importing = .init(position: 1, total: 3, fraction: 0.25) })
        XCTAssertEqual(importing.text, "Importing 1 of 3")
        XCTAssertEqual(importing.tone, .working)
        XCTAssertEqual(importing.progress, 0.25)
        XCTAssertEqual(line(recorder { $0.importing = .init(position: 1, total: 2, fraction: nil, suspended: true); $0.isLinked = false; $0.state = .notConnected }).text,
                       "2 recordings wait to import")

        XCTAssertEqual(line(recorder { $0.isListeningLive = true }).text, "Listening live")
        XCTAssertEqual(line(recorder { $0.state = .connecting; $0.isLinked = false }).text, "Connecting…")

        let away = line(recorder { $0.state = .notConnected; $0.isLinked = false; $0.newCount = 1; $0.lastConnected = now.addingTimeInterval(-60) })
        XCTAssertTrue(away.text.hasPrefix("1 new · Last seen today"), away.text)
        XCTAssertEqual(line(recorder { $0.state = .notConnected; $0.isLinked = false }).text, "Not connected")

        let problem = line(recorder { $0.state = .unavailable; $0.isLinked = false; $0.problem = "Bluetooth is off" })
        XCTAssertEqual(problem.text, "Bluetooth is off")
        XCTAssertEqual(problem.tone, .attention)
    }

    /// The Soundcore app transferring over the link iOS shares: Daybook's import waits, and the line says so
    /// in place of "Importing 1 of 3".
    func testRecorderLineSaysAnImportWaitsForTheSoundcoreApp() {
        let waiting = line(recorder {
            $0.importing = .init(position: 1, total: 3, fraction: 0)
            $0.otherAppWait = "Waiting for the Soundcore app to finish"
        })
        XCTAssertEqual(waiting.text, "Waiting for the Soundcore app to finish")
        XCTAssertEqual(waiting.tone, .working)
        XCTAssertEqual(waiting.shortText, "Waiting…")
    }

    /// Over the recorder's Wi‑Fi, leaving Daybook starts the transfer again over Bluetooth: the compact line says to
    /// keep Daybook open, also where it's narrow.
    func testBehaviorTheRecorderLineSaysToKeepDaybookOpenDuringFastTransfer() {
        let starting = line(recorder {
            $0.importing = .init(position: 1, total: 1, fraction: 0)
            $0.fastTransfer = .starting
        })
        XCTAssertEqual(starting.text, "Importing · Starting Wi‑Fi…")
        XCTAssertEqual(starting.shortText, "Starting Wi‑Fi…")
        let joining = line(recorder {
            $0.importing = .init(position: 1, total: 1, fraction: 0)
            $0.fastTransfer = .joining(recorder: "Soundcore Work")
        })
        XCTAssertEqual(joining.text, "Importing · Joining Wi‑Fi…")
        XCTAssertEqual(joining.shortText, "Joining Wi‑Fi…")
        let transferring = line(recorder {
            $0.importing = .init(position: 1, total: 1, fraction: 0.64)
            $0.fastTransfer = .transferring
        })
        XCTAssertEqual(transferring.text, "Importing · 64% · Keep Daybook open")
        XCTAssertEqual(transferring.shortText, "Keep Daybook open")
        XCTAssertEqual(transferring.progress, 0.64)
    }

    func testRecorderLineForOwnershipAndHandoff() {
        let managed = line(recorder { $0.managedBy = "Studio Mac"; $0.isLinked = false; $0.state = .notConnected })
        XCTAssertEqual(managed.text, "Managed by Studio Mac")
        XCTAssertEqual(managed.tone, .calm)

        func handoff(_ state: RecorderHandoff.State) -> StatusLineItem { line(recorder { $0.managedBy = "Studio Mac"; $0.handoff = state }) }
        XCTAssertEqual(handoff(.asking(owner: "Studio Mac")).text, "Asking Studio Mac to let go…")
        XCTAssertEqual(handoff(.asking(owner: "Studio Mac")).shortText, "Asking Studio Mac…")
        let finishing = handoff(.ownerFinishing(owner: "Studio Mac", finishing: .importing(title: "Today, 10:02 AM", secondsLeft: 90)))
        XCTAssertEqual(finishing.text, "Studio Mac finishes an import, then lets go")
        XCTAssertEqual(finishing.shortText, "Moving here after an import")
        XCTAssertEqual(handoff(.ownerFinishing(owner: "Studio Mac", finishing: nil)).text, "Studio Mac is letting go…")
        let waiting = handoff(.waitingForSync(owner: "Studio Mac", since: now))
        XCTAssertEqual(waiting.text, "Waiting for Studio Mac to let go…", "honest about who it waits for")
        XCTAssertEqual(waiting.shortText, "Waiting for Studio Mac…")
        XCTAssertEqual(waiting.tone, .working)
        XCTAssertEqual(handoff(.connecting(from: "Studio Mac")).text, "Connecting…")
        XCTAssertEqual(handoff(.done(at: now)).text, "On this iPhone now")
        XCTAssertEqual(handoff(.done(at: now)).tone, .linked)
        let refused = handoff(.refused(by: "Studio Mac", message: "No."))
        XCTAssertEqual(refused.text, "Studio Mac didn’t hand it over")
        XCTAssertEqual(refused.tone, .attention)
        XCTAssertEqual(line(recorder { $0.handoff = .handingOver(to: "Studio Mac", finishing: nil) }).text, "Moving to Studio Mac…")
        XCTAssertEqual(line(recorder { $0.handoff = .offering(to: "Studio Mac") }).text, "Asking Studio Mac to take it…")
    }

    func testTheCompactLineFollowsTheRecorderThatIsBusy() {
        let idle = recorder { $0.id = "a"; $0.name = "Soundcore Work" }
        let busy = recorder { $0.id = "b"; $0.name = "Soundcore Work 2"; $0.importing = .init(position: 1, total: 1, fraction: 0.5) }
        XCTAssertEqual(StatusSheetModel.primaryRecorder([idle, busy])?.id, "b")
        XCTAssertEqual(StatusSheetModel.primaryRecorder([idle])?.id, "a")
    }

    // MARK: The Mac line

    func testMacLineShowsLiveProgressPresenceAndWaitingWork() {
        var inputs = StatusInputs()
        inputs.mac = .connected(name: "Studio Mac")
        inputs.liveProgress = [LiveProgress(LinkProcessingProgress(meetingID: UUID(), phase: .transcribing, fraction: 0.4, macName: "Studio Mac"))]
        let transcribing = StatusSheetModel.macLine(inputs, now: now)
        XCTAssertEqual(transcribing.title, "Studio Mac")
        XCTAssertEqual(transcribing.text, "Transcribing · 40%")
        XCTAssertEqual(transcribing.progress, 0.4)
        XCTAssertEqual(transcribing.tone, .working)
        XCTAssertEqual(transcribing.shortText, "Transcribing", "the gradient line shows how far")

        inputs.liveProgress = [LiveProgress(LinkProcessingProgress(meetingID: UUID(), phase: .failed, macName: "Studio Mac", detail: "Out of space"))]
        XCTAssertEqual(StatusSheetModel.macLine(inputs, now: now).tone, .attention)

        inputs.liveProgress = []
        inputs.queue = [StatusQueueEntry(id: UUID(), title: "A", line: "Waiting", requestedHere: true, progress: nil, isRunning: false),
                        StatusQueueEntry(id: UUID(), title: "B", line: "Waiting", requestedHere: false, progress: nil, isRunning: false)]
        XCTAssertEqual(StatusSheetModel.macLine(inputs, now: now).text, "Connected · 2 waiting")
        XCTAssertEqual(StatusSheetModel.macLine(inputs, now: now).tone, .linked)
        // Narrow (a long Mac name), the waiting work stays rather than being cut off.
        XCTAssertEqual(StatusSheetModel.macLine(inputs, now: now).shortText, "2 waiting")

        inputs.queue = []
        XCTAssertNil(StatusSheetModel.macLine(inputs, now: now).shortText, "Connected alone stays")
        inputs.mac = .seen(name: "Studio Mac", lastSeen: now.addingTimeInterval(-7_200))
        XCTAssertEqual(StatusSheetModel.macLine(inputs, now: now).text, RecorderStatusWords.lastSeen(now.addingTimeInterval(-7_200), now: now),
                       "dated as every device's absence is")
        XCTAssertTrue(StatusSheetModel.macLine(inputs, now: now).text.hasPrefix("Last seen today"))
        inputs.mac = .noMac
        XCTAssertEqual(StatusSheetModel.macLine(inputs, now: now).text, "Hasn’t synced this library yet")
        inputs.mac = .unavailable("iCloud is off")
        XCTAssertEqual(StatusSheetModel.macLine(inputs, now: now).text, "Needs iCloud", "the iCloud line below says why")
        XCTAssertEqual(StatusSheetModel.macLine(inputs, now: now).tone, .calm)
        inputs.mac = .checking
        XCTAssertEqual(StatusSheetModel.macLine(inputs, now: now).text, "Looking for it…")

        // Coarse progress from a synced claim, when the link has nothing.
        inputs.mac = .seen(name: "Studio Mac", lastSeen: now)
        inputs.queue = [StatusQueueEntry(id: UUID(), title: "A", line: "Summarizing on Studio Mac · 60%", requestedHere: false, progress: 0.6, isRunning: true)]
        XCTAssertEqual(StatusSheetModel.macLine(inputs, now: now).text, "Summarizing · 60%")
    }

    func testMacLineCountsDownWithAMacsCountdownOrThisIPhonesToAMac() {
        var inputs = StatusInputs()
        inputs.mac = .connected(name: "Studio Mac")
        let id = UUID()
        inputs.liveProgress = [LiveProgress(LinkProcessingProgress(meetingID: id, phase: .summaryCountdown, macName: "Studio Mac",
                                                                   countdown: LinkSummaryCountdown(secondsLeft: 12, cloudOffered: true)), receivedAt: now)]
        let mac = StatusSheetModel.macLine(inputs, now: now)
        XCTAssertEqual(mac.title, "Studio Mac")
        XCTAssertEqual(mac.text, "Summarizing in 12 s")
        XCTAssertEqual(mac.countdownUntil, now.addingTimeInterval(12))
        XCTAssertEqual(mac.text(at: now.addingTimeInterval(3)), "Summarizing in 9 s", "it ticks")
        XCTAssertEqual(mac.tone, .calm, "waiting isn't progress: calm, as the Mac's own countdown is")

        // This iPhone counting down to sending one to Studio Mac.
        inputs.liveProgress = []
        var entry = StatusQueueEntry(id: id, title: "A", line: "Summarizing on Studio Mac in 15 s", requestedHere: false, progress: nil,
                                     isRunning: false, countdownUntil: now.addingTimeInterval(15))
        entry.isRunning = true
        entry.mac = "Studio Mac"
        entry.countdownPlace = "on Studio Mac"
        inputs.queue = [entry]
        XCTAssertEqual(StatusSheetModel.macLine(inputs, now: now).text, "Summarizing in 15 s")
        XCTAssertEqual(StatusSheetModel.macLine(inputs, now: now).text(at: now.addingTimeInterval(5)), "Summarizing in 10 s")
        XCTAssertEqual(StatusSheetModel.macLine(inputs, now: now).tone, .calm)
        // Counting down to summarizing on this iPhone: nothing for the Mac's line.
        entry.mac = nil
        entry.countdownPlace = "on this iPhone"
        inputs.queue = [entry]
        XCTAssertEqual(StatusSheetModel.macLine(inputs, now: now).text, "Connected")
    }

    func testSyncLineTone() {
        var inputs = StatusInputs()
        inputs.syncLine = "Up to date"; inputs.syncTone = .upToDate
        XCTAssertEqual(StatusSheetModel.syncLine(inputs).tone, .calm)
        inputs.syncTone = .working
        XCTAssertEqual(StatusSheetModel.syncLine(inputs).tone, .working)
        inputs.syncTone = .attention
        XCTAssertEqual(StatusSheetModel.syncLine(inputs).tone, .attention)
        XCTAssertEqual(StatusSheetModel.syncLine(inputs).symbol, "exclamationmark.icloud")
        XCTAssertEqual(StatusSheetModel.lines(inputs, now: now).map(\.id), ["recorder", "mac", "sync"])
    }

    // MARK: Detents

    func testEachDetentAddsToTheOneBefore() {
        var inputs = StatusInputs()
        inputs.recorders = [recorder { $0.newCount = 1 }]
        inputs.hostsRecordButton = true
        XCTAssertEqual(StatusSheetModel.sections(for: .compact, inputs), [.quickActions, .lines])
        // At most three groups below the lines, each a heading and one card.
        XCTAssertEqual(StatusSheetModel.sections(for: .medium, inputs), [.quickActions, .lines, .recorders, .macs])
        XCTAssertEqual(StatusSheetModel.sections(for: .large, inputs), [.quickActions, .lines, .recorders, .macs, .iphone])
        XCTAssertFalse(StatusSheetModel.showsManagement(.medium))
        XCTAssertTrue(StatusSheetModel.showsManagement(.large), "the recorder cards grow their storage, actions, and waiting recordings")

        // The notebook's panel doesn't repeat Record: it's at the foot of the left page.
        inputs.hostsRecordButton = false
        XCTAssertEqual(StatusSheetModel.sections(for: .compact, inputs), [.lines])

        // Live captions appear at medium only while a recorder streams.
        inputs.hasLiveCaptions = true
        XCTAssertEqual(StatusSheetModel.sections(for: .medium, inputs), [.lines, .captions, .recorders, .macs])
        XCTAssertEqual(StatusSheetModel.sections(for: .compact, inputs), [.lines])

        // With no recorder, the group still offers Add Recorder….
        inputs.hasLiveCaptions = false
        inputs.recorders = []
        XCTAssertEqual(StatusSheetModel.sections(for: .large, inputs), [.lines, .recorders, .macs, .iphone])

        // This iPhone's own work shows from medium on, in its card.
        inputs.phone = QueueStatusWords.Queue(running: .transcribing, fraction: 0.4)
        XCTAssertEqual(StatusSheetModel.sections(for: .medium, inputs), [.lines, .recorders, .macs, .iphone])
        XCTAssertEqual(StatusSheetModel.sections(for: .compact, inputs), [.lines])
        XCTAssertEqual(StatusDetent.compact.density, .lines)
        XCTAssertEqual(StatusDetent.medium.density, .cards)
        XCTAssertEqual(StatusDetent.large.density, .manage)
    }

    // MARK: A recorder's card

    func testARecorderOffersOnlyWhatItCanDoNow() {
        func actions(_ change: (inout StatusInputs.Recorder) -> Void) -> [StatusRecorderAction] {
            StatusSheetModel.actions(for: recorder { $0.hasRecordControl = true; $0.hasLiveListening = true; change(&$0) })
        }
        // Idle with nothing new: Record only. No "Nothing New to Import", no Listen Live until it records.
        XCTAssertEqual(actions { _ in }, [.record])
        XCTAssertEqual(actions { $0.newCount = 2 }, [.record, .importNew(2)])
        XCTAssertEqual(actions { $0.isRecording = true }, [.pause, .listenLive])
        XCTAssertEqual(actions { $0.isRecording = true; $0.isListeningLive = true }, [.pause, .stopListening])

        // While a recording comes off it, neither Record nor Import; Stop Listening stays.
        XCTAssertEqual(actions { $0.newCount = 2; $0.importing = .init(position: 1, total: 2, fraction: 0.3); $0.importRunning = true }, [])
        XCTAssertEqual(actions { $0.isListeningLive = true; $0.importing = .init(position: 1, total: 1, fraction: 0.3); $0.importRunning = true },
                       [.stopListening])

        // Away: Connect when it would do something, and new recordings can still be queued.
        XCTAssertEqual(actions { $0.isLinked = false; $0.state = .notConnected; $0.canConnect = true; $0.newCount = 1 }, [.connect, .importNew(1)])
        XCTAssertEqual(actions { $0.isLinked = false; $0.state = .connecting }, [], "nothing disabled: Connecting… is on its line")

        // Another device manages it, or it has no Bluetooth: nothing here.
        XCTAssertEqual(actions { $0.managedBy = "Studio Mac"; $0.isLinked = false }, [])
        XCTAssertEqual(actions { $0.isDirect = false; $0.newCount = 3 }, [])
        // On its way between devices: the handoff says what's happening, as on its page.
        XCTAssertEqual(actions { $0.handoff = .offering(to: "Studio Mac"); $0.newCount = 1 }, [])
        XCTAssertEqual(actions { $0.isLinked = false; $0.state = .notConnected; $0.canConnect = true; $0.handoff = .asking(owner: "Studio Mac") }, [])
        XCTAssertEqual(StatusSheetModel.actions(for: recorder { $0.newCount = 1 }), [.importNew(1)], "no record control, no Record")

        // Connected, but it didn't list its recordings (another app was using it): Check for New, not "nothing new".
        XCTAssertEqual(actions { $0.notListed = true }, [.record, .checkForNew])
        XCTAssertEqual(actions { $0.notListed = true; $0.newCount = 1 }, [.record, .importNew(1), .checkForNew], "remembered ones still import")
        XCTAssertEqual(actions { $0.notListed = true; $0.importing = .init(position: 1, total: 1, fraction: 0.1); $0.importRunning = true }, [])
    }

    func testARecordersStorageReadsTheWayPeopleSayIt() {
        XCTAssertEqual(StatusSheetModel.storageLeft(hours: 2_172), "About \(2_170.formatted()) hours left", "grouped: 2,170")
        XCTAssertEqual(StatusSheetModel.storageLeft(hours: 6.2), "About 6 hours left")
        XCTAssertEqual(StatusSheetModel.storageLeft(hours: 1.1), "About 1 hour left")
        XCTAssertEqual(StatusSheetModel.storageLeft(hours: 0.4), "Less than an hour left")
    }

    // MARK: The Macs card

    func testEachMacIsOneRowAndTheQueueGoesUnderTheMacDoingIt() {
        let studio = UUID(), air = UUID()
        var inputs = StatusInputs()
        inputs.pairedMacs = [StatusInputs.Mac(id: air, name: "MacBook Air", line: "Last connected 3 days ago", isConnected: false),
                             StatusInputs.Mac(id: studio, name: "Vlad’s MacBook Pro (755)", line: "Connected", isConnected: true)]
        inputs.mac = .connected(name: "Vlad’s MacBook Pro (755)")
        let rows = StatusSheetModel.macRows(inputs, now: now)
        XCTAssertEqual(rows.map(\.id), [.paired(air), .paired(studio)], "the Mac in the line isn't added twice")
        XCTAssertEqual(rows.map(\.showsQueue), [false, true], "under the connected Mac")
        XCTAssertEqual(rows[1].text, "Connected")

        // Not connected: under the Mac presence names.
        inputs.pairedMacs[1].isConnected = false
        inputs.mac = .seen(name: "Vlad’s MacBook Pro (755)", lastSeen: now.addingTimeInterval(-7_200))
        XCTAssertEqual(StatusSheetModel.macRows(inputs, now: now).map(\.showsQueue), [false, true])

        // A Mac that syncs this library but isn't paired here: a row of its own, from its presence.
        inputs.pairedMacs = []
        inputs.mac = .seen(name: "Studio Mac", lastSeen: now.addingTimeInterval(-7_200))
        let synced = StatusSheetModel.macRows(inputs, now: now)
        XCTAssertEqual(synced, [StatusMacRow(id: .synced("Studio Mac"), name: "Studio Mac",
                                             text: RecorderStatusWords.lastSeen(now.addingTimeInterval(-7_200), now: now), isConnected: false,
                                             showsQueue: true)])

        // No Mac at all: no rows (the card has only Pair with Your Mac…).
        inputs.mac = .noMac
        XCTAssertEqual(StatusSheetModel.macRows(inputs, now: now), [])
    }

    func testQueueListsConversationsWaitingForARecording() {
        let studio = ProcessingRequest.Device(id: "studio", name: "Studio Mac")
        func awaiting(_ title: String, ended: TimeInterval) -> Meeting {
            let mac = UUID()
            var meeting = Meeting(title: title, tracks: [RecordingTrack(id: mac, source: .microphone, relativePath: "m.caf", fileName: "m.caf",
                                                                        offset: 0, sha256: title)],
                                  transcripts: [TrackTranscript(trackID: mac, segments: [])], summary: MeetingSummary(overview: "Hi"))
            var link = CompanionRecording(deviceID: "sc", deviceKind: "soundcore.work", deviceName: "Soundcore Work",
                                          macStartedAt: now.addingTimeInterval(ended - 600), state: .stopped, startedByDaybook: true)
            link.macEndedAt = now.addingTimeInterval(ended)
            link.recordingID = "1800000000"
            meeting.companions = [link]
            return meeting
        }
        var waiting = Meeting(title: "Asked")
        waiting.processingRequests = [ProcessingRequest(meetingID: waiting.id, mode: .newAudio, requestedBy: studio, createdAt: now)]
        let failedRequest = ProcessingRequest(meetingID: UUID(), mode: .newAudio, requestedBy: studio, createdAt: now.addingTimeInterval(-3_000))
            .failed(by: studio, at: now.addingTimeInterval(-2_000), reason: "Out of memory")
        var failed = Meeting(title: "Failed")
        failed.processingRequests = [failedRequest].compactMap { $0 }
        let queue = StatusSheetModel.queue(meetings: [failed, awaiting("Newer", ended: -60), waiting, awaiting("Older", ended: -600)],
                                           liveProgress: [:], thisDevice: "this-phone", now: now)
        XCTAssertEqual(queue.map(\.title), ["Asked", "Older", "Newer", "Failed"], "after the requests waiting, oldest first")
        XCTAssertEqual(queue[1].line, "Waiting for Soundcore Work audio")
        XCTAssertEqual(queue[1].line(under: "Studio Mac"), "Waiting for Soundcore Work audio")
        XCTAssertTrue(queue[1].awaitsRecording)
        XCTAssertFalse(queue[1].requestedHere)
        // They wait for the recorder, not the Mac: its line counts only what it has to do.
        var inputs = StatusInputs()
        inputs.mac = .connected(name: "Studio Mac")
        inputs.queue = queue
        XCTAssertEqual(StatusSheetModel.macLine(inputs, now: now).text, "Connected · 1 waiting")
    }

    func testAConversationUnderItsMacDoesntNameItAgain() {
        let entry = StatusQueueEntry(id: UUID(), title: "A", line: "Transcribing on Studio Mac · 40%", requestedHere: false,
                                     progress: 0.4, isRunning: true, mac: "Studio Mac", brief: "Transcribing · 40%")
        XCTAssertEqual(entry.line(under: "Studio Mac"), "Transcribing · 40%")
        XCTAssertEqual(entry.line(under: "MacBook Air"), "Transcribing on Studio Mac · 40%", "another Mac's work keeps its name")
        XCTAssertEqual(entry.line(under: nil), "Transcribing on Studio Mac · 40%")

        let live = LiveProgress(LinkProcessingProgress(meetingID: UUID(), phase: .summarizing, fraction: 0.5, macName: "Studio Mac"))
        XCTAssertEqual(live.brief, "Summarizing · 50%")
        XCTAssertEqual(LiveProgress(LinkProcessingProgress(meetingID: UUID(), phase: .failed, macName: "Studio Mac")).brief, "Couldn’t finish")
    }

    func testThisIPhonesDownloadedAudio() {
        // Downloads and recordings made here together, in Settings' words.
        XCTAssertEqual(StatusSheetModel.audioOnThisIPhone(bytes: 0), "No audio on this iPhone")
        XCTAssertEqual(StatusSheetModel.audioOnThisIPhone(bytes: 1_200_000_000),
                       "\(ByteCountFormatter.string(fromByteCount: 1_200_000_000, countStyle: .file)) of audio")
    }

    // MARK: The Mac's queue

    func testQueueListsWorkInOrderAndWhatThisIPhoneAskedFor() {
        let phone = ProcessingRequest.Device(id: "this-phone", name: "Alex’s iPhone")
        let studio = ProcessingRequest.Device(id: "studio", name: "Studio Mac")
        func meeting(_ title: String, _ request: ProcessingRequest?, status: MeetingStatus = .imported) -> Meeting {
            var meeting = Meeting(title: title)
            meeting.status = status
            if var request {
                request.meetingID = meeting.id
                meeting.processingRequests = [request]
            }
            return meeting
        }
        let waitingOld = meeting("Older", ProcessingRequest(meetingID: UUID(), mode: .newAudio, requestedBy: phone, createdAt: now.addingTimeInterval(-600)))
        let waitingNew = meeting("Newer", ProcessingRequest(meetingID: UUID(), mode: .newAudio, requestedBy: studio, createdAt: now.addingTimeInterval(-60)))
        let claimed = ProcessingRequest(meetingID: UUID(), mode: .newAudio, requestedBy: phone, createdAt: now.addingTimeInterval(-900))
            .claimed(by: studio, at: now.addingTimeInterval(-30))?
            .renewed(by: studio, at: now.addingTimeInterval(-10), stage: .transcribing, fraction: 0.4)
        let running = meeting("Running", claimed)
        let failedRequest = ProcessingRequest(meetingID: UUID(), mode: .newAudio, requestedBy: phone, createdAt: now.addingTimeInterval(-3_000))
            .failed(by: studio, at: now.addingTimeInterval(-2_000), reason: "No speech was recognized.")
        let failed = meeting("Failed", failedRequest)
        let live = meeting("Live", ProcessingRequest(meetingID: UUID(), mode: .newAudio, requestedBy: phone, createdAt: now))
        let progress = [live.id: LiveProgress(LinkProcessingProgress(meetingID: live.id, phase: .summarizing, fraction: 0.5, macName: "Studio Mac"))]

        let queue = StatusSheetModel.queue(meetings: [waitingNew, failed, waitingOld, running, live], liveProgress: progress,
                                           thisDevice: phone.id, now: now)
        XCTAssertEqual(queue.map(\.title), ["Running", "Live", "Older", "Newer"],
                       "no speech is final: its row and page say it, the queue doesn't keep it")
        XCTAssertEqual(queue[0].line, "Transcribing on Studio Mac · 40%")
        XCTAssertTrue(queue[0].isRunning)
        XCTAssertEqual(queue[1].line, "Summarizing on Studio Mac · 50%", "live progress over the link wins")
        XCTAssertEqual(queue[2].line, "Waiting")
        XCTAssertTrue(queue[2].requestedHere, "“Requested from this iPhone”")
        XCTAssertEqual(queue[2].item(under: "Studio Mac").note, "Requested from this iPhone")
        XCTAssertFalse(queue[3].requestedHere)
        // Under Studio Mac's row in the Macs card, Studio Mac isn't named again.
        XCTAssertEqual(queue[0].line(under: "Studio Mac"), "Transcribing · 40%")
        XCTAssertEqual(queue[1].line(under: "Studio Mac"), "Summarizing · 50%")
        XCTAssertEqual(queue[2].line(under: "Studio Mac"), "Waiting")
        XCTAssertEqual(StatusSheetModel.queue(meetings: [waitingNew, failed, waitingOld, running, live], liveProgress: progress,
                                              thisDevice: phone.id, now: now, limit: 2).count, 2)
    }

    func testAFailureSaysWhatItMeansAndKeepsTheMacsWordsForDetails() {
        let phone = ProcessingRequest.Device(id: "phone", name: "Alex’s iPhone")
        let studio = ProcessingRequest.Device(id: "studio", name: "Studio Mac")
        var failed = Meeting(title: "Failed")
        failed.status = .imported
        let failedRequest = ProcessingRequest(meetingID: failed.id, mode: .newAudio, requestedBy: phone, createdAt: now.addingTimeInterval(-3_000))
            .failed(by: studio, at: now.addingTimeInterval(-2_000), reason: "MLX error: Metal heap allocation failed (code 7)")
        failed.processingRequests = failedRequest.map { [$0] }
        let entry = StatusSheetModel.queue(meetings: [failed], liveProgress: [:], thisDevice: phone.id, now: now).first
        XCTAssertEqual(entry?.line, "Studio Mac couldn’t finish")
        XCTAssertEqual(entry?.detail, "Something went wrong on Studio Mac. The recording is saved.")
        XCTAssertEqual(entry?.details, "MLX error: Metal heap allocation failed (code 7)")
        XCTAssertFalse(entry?.line.contains("MLX") ?? true)
        XCTAssertEqual(entry?.line(under: "Studio Mac"), "Couldn’t finish")

        // Over the link, the line names the Mac and nothing more.
        let live = LiveProgress(LinkProcessingProgress(meetingID: UUID(), phase: .failed, macName: "Studio Mac", detail: "MLX error"))
        XCTAssertEqual(live.line, "Studio Mac couldn’t finish")
    }

    func testAMacRecordingByItsPresenceShowsAsRecording() {
        var inputs = StatusInputs()
        inputs.mac = .recording(name: "Studio Mac", lastSeen: now)
        let line = StatusSheetModel.macLine(inputs, now: now)
        XCTAssertEqual(line.title, "Studio Mac")
        XCTAssertEqual(line.text, "Recording")
        XCTAssertEqual(line.tone, .recording)
        inputs.queue = [StatusQueueEntry(id: UUID(), title: "A", line: "Waiting", requestedHere: true, progress: nil, isRunning: false)]
        XCTAssertEqual(StatusSheetModel.macLine(inputs, now: now).text, "Recording · 1 waiting")
    }

    func testCompactDetentGrowsWithTextSize() {
        // Up to the accessibility sizes, three lines one row each; past them, one line over four rows.
        for sizes in [DynamicTypeSize.allCases.filter { !$0.isAccessibilitySize }, DynamicTypeSize.allCases.filter(\.isAccessibilitySize)] {
            var previous: CGFloat = 0
            for size in sizes {
                let height = StatusCompactDetent.height(for: size, maximum: 800)
                XCTAssertGreaterThan(height, previous, "\(size) is taller than the size before")
                previous = height
            }
        }
        // Record (68 pt with the glass) under the grabber's room, then three lines.
        XCTAssertGreaterThanOrEqual(StatusCompactDetent.height(for: .large, maximum: 800), StatusCompactDetent.recordTop + 68 + 16 + 3 * 18 + 16)
        XCTAssertLessThanOrEqual(StatusCompactDetent.height(for: .xxxLarge, maximum: 678), 678 * 0.55, "about half the screen")
        // At the largest size, the Record row and one line take at most 55% of the Duo's cover (it was 70%).
        XCTAssertLessThanOrEqual(StatusCompactDetent.height(for: .accessibility5, maximum: 678), 678 * 0.55)
        // This iPhone's line, while it has work, takes a row more.
        XCTAssertGreaterThan(StatusCompactDetent.height(for: .large, maximum: 800, lines: 4), StatusCompactDetent.height(for: .large, maximum: 800))
        XCTAssertEqual(StatusCompactDetent.height(for: .accessibility3, maximum: 800, lines: 4),
                       StatusCompactDetent.height(for: .accessibility3, maximum: 800), "one line at the accessibility sizes, whatever there is")
    }

    /// ui-iphone-02, hig-ios-05: at the accessibility sizes a line's title wraps as its words do ("Vlad’s / MacBook Pro"
    /// over "Last seen / today, 2:29 AM"), so compact makes room for the four rows they share (a one-line title leaves
    /// its words three) and the progress line, on the iPhone's sheet and the Duo's panel alike, short of the cap.
    func testCompactDetentHoldsAWrappedTitleAndItsWordsAtTheAccessibilitySizes() {
        for size in DynamicTypeSize.allCases.filter(\.isAccessibilitySize) {
            let line = StatusCompactDetent.lineHeight(.subheadline, at: size)
            let rows = CGFloat(StatusMetrics.stackedRows)
            XCTAssertEqual(rows, 4, "a title and its words, four rows between them")
            let lines = StatusCompactDetent.linesHeight(for: size)
            // The title's two lines, 2 pt, the words' two lines, then 4 pt and the 2 pt progress line.
            XCTAssertGreaterThanOrEqual(lines, rows * line + 2 + 4 + 2, "\(size)")
            let record = max(60, StatusCompactDetent.lineHeight(.title3, at: min(size, StatusCompactDetent.recordLargestSize)) + 8) + 8
            XCTAssertGreaterThanOrEqual(StatusCompactDetent.height(for: size, maximum: 2_000),
                                        StatusCompactDetent.recordTop + record + StatusCompactDetent.recordGap + lines + 16, "\(size)")
        }
        // Even at the largest size, an iPhone 18 Pro's sheet holds it uncapped.
        let largest = StatusCompactDetent.height(for: .accessibility5, maximum: 2_000)
        XCTAssertEqual(StatusCompactDetent.height(for: .accessibility5, maximum: 800), largest)
    }

    /// hig-ios-01: an iPhone 18 Pro on its side shows the panel on a right page about 380 pt tall. Compact stays within
    /// 55% of it, as the sheet does of the screen, even at the largest text size (the line scrolls there), and each size
    /// is at least the one below it, so Expand never shrinks the panel.
    func testBehaviorThePanelOnASidewaysIPhoneStaysWithinItsCapAndGrowsInOrder() {
        let page: CGFloat = 380
        for size in DynamicTypeSize.allCases {
            for lines in [StatusCompactDetent.lineCount, StatusCompactDetent.lineCount + 1] {
                let layout = StatusPanelLayout(lines: lines, typeSize: size)
                let compact = StatusPanel.contentHeight(.compact, in: page, layout: layout)
                let medium = StatusPanel.contentHeight(.medium, in: page, layout: layout)
                let large = StatusPanel.contentHeight(.large, in: page, layout: layout)
                XCTAssertGreaterThan(compact, 0, "\(size)")
                XCTAssertLessThanOrEqual(StatusPanel.footprint(.compact, in: page, layout: layout), page * 0.55, "\(size), \(lines) lines")
                XCTAssertLessThanOrEqual(compact, medium, "\(size): Expand never shrinks the panel")
                XCTAssertLessThanOrEqual(medium, large, "\(size)")
                XCTAssertLessThan(StatusPanel.footprint(.large, in: page, layout: layout), page, "\(size): large stays on the page")
                if !size.isAccessibilitySize {
                    // Short of the accessibility sizes compact doesn't scroll, so it holds its lines whole.
                    let whole = StatusCompactDetent.linesHeight(for: size, lines: lines) + PhoneStyle.Space.s1 + PhoneStyle.Space.s4
                    XCTAssertEqual(compact, whole, "\(size), \(lines) lines")
                }
            }
        }
        let largest = StatusPanelLayout(lines: StatusCompactDetent.lineCount, typeSize: .accessibility5)
        XCTAssertLessThanOrEqual(StatusPanel.contentHeight(.compact, in: page, layout: largest), page * 0.55)
        XCTAssertLessThanOrEqual(page * 0.55, StatusPanel.contentHeight(.medium, in: page, layout: largest))
        XCTAssertLessThan(StatusPanel.contentHeight(.compact, in: page, layout: largest),
                          StatusCompactDetent.linesHeight(for: .accessibility5) + PhoneStyle.Space.s1 + PhoneStyle.Space.s4,
                          "the line scrolls inside the cap")

        // The open Duo's right page is taller: compact holds its lines whole at every size.
        let duoPage: CGFloat = 635
        for size in DynamicTypeSize.allCases {
            let layout = StatusPanelLayout(lines: StatusCompactDetent.lineCount + 1, typeSize: size)
            let whole = StatusCompactDetent.linesHeight(for: size, lines: layout.lines) + PhoneStyle.Space.s1 + PhoneStyle.Space.s4
            XCTAssertEqual(StatusPanel.contentHeight(.compact, in: duoPage, layout: layout), whole, "\(size)")
        }
    }

    // MARK: This iPhone's own work

    /// rd-10, ux-iphone-21: while this iPhone transcribes its own recording, or pauses it, the sheet says so in the
    /// words a Mac's home uses for its own queue, and lists the work in the This iPhone card; idle, nothing.
    func testBehaviorThisIPhonesOwnWorkHasALineAndRowsWhileItHasSome() {
        let phone = ProcessingRequest.Device(id: "this-phone", name: "Alex’s iPhone")
        var running = Meeting(title: "Interview")
        running.processingRequests = [ProcessingRequest(meetingID: running.id, mode: .newAudio, requestedBy: phone, createdAt: now.addingTimeInterval(-60))]
        var waiting = Meeting(title: "Standup")
        waiting.processingRequests = [ProcessingRequest(meetingID: waiting.id, mode: .newAudio, requestedBy: phone, createdAt: now.addingTimeInterval(-30))]
        let local = ProcessingStatus.LocalQueue(running: running.id, fraction: 0.4, queued: [waiting.id], stage: .transcribing)
        func queue(_ meeting: Meeting) -> ProcessingStatus.LocalQueue? { [running.id, waiting.id].contains(meeting.id) ? local : nil }

        let work = StatusSheetModel.phoneWork(meetings: [waiting, running], local: queue, pause: nil, thisDevice: phone.id, now: now)
        XCTAssertEqual(work.entries.map(\.title), ["Interview", "Standup"], "what runs, then what waits")
        XCTAssertEqual(work.entries.map(\.line), ["Transcribing · 40%", "Waiting to transcribe"])
        XCTAssertEqual(work.entries.first?.progress, 0.4)
        var inputs = StatusInputs()
        inputs.phone = work.line
        inputs.phoneQueue = work.entries
        let line = StatusSheetModel.phoneLine(inputs, now: now)
        XCTAssertEqual(line?.title, "This iPhone")
        XCTAssertEqual(line?.text, "Transcribing · 40% · 1 waiting")
        XCTAssertEqual(line?.progress, 0.4)
        XCTAssertEqual(StatusSheetModel.lines(inputs, now: now).map(\.id), ["recorder", "mac", "queue", "sync"],
                       "this iPhone's line after the devices, before iCloud, as the Mac's home orders its own")

        // Paused for the battery: when it goes on, also where it's narrow.
        let pausedQueue = ProcessingStatus.LocalQueue(running: nil, queued: [], paused: [running.id, waiting.id])
        let paused = StatusSheetModel.phoneWork(meetings: [running, waiting], local: { _ in pausedQueue }, pause: .lowBattery,
                                                thisDevice: phone.id, now: now)
        XCTAssertEqual(paused.entries.map(\.line), ["Paused · Continues when iPhone is charging", "Paused · Continues when iPhone is charging"])
        inputs.phone = paused.line
        XCTAssertEqual(StatusSheetModel.phoneLine(inputs, now: now)?.text, "Paused · Continues when iPhone is charging")
        XCTAssertEqual(StatusSheetModel.phoneLine(inputs, now: now)?.shortText, "Continues when iPhone is charging")

        // Nothing to do here: no line, and no card until the sheet is at full height.
        let idle = StatusSheetModel.phoneWork(meetings: [running, waiting], local: { _ in nil }, pause: nil, thisDevice: phone.id, now: now)
        XCTAssertEqual(idle, StatusSheetModel.PhoneWork())
        inputs.phone = idle.line
        inputs.phoneQueue = idle.entries
        XCTAssertNil(StatusSheetModel.phoneLine(inputs, now: now))
        XCTAssertFalse(StatusSheetModel.sections(for: .medium, inputs).contains(.iphone))
        XCTAssertEqual(StatusSheetModel.lines(inputs, now: now).count, 3)
    }

    /// A summary counting down to this iPhone, or running in the cloud, is this iPhone's own work, not a Mac's.
    func testBehaviorASummaryCountingDownHereIsThisIPhonesNotAMacs() throws {
        let id = UUID()
        let sonnet = CloudModel(provider: .anthropic, id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", tier: .balanced,
                                inputPrice: 2, outputPrice: 10, priceIsEstimated: false, contextTokens: 200_000, rank: 1)
        // With the cloud on offer, a summary due here counts down before it starts.
        let options = SummaryOptions(thisDeviceCanSummarize: true, reachableMacs: [], cloud: sonnet)
        let here = SummaryPlacementPlanner(options: options, preferences: CloudSummaryPreferences(), at: now, waitsForMacs: true)
        guard case .countingDown(.thisDevice, _) = here.phase else { return XCTFail("counts down to this iPhone: \(here.phase)") }
        let meeting = Meeting(id: id, title: "Counting")
        let work = StatusSheetModel.phoneWork(meetings: [meeting], local: { _ in nil }, pause: nil, thisDevice: "me", planners: [id: here],
                                              now: now)
        let row = try XCTUnwrap(work.entries.first?.item(under: nil, now: now))
        XCTAssertEqual(row.line(at: now.addingTimeInterval(2)), "Summarizing in \(here.secondsLeft(at: now.addingTimeInterval(2)) ?? 0) s",
                       "under the This iPhone heading it doesn't name the place, and it ticks")
        XCTAssertEqual(row.actions.map(\.title), here.actions.map(\.title))
        XCTAssertNotNil(work.line.countdown)
        XCTAssertEqual(StatusSheetModel.queue(meetings: [meeting], liveProgress: [:], thisDevice: "me", planners: [id: here], now: now), [],
                       "not in the Macs card")
        var inputs = StatusInputs()
        inputs.phone = work.line
        XCTAssertEqual(StatusSheetModel.phoneLine(inputs, now: now)?.tone, .calm, "a countdown is calm")
    }

    // MARK: Where a line leads

    /// ux-iphone-02: a line that needs the person leads to its fix; the rest show more.
    func testBehaviorALineThatNeedsThePersonLeadsToItsFix() {
        var inputs = StatusInputs()
        let reason = CloudAvailability.signedOutMessage
        inputs.syncTone = .attention
        inputs.syncOff = true
        inputs.syncLine = StatusSheetModel.unavailablePhrase(reason)
        inputs.syncShort = "Off"
        let sync = StatusSheetModel.syncLine(inputs)
        XCTAssertEqual(sync.text, "Signed out", "the reason, not a bare Off")
        XCTAssertEqual(sync.shortText, "Off", "Off where it's narrow")
        XCTAssertEqual(sync.symbol, "icloud.slash")
        XCTAssertEqual(StatusSheetModel.route(for: sync, inputs), .open(.icloud))
        XCTAssertEqual(StatusSheetModel.hint(for: .open(.icloud)), "Opens iCloud settings")
        XCTAssertEqual(StatusSheetModel.unavailablePhrase(CloudAvailability.iCloudDriveOffMessage), "iCloud Drive is off")
        XCTAssertEqual(StatusSheetModel.unavailablePhrase(CloudAvailability.unsetMessage), "Not available in this build")

        // A Mac that isn't set up to transcribe, paired here or not: the Macs card, where its row says what to do (the
        // Mac's own page says only "Transcribes: Not set up").
        let studio = UUID()
        inputs.mac = .notProcessing(name: "Studio Mac", lastSeen: now)
        inputs.pairedMacs = [StatusInputs.Mac(id: studio, name: "Studio Mac", line: "Connected", isConnected: true, notProcessing: true)]
        let mac = StatusSheetModel.macLine(inputs, now: now)
        XCTAssertEqual(mac.tone, .attention)
        XCTAssertEqual(StatusSheetModel.route(for: mac, inputs), .showFix(.macs))
        XCTAssertEqual(StatusSheetModel.hint(for: .showFix(.macs)), "Shows how to fix it")
        XCTAssertTrue(StatusSheetModel.sections(for: .medium, inputs).contains(.macs), "the step up to medium shows the card")
        let row = StatusSheetModel.macRows(inputs, now: now).first
        XCTAssertEqual(row?.text, "Not set up to transcribe", "not \"Connected\"")
        XCTAssertEqual(row?.fix, "Finish in Daybook › Settings on Studio Mac.")
        XCTAssertTrue(row?.needsYou == true)
        inputs.pairedMacs = []
        XCTAssertEqual(StatusSheetModel.route(for: mac, inputs), .showFix(.macs))
        XCTAssertEqual(StatusSheetModel.macRows(inputs, now: now).first?.fix, "Finish in Daybook › Settings on Studio Mac.")
        // What a Mac couldn’t finish: the Macs card too, where its queue row says what happened.
        var failing = inputs
        failing.liveProgress = [LiveProgress(LinkProcessingProgress(meetingID: UUID(), phase: .failed, macName: "Studio Mac"))]
        let failed = StatusSheetModel.macLine(failing, now: now)
        XCTAssertEqual(failed.text, "Couldn’t finish")
        XCTAssertEqual(StatusSheetModel.route(for: failed, failing), .showFix(.macs))

        // A recorder's problem: its page.
        let problem = line(recorder { $0.state = .unavailable; $0.isLinked = false; $0.problem = "Bluetooth is off" })
        XCTAssertEqual(StatusSheetModel.route(for: problem, inputs), .open(.device("sc")))
        // Calm lines show more.
        XCTAssertEqual(StatusSheetModel.route(for: line(recorder()), inputs), .showMore)
        XCTAssertEqual(StatusSheetModel.hint(for: .showMore), "Shows more")
    }

    // MARK: The queue's failures

    /// ux-iphone-12: a conversation that couldn't finish offers Try Again with what it asked for, and stays in the
    /// queue only while it's recent; no speech never does.
    func testBehaviorAFailureOffersTryAgainAndGoesWhenItsOld() {
        let phone = ProcessingRequest.Device(id: "phone", name: "Alex’s iPhone")
        let studio = ProcessingRequest.Device(id: "studio", name: "Studio Mac")
        func failed(_ title: String, mode: ProcessingRequest.Mode = .newAudio, ago: TimeInterval, reason: String = "Out of memory") -> Meeting {
            var meeting = Meeting(title: title, tracks: [RecordingTrack(id: UUID(), source: .microphone, relativePath: "m.caf", fileName: "m.caf",
                                                                       offset: 0, sha256: title)])
            meeting.status = .imported
            meeting.processingRequests = [ProcessingRequest(meetingID: meeting.id, mode: mode, requestedBy: phone, createdAt: now.addingTimeInterval(-ago - 60))
                .failed(by: studio, at: now.addingTimeInterval(-ago), reason: reason)].compactMap { $0 }
            return meeting
        }
        let recent = failed("Recent", ago: 3_600)
        let summary = failed("Summary", mode: .summaryOnly, ago: 3_600)
        let old = failed("Old", ago: 8 * 86_400)
        let silent = failed("Silent", ago: 60, reason: "No speech was recognized.")
        let queue = StatusSheetModel.queue(meetings: [recent, summary, old, silent], liveProgress: [:], thisDevice: phone.id, now: now)
        XCTAssertEqual(queue.map(\.title), ["Recent", "Summary"])
        XCTAssertEqual(queue[0].retry, .newAudio)
        XCTAssertEqual(queue[1].retry, .summaryOnly, "Try Again asks again for what failed, as the page does")
        let item = queue[0].item(under: "Studio Mac")
        XCTAssertEqual(item.actions, [.tryAgain(.newAudio)])
        XCTAssertTrue(item.isProblem)
        XCTAssertEqual(item.line, "Couldn’t finish")
        XCTAssertEqual(item.detail, "The speech model couldn’t start on Studio Mac. The recording is saved.",
                       "in the plain words both apps give its kind")
        XCTAssertEqual(item.details, "Out of memory")
        XCTAssertNil(item.note, "a failure isn't “Requested from this iPhone”")
        XCTAssertEqual(queue[0].item(under: nil).line, "Studio Mac couldn’t finish", "at the top of the card, it names the Mac")
    }

    // MARK: At the accessibility sizes

    /// hig-ios-05: compact at the accessibility sizes keeps the line that matters most, so the list stays usable.
    func testBehaviorAtTheAccessibilitySizesCompactKeepsTheLineThatMattersMost() {
        var inputs = StatusInputs()
        inputs.recorders = [recorder()]
        inputs.mac = .seen(name: "Studio Mac", lastSeen: now)
        inputs.syncLine = "Up to date"
        inputs.syncTone = .upToDate
        let lines = StatusSheetModel.lines(inputs, now: now)
        XCTAssertEqual(StatusSheetModel.compactLines(lines, accessibilitySize: false), lines)
        XCTAssertEqual(StatusSheetModel.compactLines(lines, accessibilitySize: true).map(\.id), ["recorder-sc"], "connected beats calm")
        inputs.syncTone = .attention
        inputs.syncLine = "Sync paused"
        XCTAssertEqual(StatusSheetModel.compactLines(StatusSheetModel.lines(inputs, now: now), accessibilitySize: true).map(\.id), ["sync"],
                       "what needs the person first")
        inputs.recorders = []
        inputs.syncTone = .upToDate
        XCTAssertEqual(StatusSheetModel.compactLines(StatusSheetModel.lines(inputs, now: now), accessibilitySize: true).map(\.id), ["mac"],
                       "“None added” last")
    }
}
