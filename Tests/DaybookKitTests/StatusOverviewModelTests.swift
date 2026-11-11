import DaybookCore
import DaybookDevices
import DaybookLink
import Foundation
import XCTest

@testable import DaybookKit

/// The status overview both apps draw (docs/interface.md, "Status overview"; docs/iphone.md, "Status sheet"): what
/// each line says in each state, and which groups the iPhone's sheet shows. The iPhone's own parts (its sizes, where a
/// line leads, its rows) are its `StatusSheetModelTests`.
@MainActor
final class StatusOverviewModelTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func recorder(_ change: (inout RecorderFacts) -> Void = { _ in }) -> RecorderFacts {
        var recorder = RecorderFacts(
            id: "sc", name: "Soundcore Work", shortName: "Soundcore", symbol: "recordingtape", isDirect: true,
            state: .connected, isLinked: true)
        recorder.batteryLevel = 80
        change(&recorder)
        return recorder
    }

    private func line(_ recorder: RecorderFacts) -> StatusLineWords {
        StatusOverviewModel.recorderLine(recorder, here: "this iPhone", now: now)
    }

    // MARK: The recorder line

    func testARecorderThatIsntLiveHereSaysWhatItWasLastKnownToDo() {
        let managed = line(
            recorder {
                $0.managedBy = "Studio Mac"
                $0.isLinked = false
                $0.state = .notConnected
                $0.lastKnown = "Recording since 10:02, as of 10:14"
            })
        XCTAssertEqual(managed.text, "Managed by Studio Mac · Recording since 10:02, as of 10:14")
        XCTAssertEqual(
            line(
                recorder {
                    $0.managedBy = "Studio Mac"
                    $0.isLinked = false
                }
            ).text, "Managed by Studio Mac",
            "nothing said, or too old to say")
        let away = line(
            recorder {
                $0.isLinked = false
                $0.state = .notConnected
                $0.lastKnown = "Not recording, as of 10:14"
            })
        XCTAssertEqual(away.text, "Not recording, as of 10:14")
        XCTAssertEqual(away.tone, .calm)

        // What it says is shown with its age, then not at all.
        let asOf = Date()
        let state = LinkRecorderState(
            kind: "soundcore.work", isRecording: true, startedAt: asOf.addingTimeInterval(-600),
            asOf: asOf)
        XCTAssertEqual(
            state.summary(now: asOf),
            "Recording since \(asOf.addingTimeInterval(-600).formatted(date: .omitted, time: .shortened))"
        )
        XCTAssertTrue(
            state.summary(now: asOf.addingTimeInterval(120))?.hasSuffix(
                "as of \(asOf.formatted(date: .omitted, time: .shortened))") == true)
        XCTAssertNil(state.summary(now: asOf.addingTimeInterval(21 * 60)))
    }

    func testRecorderLineSaysWhatTheRecorderIsDoing() {
        let connected = line(recorder { $0.newCount = 2 })
        XCTAssertEqual(connected.title, "Soundcore Work")
        XCTAssertEqual(connected.text, "Connected · 80% · 2 new")
        XCTAssertEqual(connected.tone, .linked)

        XCTAssertEqual(line(recorder { $0.batteryCharging = true }).text, "Connected · 80%, charging")
        let recording = line(recorder { $0.isRecording = true })
        XCTAssertEqual(recording.text, "Recording · 80%")
        XCTAssertEqual(recording.tone, .recording, "the red dot: recording right now")

        // Too narrow for all of it, the line keeps what matters instead of cutting the end off.
        XCTAssertEqual(
            connected.shortText, "80% · 2 new", "a battery level and new recordings say it's connected")
        XCTAssertEqual(
            line(
                recorder {
                    $0.batteryCharging = true
                    $0.newCount = 1
                }
            ).shortText, "80%, charging · 1 new")
        XCTAssertEqual(
            line(
                recorder {
                    $0.isRecording = true
                    $0.newCount = 2
                }
            ).text, "Recording · 80% · 2 new")
        XCTAssertEqual(
            line(
                recorder {
                    $0.isRecording = true
                    $0.newCount = 2
                }
            ).shortText, "Recording · 80%")
        XCTAssertNil(recording.shortText, "nothing to drop")
        XCTAssertNil(line(recorder { $0.batteryLevel = nil }).shortText, "Connected alone stays")

        let importing = line(recorder { $0.importing = .init(position: 1, total: 3, fraction: 0.25, running: false) })
        XCTAssertEqual(importing.text, "Importing 1 of 3")
        XCTAssertEqual(importing.tone, .working)
        XCTAssertEqual(importing.progress, 0.25)
        XCTAssertEqual(
            line(
                recorder {
                    $0.importing = .init(position: 1, total: 2, fraction: nil, suspended: true, running: false)
                    $0.isLinked = false
                    $0.state = .notConnected
                }
            ).text,
            "2 recordings wait to import")

        XCTAssertEqual(line(recorder { $0.isListeningLive = true }).text, "Listening live")
        XCTAssertEqual(
            line(
                recorder {
                    $0.state = .connecting
                    $0.isLinked = false
                }
            ).text, "Connecting…")

        let away = line(
            recorder {
                $0.state = .notConnected
                $0.isLinked = false
                $0.newCount = 1
                $0.lastConnected = now.addingTimeInterval(-60)
            })
        XCTAssertTrue(away.text.hasPrefix("1 new · Last seen today"), away.text)
        XCTAssertEqual(
            line(
                recorder {
                    $0.state = .notConnected
                    $0.isLinked = false
                }
            ).text, "Not connected")

        let problem = line(
            recorder {
                $0.state = .unavailable
                $0.isLinked = false
                $0.problem = "Bluetooth is off"
            })
        XCTAssertEqual(problem.text, "Bluetooth is off")
        XCTAssertEqual(problem.tone, .attention)
    }

    /// The Soundcore app transferring over the link iOS shares: Daybook's import waits, and the line says so
    /// in place of "Importing 1 of 3".
    func testRecorderLineSaysAnImportWaitsForTheSoundcoreApp() {
        let waiting = line(
            recorder {
                $0.importing = .init(position: 1, total: 3, fraction: 0, running: false)
                $0.otherAppWait = "Waiting for the Soundcore app to finish"
            })
        XCTAssertEqual(waiting.text, "Waiting for the Soundcore app to finish")
        XCTAssertEqual(waiting.tone, .working)
        XCTAssertEqual(waiting.shortText, "Waiting…")
    }

    /// Over the recorder's Wi‑Fi, leaving Daybook starts the transfer again over Bluetooth: the compact line says to
    /// keep Daybook open, also where it's narrow.
    func testBehaviorTheRecorderLineSaysToKeepDaybookOpenDuringFastTransfer() {
        let starting = line(
            recorder {
                $0.importing = .init(position: 1, total: 1, fraction: 0, running: false)
                $0.fastTransfer = .starting
            })
        XCTAssertEqual(starting.text, "Importing · Starting Wi‑Fi…")
        XCTAssertEqual(starting.shortText, "Starting Wi‑Fi…")
        let joining = line(
            recorder {
                $0.importing = .init(position: 1, total: 1, fraction: 0, running: false)
                $0.fastTransfer = .joining(recorder: "Soundcore Work")
            })
        XCTAssertEqual(joining.text, "Importing · Joining Wi‑Fi…")
        XCTAssertEqual(joining.shortText, "Joining Wi‑Fi…")
        let transferring = line(
            recorder {
                $0.importing = .init(position: 1, total: 1, fraction: 0.64, running: false)
                $0.fastTransfer = .transferring
            })
        XCTAssertEqual(transferring.text, "Importing · 64% · Keep Daybook open")
        XCTAssertEqual(transferring.shortText, "Keep Daybook open")
        XCTAssertEqual(transferring.progress, 0.64)
    }

    func testRecorderLineForOwnershipAndHandoff() {
        let managed = line(
            recorder {
                $0.managedBy = "Studio Mac"
                $0.isLinked = false
                $0.state = .notConnected
            })
        XCTAssertEqual(managed.text, "Managed by Studio Mac")
        XCTAssertEqual(managed.tone, .calm)

        func handoff(_ state: RecorderHandoff.State) -> StatusLineWords {
            line(
                recorder {
                    $0.managedBy = "Studio Mac"
                    $0.handoff = state
                })
        }
        XCTAssertEqual(handoff(.asking(owner: "Studio Mac")).text, "Asking Studio Mac to let go…")
        XCTAssertEqual(handoff(.asking(owner: "Studio Mac")).shortText, "Asking Studio Mac…")
        let finishing = handoff(
            .ownerFinishing(
                owner: "Studio Mac", finishing: .importing(title: "Today, 10:02 AM", secondsLeft: 90)))
        XCTAssertEqual(finishing.text, "Studio Mac finishes an import, then lets go")
        XCTAssertEqual(finishing.shortText, "Moving here after an import")
        XCTAssertEqual(
            handoff(.ownerFinishing(owner: "Studio Mac", finishing: nil)).text,
            "Studio Mac is letting go…")
        let waiting = handoff(.waitingForSync(owner: "Studio Mac", since: now))
        XCTAssertEqual(
            waiting.text, "Waiting for Studio Mac to let go…", "honest about who it waits for")
        XCTAssertEqual(waiting.shortText, "Waiting for Studio Mac…")
        XCTAssertEqual(waiting.tone, .working)
        XCTAssertEqual(handoff(.connecting(from: "Studio Mac")).text, "Connecting…")
        XCTAssertEqual(handoff(.done(at: now)).text, "On this iPhone now")
        XCTAssertEqual(handoff(.done(at: now)).tone, .linked)
        let refused = handoff(.refused(by: "Studio Mac", message: "No."))
        XCTAssertEqual(refused.text, "Studio Mac didn’t hand it over")
        XCTAssertEqual(refused.tone, .attention)
        XCTAssertEqual(
            line(recorder { $0.handoff = .handingOver(to: "Studio Mac", finishing: nil) }).text,
            "Moving to Studio Mac…")
        XCTAssertEqual(
            line(recorder { $0.handoff = .offering(to: "Studio Mac") }).text,
            "Asking Studio Mac to take it…"
        )
    }

    /// ux-flows P4, uxf-10: a line for each recorder added, and none for a recorder that isn't: no "None added".
    func testBehaviorEachRecorderAddedHasItsLineAndNoneAddedSaysNothing() {
        let idle = recorder {
            $0.id = "a"
            $0.name = "Soundcore Work"
        }
        let busy = recorder {
            $0.id = "b"
            $0.name = "Soundcore Work 2"
            $0.importing = .init(position: 1, total: 1, fraction: 0.5, running: false)
        }
        var inputs = StatusOverviewInputs(words: .iPhone())
        inputs.recording.recorders = [idle, busy]
        XCTAssertEqual(StatusOverviewModel.lines(inputs, now: now).map(\.id), ["recorder-a", "recorder-b"])
        XCTAssertEqual(
            StatusOverviewModel.strip(StatusOverviewModel.lines(inputs, now: now))?.id, "recorder-b",
            "the busy one is what the strip says")
        inputs.recording.recorders = []
        XCTAssertEqual(StatusOverviewModel.lines(inputs, now: now), [], "nothing added, nothing checked yet")
        XCTAssertFalse(StatusOverviewModel.sections(inputs, now: now).contains(.recorders), "no Add Recorder… card")
    }

    // MARK: The Mac line

    func testMacLineShowsLiveProgressPresenceAndWaitingWork() throws {
        var inputs = StatusOverviewInputs(words: .iPhone())
        inputs.mac = .connected(name: "Studio Mac")
        inputs.liveProgress = [
            LiveProgress(
                LinkProcessingProgress(
                    meetingID: UUID(), phase: .transcribing, fraction: 0.4, macName: "Studio Mac"))
        ]
        let transcribing = try XCTUnwrap(StatusOverviewModel.macLine(inputs, now: now))
        XCTAssertEqual(transcribing.title, "Studio Mac")
        XCTAssertEqual(transcribing.text, "Transcribing · 40%")
        XCTAssertEqual(transcribing.progress, 0.4)
        XCTAssertEqual(transcribing.tone, .working)
        XCTAssertEqual(transcribing.shortText, "Transcribing", "the gradient line shows how far")

        inputs.liveProgress = [
            LiveProgress(
                LinkProcessingProgress(
                    meetingID: UUID(), phase: .failed, macName: "Studio Mac", detail: "Out of space"))
        ]
        XCTAssertEqual(StatusOverviewModel.macLine(inputs, now: now)?.tone, .attention)

        inputs.liveProgress = []
        inputs.queue = [
            StatusQueueEntry(
                id: UUID(), title: "A", line: "Waiting", requestedHere: true, progress: nil,
                isRunning: false),
            StatusQueueEntry(
                id: UUID(), title: "B", line: "Waiting", requestedHere: false, progress: nil,
                isRunning: false),
        ]
        XCTAssertEqual(StatusOverviewModel.macLine(inputs, now: now)?.text, "Connected · 2 waiting")
        XCTAssertEqual(StatusOverviewModel.macLine(inputs, now: now)?.tone, .linked)
        // Narrow (a long Mac name), the waiting work stays rather than being cut off.
        XCTAssertEqual(StatusOverviewModel.macLine(inputs, now: now)?.shortText, "2 waiting")

        inputs.queue = []
        XCTAssertNil(StatusOverviewModel.macLine(inputs, now: now)?.shortText, "Connected alone stays")
        inputs.mac = .seen(name: "Studio Mac", lastSeen: now.addingTimeInterval(-7_200))
        XCTAssertEqual(
            StatusOverviewModel.macLine(inputs, now: now)?.text,
            RecorderStatusWords.lastSeen(now.addingTimeInterval(-7_200), now: now),
            "dated as every device's absence is")
        XCTAssertTrue(StatusOverviewModel.macLine(inputs, now: now)?.text.hasPrefix("Last seen today") == true)
        // ux-flows P4, uxf-10: a Mac speaks only while it exists: none synced, or none known, says nothing.
        inputs.mac = .seen(name: "Studio Mac", lastSeen: now.addingTimeInterval(-31 * 86_400))
        XCTAssertNil(StatusOverviewModel.macLine(inputs, now: now), "last synced more than 30 days ago")
        inputs.mac = .noMac
        XCTAssertNil(StatusOverviewModel.macLine(inputs, now: now), "no “Hasn’t synced this library yet”")
        inputs.mac = .unavailable("iCloud is off")
        XCTAssertNil(StatusOverviewModel.macLine(inputs, now: now), "iCloud's own line says why")
        inputs.mac = .checking
        XCTAssertNil(StatusOverviewModel.macLine(inputs, now: now))
        // A Mac paired over the link keeps its line whatever sync says.
        let studio = UUID()
        inputs.pairedMacs = [
            StatusOverviewInputs.Mac(id: studio, name: "Studio Mac", line: "Last seen yesterday", isConnected: false)
        ]
        let paired = StatusOverviewModel.lines(inputs, now: now)
        XCTAssertEqual(paired.map(\.id), ["mac-\(studio.uuidString)"])
        XCTAssertEqual(paired.first?.text, "Last seen yesterday")
        XCTAssertEqual(paired.first?.tone, .calm)
        inputs.pairedMacs[0].isConnected = true
        inputs.pairedMacs[0].line = "Connected"
        XCTAssertEqual(StatusOverviewModel.lines(inputs, now: now).first?.tone, .linked)
        inputs.pairedMacs[0].isRecording = true
        XCTAssertEqual(StatusOverviewModel.lines(inputs, now: now).first?.tone, .recording)
        // Two Macs, one line each, the one at work first and the other not named twice.
        inputs.pairedMacs[0].isRecording = false
        inputs.pairedMacs.append(
            StatusOverviewInputs.Mac(id: UUID(), name: "MacBook Air", line: "Last seen today, 9:12 AM", isConnected: false))
        inputs.mac = .connected(name: "Studio Mac")
        XCTAssertEqual(
            StatusOverviewModel.lines(inputs, now: now).map(\.title), ["Studio Mac", "MacBook Air"])
        inputs.pairedMacs = []

        // Coarse progress from a synced claim, when the link has nothing.
        inputs.mac = .seen(name: "Studio Mac", lastSeen: now)
        inputs.queue = [
            StatusQueueEntry(
                id: UUID(), title: "A", line: "Summarizing on Studio Mac · 60%", requestedHere: false,
                progress: 0.6, isRunning: true)
        ]
        XCTAssertEqual(StatusOverviewModel.macLine(inputs, now: now)?.text, "Summarizing · 60%")
    }

    func testMacLineCountsDownWithAMacsCountdownOrThisIPhonesToAMac() throws {
        var inputs = StatusOverviewInputs(words: .iPhone())
        inputs.mac = .connected(name: "Studio Mac")
        let id = UUID()
        inputs.liveProgress = [
            LiveProgress(
                LinkProcessingProgress(
                    meetingID: id, phase: .summaryCountdown, macName: "Studio Mac",
                    countdown: LinkSummaryCountdown(secondsLeft: 12, cloudOffered: true)), receivedAt: now)
        ]
        let mac = try XCTUnwrap(StatusOverviewModel.macLine(inputs, now: now))
        XCTAssertEqual(mac.title, "Studio Mac")
        XCTAssertEqual(mac.text, SummaryPlacementWords.countdown(seconds: 12))
        XCTAssertEqual(mac.countdownUntil, now.addingTimeInterval(12))
        XCTAssertEqual(mac.text(at: now.addingTimeInterval(3)), SummaryPlacementWords.countdown(seconds: 9), "it ticks")
        XCTAssertEqual(mac.tone, .calm, "waiting isn't progress: calm, as the Mac's own countdown is")

        // This iPhone counting down to sending one to Studio Mac.
        inputs.liveProgress = []
        var entry = StatusQueueEntry(
            id: id, title: "A", line: SummaryPlacementWords.countdown(on: "Studio Mac", seconds: 15), requestedHere: false,
            progress: nil,
            isRunning: false, countdownUntil: now.addingTimeInterval(15))
        entry.isRunning = true
        entry.mac = "Studio Mac"
        entry.countdownDevice = "Studio Mac"
        inputs.queue = [entry]
        XCTAssertEqual(StatusOverviewModel.macLine(inputs, now: now)?.text, SummaryPlacementWords.countdown(seconds: 15))
        XCTAssertEqual(
            StatusOverviewModel.macLine(inputs, now: now)?.text(at: now.addingTimeInterval(5)),
            SummaryPlacementWords.countdown(seconds: 10))
        XCTAssertEqual(StatusOverviewModel.macLine(inputs, now: now)?.tone, .calm)
        // Under another Mac's row (or none), it names the Mac it counts down to; under that Mac, it doesn't.
        XCTAssertEqual(
            entry.line(under: nil, at: now.addingTimeInterval(5)), SummaryPlacementWords.countdown(on: "Studio Mac", seconds: 10))
        XCTAssertEqual(entry.line(under: "Studio Mac", at: now.addingTimeInterval(5)), SummaryPlacementWords.countdown(seconds: 10))
        // Counting down to summarizing on this iPhone: nothing for the Mac's line.
        entry.mac = nil
        entry.countdownDevice = "this iPhone"
        inputs.queue = [entry]
        XCTAssertEqual(StatusOverviewModel.macLine(inputs, now: now)?.text, "Connected")
    }

    /// iCloud has a line only while it's a problem, as on Floating Notes' home.
    func testSyncLineOnlyWhenItsAProblem() {
        var inputs = StatusOverviewInputs(words: .iPhone())
        inputs.syncLine = "Up to date"
        inputs.syncTone = .upToDate
        XCTAssertNil(StatusOverviewModel.syncLine(inputs))
        inputs.syncTone = .working
        inputs.syncLine = "Syncing 3 changes"
        XCTAssertNil(StatusOverviewModel.syncLine(inputs), "syncing is nothing to say")
        inputs.syncTone = .checking
        XCTAssertNil(StatusOverviewModel.syncLine(inputs))
        inputs.syncTone = .attention
        inputs.syncLine = "iCloud storage is full"
        XCTAssertEqual(StatusOverviewModel.syncLine(inputs)?.tone, .attention)
        XCTAssertEqual(StatusOverviewModel.syncLine(inputs)?.symbol, "exclamationmark.icloud")
        XCTAssertEqual(StatusOverviewModel.lines(inputs, now: now).map(\.id), ["sync"])
    }

    // MARK: The sheet's groups

    /// VI-18, uxf-10: the sheet doesn't repeat the lines its cards say, and has a card only for what exists.
    func testBehaviorTheSheetShowsACardForWhatExistsAndNoRepeatedLines() {
        var inputs = StatusOverviewInputs(words: .iPhone())
        XCTAssertEqual(
            StatusOverviewModel.sections(inputs, now: now), [.iphone],
            "nothing added: this iPhone and the audio kept on it, no Add Recorder… or Pair with Your Mac… card")

        inputs.recording.recorders = [recorder { $0.newCount = 1 }]
        inputs.mac = .seen(name: "Studio Mac", lastSeen: now)
        XCTAssertEqual(StatusOverviewModel.sections(inputs, now: now), [.recorders, .macs, .iphone])

        // Live captions first, while a recorder streams.
        inputs.hasLiveCaptions = true
        XCTAssertEqual(StatusOverviewModel.sections(inputs, now: now), [.captions, .recorders, .macs, .iphone])

        // iCloud has no card: its line, while it's a problem, leads the sheet.
        inputs.hasLiveCaptions = false
        inputs.syncTone = .attention
        inputs.syncLine = "Signed out"
        XCTAssertEqual(StatusOverviewModel.sections(inputs, now: now), [.lines, .recorders, .macs, .iphone])

        // A Mac last seen long ago has no card, unless work waits for one.
        inputs.syncTone = .upToDate
        inputs.recording.recorders = []
        inputs.mac = .seen(name: "Studio Mac", lastSeen: now.addingTimeInterval(-40 * 86_400))
        XCTAssertEqual(StatusOverviewModel.sections(inputs, now: now), [.iphone])
        XCTAssertEqual(StatusOverviewModel.macRows(inputs, now: now), [])
        inputs.queue = [
            StatusQueueEntry(
                id: UUID(), title: "A", line: "Waiting", requestedHere: true, progress: nil, isRunning: false)
        ]
        XCTAssertEqual(StatusOverviewModel.sections(inputs, now: now), [.macs, .iphone])
    }

    // MARK: A recorder's card

    func testARecorderOffersOnlyWhatItCanDoNow() {
        func actions(_ change: (inout RecorderFacts) -> Void) -> [StatusRecorderAction] {
            StatusOverviewModel.actions(
                for: recorder {
                    $0.hasRecordControl = true
                    $0.hasLiveListening = true
                    change(&$0)
                })
        }
        // Idle with nothing new: Record only. No "Nothing New to Import", no Listen Live until it records.
        XCTAssertEqual(actions { _ in }, [.record])
        XCTAssertEqual(actions { $0.newCount = 2 }, [.record, .importNew(2)])
        XCTAssertEqual(actions { $0.isRecording = true }, [.pause, .listenLive])
        XCTAssertEqual(
            actions {
                $0.isRecording = true
                $0.isListeningLive = true
            }, [.pause, .stopListening])

        // While a recording comes off it, neither Record nor Import; Stop Listening stays.
        XCTAssertEqual(
            actions {
                $0.newCount = 2
                $0.importing = .init(position: 1, total: 2, fraction: 0.3)
            }, [])
        XCTAssertEqual(
            actions {
                $0.isListeningLive = true
                $0.importing = .init(position: 1, total: 1, fraction: 0.3)
            },
            [.stopListening])

        // Away: Connect when it would do something, and new recordings can still be queued.
        XCTAssertEqual(
            actions {
                $0.isLinked = false
                $0.state = .notConnected
                $0.canConnect = true
                $0.newCount = 1
            }, [.connect, .importNew(1)])
        XCTAssertEqual(
            actions {
                $0.isLinked = false
                $0.state = .connecting
            }, [], "nothing disabled: Connecting… is on its line")

        // Another device manages it, or it has no Bluetooth: nothing here.
        XCTAssertEqual(
            actions {
                $0.managedBy = "Studio Mac"
                $0.isLinked = false
            }, [])
        XCTAssertEqual(
            actions {
                $0.isDirect = false
                $0.newCount = 3
            }, [])
        // On its way between devices: the handoff says what's happening, as on its page.
        XCTAssertEqual(
            actions {
                $0.handoff = .offering(to: "Studio Mac")
                $0.newCount = 1
            }, [])
        XCTAssertEqual(
            actions {
                $0.isLinked = false
                $0.state = .notConnected
                $0.canConnect = true
                $0.handoff = .asking(owner: "Studio Mac")
            }, [])
        XCTAssertEqual(
            StatusOverviewModel.actions(for: recorder { $0.newCount = 1 }), [.importNew(1)],
            "no record control, no Record")

        // Connected, but it didn't list its recordings (another app was using it): Check for New, not "nothing new".
        XCTAssertEqual(actions { $0.notListed = true }, [.record, .checkForNew])
        XCTAssertEqual(
            actions {
                $0.notListed = true
                $0.newCount = 1
            }, [.record, .importNew(1), .checkForNew], "remembered ones still import")
        XCTAssertEqual(
            actions {
                $0.notListed = true
                $0.importing = .init(position: 1, total: 1, fraction: 0.1)
            }, [])
    }

    func testARecordersStorageReadsTheWayPeopleSayIt() {
        XCTAssertEqual(
            StatusOverviewModel.storageLeft(hours: 2_172), "About \(2_170.formatted()) hours left",
            "grouped: 2,170")
        XCTAssertEqual(StatusOverviewModel.storageLeft(hours: 6.2), "About 6 hours left")
        XCTAssertEqual(StatusOverviewModel.storageLeft(hours: 1.1), "About 1 hour left")
        XCTAssertEqual(StatusOverviewModel.storageLeft(hours: 0.4), "Less than an hour left")
    }

    // MARK: The Macs card

    func testEachMacIsOneRowAndTheQueueGoesUnderTheMacDoingIt() {
        let studio = UUID()
        let air = UUID()
        var inputs = StatusOverviewInputs(words: .iPhone())
        inputs.pairedMacs = [
            StatusOverviewInputs.Mac(
                id: air, name: "MacBook Air", line: "Last connected 3 days ago", isConnected: false),
            StatusOverviewInputs.Mac(
                id: studio, name: "Vlad’s MacBook Pro (755)", line: "Connected", isConnected: true),
        ]
        inputs.mac = .connected(name: "Vlad’s MacBook Pro (755)")
        let rows = StatusOverviewModel.macRows(inputs, now: now)
        XCTAssertEqual(
            rows.map(\.id), [.paired(air), .paired(studio)], "the Mac in the line isn't added twice")
        XCTAssertEqual(rows.map(\.showsQueue), [false, true], "under the connected Mac")
        XCTAssertEqual(rows[1].text, "Connected")

        // Not connected: under the Mac presence names.
        inputs.pairedMacs[1].isConnected = false
        inputs.mac = .seen(name: "Vlad’s MacBook Pro (755)", lastSeen: now.addingTimeInterval(-7_200))
        XCTAssertEqual(StatusOverviewModel.macRows(inputs, now: now).map(\.showsQueue), [false, true])

        // A Mac that syncs this library but isn't paired here: a row of its own, from its presence.
        inputs.pairedMacs = []
        inputs.mac = .seen(name: "Studio Mac", lastSeen: now.addingTimeInterval(-7_200))
        let synced = StatusOverviewModel.macRows(inputs, now: now)
        XCTAssertEqual(
            synced,
            [
                StatusMacRow(
                    id: .synced("Studio Mac"), name: "Studio Mac",
                    text: RecorderStatusWords.lastSeen(now.addingTimeInterval(-7_200), now: now),
                    isConnected: false,
                    showsQueue: true)
            ])

        // No Mac at all: no rows (the card has only Pair with Your Mac…).
        inputs.mac = .noMac
        XCTAssertEqual(StatusOverviewModel.macRows(inputs, now: now), [])
    }

    func testQueueListsConversationsWaitingForARecording() {
        let studio = ProcessingRequest.Device(id: "studio", name: "Studio Mac")
        func awaiting(_ title: String, ended: TimeInterval) -> Meeting {
            let mac = UUID()
            var meeting = Meeting(
                title: title,
                tracks: [
                    RecordingTrack(
                        id: mac, source: .microphone, relativePath: "m.caf", fileName: "m.caf",
                        offset: 0, sha256: title)
                ],
                transcripts: [TrackTranscript(trackID: mac, segments: [])],
                summary: MeetingSummary(overview: "Hi"))
            var link = CompanionRecording(
                deviceID: "sc", deviceKind: "soundcore.work", deviceName: "Soundcore Work",
                macStartedAt: now.addingTimeInterval(ended - 600), state: .stopped, startedByDaybook: true)
            link.macEndedAt = now.addingTimeInterval(ended)
            link.recordingID = "1800000000"
            meeting.companions = [link]
            return meeting
        }
        var waiting = Meeting(title: "Asked")
        waiting.processingRequests = [
            ProcessingRequest(meetingID: waiting.id, mode: .newAudio, requestedBy: studio, createdAt: now)
        ]
        let failedRequest = ProcessingRequest(
            meetingID: UUID(), mode: .newAudio, requestedBy: studio,
            createdAt: now.addingTimeInterval(-3_000)
        )
        .failed(by: studio, at: now.addingTimeInterval(-2_000), reason: "Out of memory")
        var failed = Meeting(title: "Failed")
        failed.processingRequests = [failedRequest].compactMap { $0 }
        let queue = StatusOverviewModel.queue(
            meetings: [failed, awaiting("Newer", ended: -60), waiting, awaiting("Older", ended: -600)],
            liveProgress: [:], words: .iPhone(id: "this-phone"), now: now)
        XCTAssertEqual(
            queue.map(\.title), ["Asked", "Older", "Newer", "Failed"],
            "after the requests waiting, oldest first")
        XCTAssertEqual(queue[1].line, "Waiting for Soundcore Work audio")
        XCTAssertEqual(queue[1].line(under: "Studio Mac"), "Waiting for Soundcore Work audio")
        XCTAssertTrue(queue[1].awaitsRecording)
        XCTAssertFalse(queue[1].requestedHere)
        // They wait for the recorder, not the Mac: its line counts only what it has to do.
        var inputs = StatusOverviewInputs(words: .iPhone())
        inputs.mac = .connected(name: "Studio Mac")
        inputs.queue = queue
        XCTAssertEqual(StatusOverviewModel.macLine(inputs, now: now)?.text, "Connected · 1 waiting")
    }

    func testAConversationUnderItsMacDoesntNameItAgain() {
        let entry = StatusQueueEntry(
            id: UUID(), title: "A", line: "Transcribing on Studio Mac · 40%", requestedHere: false,
            progress: 0.4, isRunning: true, mac: "Studio Mac", brief: "Transcribing · 40%")
        XCTAssertEqual(entry.line(under: "Studio Mac"), "Transcribing · 40%")
        XCTAssertEqual(
            entry.line(under: "MacBook Air"), "Transcribing on Studio Mac · 40%",
            "another Mac's work keeps its name")
        XCTAssertEqual(entry.line(under: nil), "Transcribing on Studio Mac · 40%")

        let live = LiveProgress(
            LinkProcessingProgress(
                meetingID: UUID(), phase: .summarizing, fraction: 0.5, macName: "Studio Mac"))
        XCTAssertEqual(live.brief, "Summarizing · 50%")
        XCTAssertEqual(
            LiveProgress(LinkProcessingProgress(meetingID: UUID(), phase: .failed, macName: "Studio Mac"))
                .brief, "Couldn’t finish")
    }

    // MARK: The Mac's queue

    func testQueueListsWorkInOrderAndWhatThisIPhoneAskedFor() {
        let phone = ProcessingRequest.Device(id: "this-phone", name: "Alex’s iPhone")
        let studio = ProcessingRequest.Device(id: "studio", name: "Studio Mac")
        func meeting(_ title: String, _ request: ProcessingRequest?, status: MeetingStatus = .imported)
            -> Meeting
        {
            var meeting = Meeting(title: title)
            meeting.status = status
            if var request {
                request.meetingID = meeting.id
                meeting.processingRequests = [request]
            }
            return meeting
        }
        let waitingOld = meeting(
            "Older",
            ProcessingRequest(
                meetingID: UUID(), mode: .newAudio, requestedBy: phone,
                createdAt: now.addingTimeInterval(-600))
        )
        let waitingNew = meeting(
            "Newer",
            ProcessingRequest(
                meetingID: UUID(), mode: .newAudio, requestedBy: studio,
                createdAt: now.addingTimeInterval(-60))
        )
        let claimed = ProcessingRequest(
            meetingID: UUID(), mode: .newAudio, requestedBy: phone,
            createdAt: now.addingTimeInterval(-900)
        )
        .claimed(by: studio, at: now.addingTimeInterval(-30))?
        .renewed(by: studio, at: now.addingTimeInterval(-10), stage: .transcribing, fraction: 0.4)
        let running = meeting("Running", claimed)
        let failedRequest = ProcessingRequest(
            meetingID: UUID(), mode: .newAudio, requestedBy: phone,
            createdAt: now.addingTimeInterval(-3_000)
        )
        .failed(by: studio, at: now.addingTimeInterval(-2_000), reason: "No speech was recognized.")
        let failed = meeting("Failed", failedRequest)
        let live = meeting(
            "Live",
            ProcessingRequest(meetingID: UUID(), mode: .newAudio, requestedBy: phone, createdAt: now)
        )
        let progress = [
            live.id: LiveProgress(
                LinkProcessingProgress(
                    meetingID: live.id, phase: .summarizing, fraction: 0.5, macName: "Studio Mac"))
        ]

        let queue = StatusOverviewModel.queue(
            meetings: [waitingNew, failed, waitingOld, running, live], liveProgress: progress,
            words: .iPhone(id: phone.id), now: now)
        XCTAssertEqual(
            queue.map(\.title), ["Running", "Live", "Older", "Newer"],
            "no speech is final: its row and page say it, the queue doesn't keep it")
        XCTAssertEqual(queue[0].line, "Transcribing on Studio Mac · 40%")
        XCTAssertTrue(queue[0].isRunning)
        XCTAssertEqual(
            queue[1].line, "Summarizing on Studio Mac · 50%", "live progress over the link wins")
        XCTAssertEqual(queue[2].line, "Waiting")
        XCTAssertTrue(queue[2].requestedHere, "“Requested from this iPhone”")
        XCTAssertFalse(queue[3].requestedHere)
        // Under Studio Mac's row in the Macs card, Studio Mac isn't named again.
        XCTAssertEqual(queue[0].line(under: "Studio Mac"), "Transcribing · 40%")
        XCTAssertEqual(queue[1].line(under: "Studio Mac"), "Summarizing · 50%")
        XCTAssertEqual(queue[2].line(under: "Studio Mac"), "Waiting")
        XCTAssertEqual(
            StatusOverviewModel.queue(
                meetings: [waitingNew, failed, waitingOld, running, live], liveProgress: progress,
                words: .iPhone(id: phone.id), now: now, limit: 2
            ).count, 2)
    }

    func testAFailureSaysWhatItMeansAndKeepsTheMacsWordsForDetails() {
        let phone = ProcessingRequest.Device(id: "phone", name: "Alex’s iPhone")
        let studio = ProcessingRequest.Device(id: "studio", name: "Studio Mac")
        var failed = Meeting(title: "Failed")
        failed.status = .imported
        let failedRequest = ProcessingRequest(
            meetingID: failed.id, mode: .newAudio, requestedBy: phone,
            createdAt: now.addingTimeInterval(-3_000)
        )
        .failed(
            by: studio, at: now.addingTimeInterval(-2_000),
            reason: "MLX error: Metal heap allocation failed (code 7)")
        failed.processingRequests = failedRequest.map { [$0] }
        let entry = StatusOverviewModel.queue(
            meetings: [failed], liveProgress: [:], words: .iPhone(id: phone.id), now: now
        ).first
        XCTAssertEqual(entry?.line, "Studio Mac couldn’t finish")
        XCTAssertEqual(entry?.detail, "Something went wrong on Studio Mac. The recording is saved.")
        XCTAssertEqual(entry?.details, "MLX error: Metal heap allocation failed (code 7)")
        XCTAssertFalse(entry?.line.contains("MLX") ?? true)
        XCTAssertEqual(entry?.line(under: "Studio Mac"), "Couldn’t finish")

        // Over the link, the line names the Mac and nothing more.
        let live = LiveProgress(
            LinkProcessingProgress(
                meetingID: UUID(), phase: .failed, macName: "Studio Mac", detail: "MLX error"))
        XCTAssertEqual(live.line, "Studio Mac couldn’t finish")
    }

    func testAMacRecordingByItsPresenceShowsAsRecording() throws {
        var inputs = StatusOverviewInputs(words: .iPhone())
        inputs.mac = .recording(name: "Studio Mac", lastSeen: now)
        let line = try XCTUnwrap(StatusOverviewModel.macLine(inputs, now: now))
        XCTAssertEqual(line.title, "Studio Mac")
        XCTAssertEqual(line.text, "Recording")
        XCTAssertEqual(line.tone, .recording)
        inputs.queue = [
            StatusQueueEntry(
                id: UUID(), title: "A", line: "Waiting", requestedHere: true, progress: nil,
                isRunning: false)
        ]
        XCTAssertEqual(StatusOverviewModel.macLine(inputs, now: now)?.text, "Recording · 1 waiting")
    }

    // MARK: This iPhone's own work

    /// rd-10, ux-iphone-21: while this iPhone transcribes its own recording, or pauses it, the sheet says so in the
    /// words a Mac's home uses for its own queue, and lists the work in the This iPhone card; idle, nothing.
    func testBehaviorThisIPhonesOwnWorkHasALineAndRowsWhileItHasSome() {
        let phone = ProcessingRequest.Device(id: "this-phone", name: "Alex’s iPhone")
        var running = Meeting(title: "Interview")
        running.processingRequests = [
            ProcessingRequest(
                meetingID: running.id, mode: .newAudio, requestedBy: phone,
                createdAt: now.addingTimeInterval(-60))
        ]
        var waiting = Meeting(title: "Standup")
        waiting.processingRequests = [
            ProcessingRequest(
                meetingID: waiting.id, mode: .newAudio, requestedBy: phone,
                createdAt: now.addingTimeInterval(-30))
        ]
        let local = ProcessingStatus.LocalQueue(
            running: running.id, fraction: 0.4, queued: [waiting.id], stage: .transcribing)
        func queue(_ meeting: Meeting) -> ProcessingStatus.LocalQueue? {
            [running.id, waiting.id].contains(meeting.id) ? local : nil
        }

        let work = StatusOverviewModel.localWork(
            meetings: [waiting, running], local: queue, pause: nil, words: .iPhone(id: phone.id), now: now)
        XCTAssertEqual(
            work.entries.map(\.title), ["Interview", "Standup"], "what runs, then what waits")
        XCTAssertEqual(work.entries.map(\.line), ["Transcribing · 40%", "Waiting to transcribe"])
        XCTAssertEqual(work.entries.first?.progress, 0.4)
        var inputs = StatusOverviewInputs(words: .iPhone())
        inputs.local = work.line
        inputs.localQueue = work.entries
        let line = StatusOverviewModel.localLine(inputs, now: now)
        XCTAssertEqual(line?.title, "This iPhone")
        XCTAssertEqual(line?.text, "Transcribing · 40% · 1 waiting")
        XCTAssertEqual(line?.progress, 0.4)
        inputs.recording.recorders = [recorder()]
        inputs.mac = .connected(name: "Studio Mac")
        inputs.syncTone = .attention
        inputs.syncLine = "Signed out"
        XCTAssertEqual(
            StatusOverviewModel.lines(inputs, now: now).map(\.id), ["recorder-sc", "mac", "queue", "sync"],
            "this iPhone's line after the devices, before iCloud, as the Mac's home orders its own")
        inputs = StatusOverviewInputs(words: .iPhone())
        inputs.local = work.line
        inputs.localQueue = work.entries

        // Paused for the battery: when it goes on, also where it's narrow.
        let pausedQueue = ProcessingStatus.LocalQueue(
            running: nil, queued: [], paused: [running.id, waiting.id])
        let paused = StatusOverviewModel.localWork(
            meetings: [running, waiting], local: { _ in pausedQueue }, pause: .lowBattery,
            words: .iPhone(id: phone.id), now: now)
        XCTAssertEqual(
            paused.entries.map(\.line),
            ["Paused · Continues when iPhone is charging", "Paused · Continues when iPhone is charging"])
        inputs.local = paused.line
        XCTAssertEqual(
            StatusOverviewModel.localLine(inputs, now: now)?.text,
            "Paused · Continues when iPhone is charging")
        XCTAssertEqual(
            StatusOverviewModel.localLine(inputs, now: now)?.shortText, "Continues when iPhone is charging")

        // Nothing to do here: no line, and no card until the sheet is at full height.
        let idle = StatusOverviewModel.localWork(
            meetings: [running, waiting], local: { _ in nil }, pause: nil, words: .iPhone(id: phone.id), now: now)
        XCTAssertEqual(idle, StatusOverviewModel.LocalWork())
        inputs.local = idle.line
        inputs.localQueue = idle.entries
        XCTAssertNil(StatusOverviewModel.localLine(inputs, now: now))
        XCTAssertEqual(StatusOverviewModel.sections(inputs, now: now), [.iphone], "its card holds only the audio kept on it")
        XCTAssertEqual(StatusOverviewModel.lines(inputs, now: now), [])
    }

    /// A summary counting down to this iPhone, or running in the cloud, is this iPhone's own work, not a Mac's.
    func testBehaviorASummaryCountingDownHereIsThisIPhonesNotAMacs() throws {
        let id = UUID()
        let sonnet = CloudModel(
            provider: .anthropic, id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", tier: .balanced,
            inputPrice: 2, outputPrice: 10, priceIsEstimated: false, contextTokens: 200_000, rank: 1)
        // With the cloud on offer, a summary due here counts down before it starts.
        let options = SummaryOptions(thisDeviceCanSummarize: true, reachableMacs: [], cloud: sonnet)
        let here = SummaryPlacementPlanner(
            options: options, preferences: CloudSummaryPreferences(), at: now, waitsForMacs: true)
        guard case .countingDown(.thisDevice, _) = here.phase else {
            return XCTFail("counts down to this iPhone: \(here.phase)")
        }
        let meeting = Meeting(id: id, title: "Counting")
        let work = StatusOverviewModel.localWork(
            meetings: [meeting], local: { _ in nil }, pause: nil, words: .iPhone(id: "me"), planners: [id: here],
            now: now)
        let row = try XCTUnwrap(work.entries.first)
        XCTAssertEqual(
            row.line(under: nil, at: now.addingTimeInterval(2)),
            SummaryPlacementWords.countdown(seconds: here.secondsLeft(at: now.addingTimeInterval(2)) ?? 0),
            "under the This iPhone heading it doesn't name the place, and it ticks")
        XCTAssertEqual(row.actions.map(\.title), here.actions.map(\.title))
        XCTAssertNotNil(work.line.countdown)
        XCTAssertEqual(
            StatusOverviewModel.queue(
                meetings: [meeting], liveProgress: [:], words: .iPhone(id: "me"), planners: [id: here], now: now),
            [],
            "not in the Macs card")
        var inputs = StatusOverviewInputs(words: .iPhone())
        inputs.local = work.line
        XCTAssertEqual(StatusOverviewModel.localLine(inputs, now: now)?.tone, .calm, "a countdown is calm")
    }

    // MARK: The queue's failures

    /// ux-iphone-12: a conversation that couldn't finish offers Try Again with what it asked for, and stays in the
    /// queue only while it's recent; no speech never does.
    func testBehaviorAFailureOffersTryAgainAndGoesWhenItsOld() {
        let phone = ProcessingRequest.Device(id: "phone", name: "Alex’s iPhone")
        let studio = ProcessingRequest.Device(id: "studio", name: "Studio Mac")
        func failed(
            _ title: String, mode: ProcessingRequest.Mode = .newAudio, ago: TimeInterval,
            reason: String = "Out of memory"
        ) -> Meeting {
            var meeting = Meeting(
                title: title,
                tracks: [
                    RecordingTrack(
                        id: UUID(), source: .microphone, relativePath: "m.caf", fileName: "m.caf",
                        offset: 0, sha256: title)
                ])
            meeting.status = .imported
            meeting.processingRequests = [
                ProcessingRequest(
                    meetingID: meeting.id, mode: mode, requestedBy: phone,
                    createdAt: now.addingTimeInterval(-ago - 60)
                )
                .failed(by: studio, at: now.addingTimeInterval(-ago), reason: reason)
            ].compactMap { $0 }
            return meeting
        }
        let recent = failed("Recent", ago: 3_600)
        let summary = failed("Summary", mode: .summaryOnly, ago: 3_600)
        let old = failed("Old", ago: 8 * 86_400)
        let silent = failed("Silent", ago: 60, reason: "No speech was recognized.")
        let queue = StatusOverviewModel.queue(
            meetings: [recent, summary, old, silent], liveProgress: [:], words: .iPhone(id: phone.id), now: now)
        XCTAssertEqual(queue.map(\.title), ["Recent", "Summary"])
        XCTAssertEqual(queue[0].retry, .newAudio)
        XCTAssertEqual(
            queue[1].retry, .summaryOnly, "Try Again asks again for what failed, as the page does")
        XCTAssertTrue(queue[0].failed)
        XCTAssertEqual(queue[0].line(under: "Studio Mac"), "Couldn’t finish")
        XCTAssertEqual(
            queue[0].detail, "The speech model couldn’t start on Studio Mac. The recording is saved.",
            "in the plain words both apps give its kind")
        XCTAssertEqual(queue[0].details, "Out of memory")
        XCTAssertFalse(queue[0].requestedHere)
        XCTAssertEqual(
            queue[0].line(under: nil), "Studio Mac couldn’t finish",
            "at the top of the card, it names the Mac")
    }

    // MARK: The strip

    /// ui-iphone (P1): the strip at the library's foot says one line, and only one with something to say: what needs
    /// the person, then what records elsewhere, then what's working or counting down; nothing when all is calm.
    func testBehaviorTheStripSaysTheOneLineWithSomethingToSayOrNothing() {
        var inputs = StatusOverviewInputs(words: .iPhone())
        inputs.recording.recorders = [recorder()]
        inputs.mac = .seen(name: "Studio Mac", lastSeen: now)
        inputs.syncTone = .upToDate
        inputs.syncLine = "Up to date"
        XCTAssertEqual(
            StatusOverviewModel.lines(inputs, now: now).map(\.id), ["recorder-sc", "mac"],
            "a connected recorder and a Mac seen today, iCloud up to date")
        XCTAssertNil(
            StatusOverviewModel.strip(StatusOverviewModel.lines(inputs, now: now)),
            "connected and calm say nothing at rest")

        inputs.liveProgress = [
            LiveProgress(
                LinkProcessingProgress(
                    meetingID: UUID(), phase: .transcribing, fraction: 0.55, macName: "Studio Mac"))
        ]
        let working = StatusOverviewModel.strip(StatusOverviewModel.lines(inputs, now: now))
        XCTAssertEqual(working?.title, "Studio Mac")
        XCTAssertEqual(working?.text, "Transcribing · 55%")
        XCTAssertEqual(working?.progress, 0.55, "with its gradient line")

        inputs.recording.recorders = [recorder { $0.isListeningLive = true }]
        XCTAssertEqual(
            StatusOverviewModel.strip(StatusOverviewModel.lines(inputs, now: now))?.id, "recorder-sc",
            "what records elsewhere before what works")

        inputs.syncTone = .attention
        inputs.syncOff = true
        inputs.syncLine = "Signed out"
        let problem = StatusOverviewModel.strip(StatusOverviewModel.lines(inputs, now: now))
        XCTAssertEqual(problem?.id, "sync", "what needs the person first")
        XCTAssertEqual(problem?.text, "Signed out")
        XCTAssertEqual(problem?.tone, .attention)

        // A countdown is calm but is something to say; a paused queue that will continue isn't.
        var counting = StatusOverviewInputs(words: .iPhone())
        counting.local = QueueStatusWords.Queue(countdown: now.addingTimeInterval(12))
        XCTAssertEqual(StatusOverviewModel.strip(StatusOverviewModel.lines(counting, now: now))?.id, "queue")
        var paused = StatusOverviewInputs(words: .iPhone())
        paused.local = QueueStatusWords.Queue(waiting: 2, pause: .lowBattery)
        XCTAssertEqual(StatusOverviewModel.lines(paused, now: now).map(\.id), ["queue"])
        XCTAssertNil(StatusOverviewModel.strip(StatusOverviewModel.lines(paused, now: now)))
    }
}
