import DaybookCore
import DaybookLink
import Foundation
import XCTest
@testable import DaybookKit

/// One presentation of a conversation's processing for both apps: every status, on a Mac and on an iPhone, reads,
/// looks, and acts the same way, with only "this Mac" and "this iPhone" telling them apart, and only what a device
/// can do (`LocalCapabilities`) changing its actions.
final class ConversationStatusPresentationTests: XCTestCase {
    typealias Presentation = ConversationStatusPresentation
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let studio = ProcessingRequest.Device(id: "studio", name: "Studio Mac")
    private let alexPhone = ProcessingRequest.Device(id: "phone", name: "Alex’s iPhone")
    private var mac: Presentation.Inputs { .init(words: .mac(id: "studio"), local: .mac(missingModelBytes: 1_600_000_000)) }
    private var phone: Presentation.Inputs { .init(words: .iPhone(id: "phone"), local: .iPhone()) }

    private func recorded(transcribed: Bool = false) -> Meeting {
        let track = RecordingTrack(source: .microphone, relativePath: "Originals/a.m4a", fileName: "a.m4a", duration: 60)
        var meeting = Meeting(title: "Weekly product sync", tracks: [track])
        if transcribed {
            let segment = TranscriptSegment(trackID: track.id, start: 0, end: 4, text: "Ship it")
            meeting.transcripts = [TrackTranscript(trackID: track.id, segments: [segment])]
            meeting.unifiedTranscript = [segment]
        }
        return meeting
    }

    private func page(_ status: ProcessingStatus, _ meeting: Meeting? = nil, _ inputs: Presentation.Inputs) -> Presentation? {
        Presentation.page(status, meeting: meeting ?? recorded(), inputs: inputs, now: now)
    }

    private func row(_ status: ProcessingStatus, _ meeting: Meeting? = nil, _ inputs: Presentation.Inputs) -> ConversationRowStatus? {
        Presentation.row(status, meeting: meeting ?? recorded(), inputs: inputs, now: now)
    }

    // MARK: Every status on both devices

    func testBehaviorRecordedIsABoxWithTranscribeOnBothDevices() {
        for inputs in [mac, phone] {
            let shown = page(.recorded, nil, inputs)
            XCTAssertEqual(shown, Presentation(kind: .box(.accent), symbol: "waveform.circle.fill", title: "Not transcribed yet",
                                               actions: [.transcribe(newAudio: false)]), "\(inputs.words.here)")
            XCTAssertEqual(row(.recorded, nil, inputs), ConversationRowStatus(kind: .notTranscribed, text: "Not transcribed yet"))
        }
        XCTAssertEqual(ConversationRowStatus.Kind.notTranscribed.symbol, "waveform", "a waiting state's secondary symbol, not an unread dot")
        XCTAssertEqual(page(.recorded, recorded(transcribed: true), mac)?.title, "A new recording isn’t transcribed yet")
        XCTAssertEqual(page(.recorded, recorded(transcribed: true), mac)?.actions.first?.title, "Transcribe New Audio")
        XCTAssertNil(page(.recorded, Meeting(title: "Notes"), mac), "nothing to transcribe")
    }

    func testBehaviorTranscribedOffersSummarizeOnBothDevices() {
        for inputs in [mac, phone] {
            XCTAssertEqual(page(.transcribed, recorded(transcribed: true), inputs),
                           Presentation(kind: .line, symbol: "text.alignleft", title: "Not summarized yet", actions: [.summarize]))
            XCTAssertNil(row(.transcribed, recorded(transcribed: true), inputs), "the transcript reads: the row shows its preview")
        }
    }

    func testBehaviorWorkHereReadsAsTheDeviceCallsItself() {
        let here = ProcessingStatus.processing(.init(stage: .identifyingSpeakers, fraction: 0.4))
        let onMac = page(here, nil, mac)
        XCTAssertEqual(onMac?.title, "Identifying speakers · 40%", "never Transcribing while speakers are found")
        XCTAssertEqual(onMac?.progress, 0.4)
        XCTAssertEqual(onMac?.actions, [.pause], "a Mac pauses its own work")
        XCTAssertEqual(onMac?.phrase, "Identifying speakers")
        XCTAssertEqual(row(here, nil, mac), ConversationRowStatus(kind: .processing, text: "Identifying speakers · 40%", fraction: 0.4))

        let phoneHere = ProcessingStatus.processing(.init(stage: .identifyingSpeakers, fraction: 0.4, device: alexPhone))
        XCTAssertEqual(page(phoneHere, nil, phone)?.title, "Identifying speakers on this iPhone · 40%")
        XCTAssertEqual(page(phoneHere, nil, phone)?.symbol, "iphone")
        XCTAssertEqual(page(phoneHere, nil, phone)?.actions, [])
        XCTAssertEqual(row(phoneHere, nil, phone)?.text, "Identifying speakers on this iPhone · 40%")

        // Summarizing here stops rather than pauses.
        XCTAssertEqual(page(.processing(.init(stage: .summarizing, fraction: nil)), nil, mac)?.actions, [.stopSummary])
        XCTAssertEqual(page(.processing(.init(stage: .summarizing, fraction: nil)), nil, mac)?.title, "Summarizing…")
        XCTAssertEqual(page(.processing(.init(stage: .summarizing, fraction: nil)), nil, mac)?.isWorking, true)
    }

    func testBehaviorEachDevicesOwnQueueReadsAsItsOwnWork() {
        // A device's own queue names no device (`ProcessingStatus(_:queue:)`): it's this one, on both apps.
        let meeting = recorded()
        let status = ProcessingStatus(meeting, queue: .init(running: meeting.id, fraction: 0.4, stage: .transcribing), now: now)
        guard case .processing(let progress) = status else { return XCTFail("\(status)") }
        XCTAssertNil(progress.device)

        let onPhone = page(status, meeting, phone)
        XCTAssertEqual(onPhone?.title, "Transcribing on this iPhone · 40%")
        XCTAssertEqual(onPhone?.symbol, "iphone")
        XCTAssertEqual(onPhone?.actions, [], "an iPhone's queue runs itself")
        XCTAssertEqual(row(status, meeting, phone), ConversationRowStatus(kind: .processing, text: "Transcribing on this iPhone · 40%", fraction: 0.4))

        let onMac = page(status, meeting, mac)
        XCTAssertEqual(onMac?.title, "Transcribing · 40%")
        XCTAssertEqual(onMac?.symbol, "desktopcomputer")
        XCTAssertEqual(onMac?.actions, [.pause])
        XCTAssertEqual(row(status, meeting, mac)?.text, "Transcribing · 40%")
    }

    func testBehaviorAnotherDevicesWorkReadsTheSameEverywhereWithItsFigure() {
        let elsewhere = ProcessingStatus.processing(.init(stage: .transcribing, fraction: 0.4, device: studio))
        let words = DeviceWords.mac(id: "this-mac")
        let onMac = page(elsewhere, nil, Presentation.Inputs(words: words, local: .mac()))
        let onPhone = page(elsewhere, nil, phone)
        XCTAssertEqual(onMac?.title, "Transcribing on Studio Mac · 40%")
        XCTAssertEqual(onPhone?.title, onMac?.title)
        XCTAssertEqual(onPhone?.symbol, "desktopcomputer")
        XCTAssertEqual(onMac?.actions, [], "only the device doing it pauses it")
        XCTAssertEqual(row(elsewhere, nil, phone), ConversationRowStatus(kind: .processing, text: "Transcribing on Studio Mac · 40%", fraction: 0.4))
        XCTAssertEqual(row(elsewhere, nil, Presentation.Inputs(words: words, local: .mac()))?.text, "Transcribing on Studio Mac · 40%")
        // With no figure yet, a spinner.
        let silent = page(.processing(.init(stage: .transcribing, fraction: nil, device: studio)), nil, phone)
        XCTAssertEqual(silent?.title, "Transcribing on Studio Mac")
        XCTAssertEqual(silent?.isWorking, true)
    }

    func testBehaviorQueuedHereSaysWhatItWaitsFor() {
        var inputs = mac
        inputs.runningTitle = "Roadmap review"
        XCTAssertEqual(page(.requested(.queued(position: 0, after: UUID())), nil, inputs),
                       Presentation(kind: .line, symbol: "clock", title: "Waiting to transcribe after “Roadmap review”", actions: [.cancel]))
        inputs.queueWaitsForDownload = true
        XCTAssertEqual(page(.requested(.queued(position: 0, after: nil)), nil, inputs)?.title, "Waiting to transcribe after the download")
        // Position 0 is next: two ahead of position 2, and the conversation running now, when one is.
        XCTAssertEqual(page(.requested(.queued(position: 2, after: nil)), nil, inputs)?.title, "Waiting to transcribe · 2 ahead")
        XCTAssertEqual(page(.requested(.queued(position: 2, after: UUID())), nil, inputs)?.title, "Waiting to transcribe · 3 ahead")
        XCTAssertEqual(page(.requested(.queued(position: 0, after: nil)), nil, phone)?.actions, [], "an iPhone's queue runs itself")
        XCTAssertEqual(row(.requested(.queued(position: 0, after: nil)), nil, inputs), ConversationRowStatus(kind: .waiting, text: "Waiting to transcribe"))
    }

    func testBehaviorWaitingForModelsOffersTheDownloadWhereModelsAreManaged() {
        let box = page(.requested(.models), nil, mac)
        XCTAssertEqual(box, Presentation(kind: .box(.accent), symbol: "arrow.down.circle.fill", title: "Download models to transcribe this conversation",
                                         detail: "1.6 GB", actions: [.chooseModels, .downloadModels(bytes: 1_600_000_000)]))
        XCTAssertEqual(box?.actions.map(\.title), ["Choose Models…", "Download"])
        var downloading = mac
        downloading.local.download = .init(name: "Parakeet Ultra", fraction: 0.42)
        XCTAssertEqual(page(.requested(.models), nil, downloading),
                       Presentation(kind: .line, symbol: "arrow.down.circle", title: "Downloading models · 42%", progress: 0.42,
                                    actions: [.cancelDownload]), "one phrase, never a model at a time")
        XCTAssertEqual(page(.requested(.models), nil, phone), Presentation(kind: .line, symbol: "arrow.down.circle", title: "Waiting for models"))
        XCTAssertEqual(row(.requested(.models), nil, mac), ConversationRowStatus(kind: .waitingForModels, text: "Waiting for models"))
        XCTAssertEqual(ConversationRowStatus.Kind.waitingForModels.symbol, "arrow.down.circle")
    }

    /// A Mac's downloads in the one phrase every surface uses (uxf-06, uxf-07, uxf-12): the whole set arriving with the
    /// total, waiting for Wi‑Fi with Download to go on now, and a download that stopped as a problem with Try Again.
    func testBehaviorAMacsDownloadsReadAsOneSetAndAFailureOffersTryAgain() {
        var inputs = mac
        inputs.local = .mac(missingModelBytes: 7_600_000_000, models: .downloading(done: 3_800_000_000, total: 7_600_000_000))
        XCTAssertEqual(page(.requested(.models), nil, inputs),
                       Presentation(kind: .line, symbol: "arrow.down.circle", title: "Downloading models · 50%", detail: "3.8 of 7.6 GB",
                                    progress: 0.5, actions: [.cancelDownload]))

        inputs.local.models = .waitingForWiFi(bytes: 7_600_000_000)
        let waiting = page(.requested(.models), nil, inputs)
        XCTAssertEqual(waiting, Presentation(kind: .line, symbol: "wifi", title: "Downloading models · Waiting for Wi‑Fi", detail: "7.6 GB",
                                             actions: [.downloadModels(bytes: 7_600_000_000)]))
        XCTAssertEqual(waiting?.actions.map(\.title), ["Download"])

        inputs.local.models = .failed(model: "Gemma 4 12B 4-bit", bytes: 7_600_000_000)
        let failed = page(.requested(.models), nil, inputs)
        XCTAssertEqual(failed, Presentation(kind: .box(.problem), symbol: "exclamationmark.triangle.fill", title: "Couldn’t download Gemma 4 12B 4-bit",
                                            actions: [.downloadModels(bytes: 7_600_000_000, again: true)]))
        XCTAssertEqual(failed?.actions.map(\.title), ["Try Again"])
        XCTAssertEqual(failed?.actions.first?.isPrimary, true)
        XCTAssertEqual(row(.requested(.models), nil, inputs), ConversationRowStatus(kind: .waitingForModels, text: "Waiting for models"))
    }

    func testBehaviorPausedLooksTheSameAndSaysWhyOrResumes() {
        XCTAssertEqual(page(.requested(.paused), nil, mac), Presentation(kind: .line, symbol: "pause.circle", title: "Paused", actions: [.resume]))
        var charging = phone
        charging.pause = .lowBattery
        XCTAssertEqual(page(.requested(.paused), nil, charging),
                       Presentation(kind: .line, symbol: "pause.circle", title: "Paused", detail: "Continues when iPhone is charging"))
        for inputs in [mac, phone] {
            let paused = row(.requested(.paused), nil, inputs)
            XCTAssertEqual(paused, ConversationRowStatus(kind: .paused, text: "Paused"))
            XCTAssertEqual(paused?.kind.symbol, "pause.circle", "the same glyph on both")
        }
    }

    func testBehaviorARequestWaitingForAMacSaysWhetherOneIsAround() {
        let request = ProcessingRequest(meetingID: UUID(), mode: .newAudio, requestedBy: alexPhone, createdAt: now)
        var inputs = phone
        inputs.mac = .seen(name: "Studio Mac", at: now.addingTimeInterval(-2 * 3600))
        XCTAssertEqual(page(.requested(.device(request)), nil, inputs),
                       Presentation(kind: .line, symbol: "clock", title: "Waiting for your Mac", detail: "Last seen 2 h ago", actions: [.cancelRequest(request.id)]))
        inputs.mac = .connected("Studio Mac")
        XCTAssertEqual(page(.requested(.device(request)), nil, inputs)?.title, "Waiting for Studio Mac")
        XCTAssertNil(page(.requested(.device(request)), nil, inputs)?.detail)
        inputs.mac = .noMac
        XCTAssertEqual(page(.requested(.device(request)), nil, inputs)?.detail, "No Mac has synced this library yet. Open Daybook on your Mac.")
        // A Mac that isn't set up says where to finish, as the iPhone's Settings does.
        inputs.mac = .notProcessing("Studio Mac")
        XCTAssertEqual(page(.requested(.device(request)), nil, inputs)?.detail,
                       "Studio Mac isn’t set up to transcribe. Finish in Daybook › Settings on Studio Mac.")
        XCTAssertEqual(row(.requested(.device(request)), nil, phone), ConversationRowStatus(kind: .waiting, text: "Waiting for your Mac"))

        // A Mac that can take it offers to, once.
        let onMac = page(.requested(.device(request)), nil, Presentation.Inputs(words: .mac(id: "this-mac"), local: .mac()))
        XCTAssertEqual(onMac, Presentation(kind: .box(.accent), symbol: "waveform.circle.fill", title: "Requested from Alex’s iPhone",
                                           actions: [.transcribe(newAudio: false)]))
        XCTAssertEqual(row(.requested(.device(request)), nil, Presentation.Inputs(words: .mac(id: "this-mac"), local: .mac()))?.text,
                       "Requested from Alex’s iPhone")

        // A Summarize request says "again" only with a summary already.
        let first = ProcessingRequest(meetingID: UUID(), mode: .summaryOnly, requestedBy: alexPhone, createdAt: now)
        XCTAssertEqual(page(.requested(.device(first)), recorded(transcribed: true), phone),
                       Presentation(kind: .line, symbol: "clock", title: "Waiting for your Mac to summarize", actions: [.cancelRequest(first.id)]))
        XCTAssertEqual(row(.requested(.device(first)), recorded(transcribed: true), phone),
                       ConversationRowStatus(kind: .waiting, text: "Waiting for your Mac to summarize"))
        var summarized = recorded(transcribed: true)
        summarized.summary = MeetingSummary(overview: "Done")
        let again = ProcessingRequest(meetingID: summarized.id, mode: .summaryOnly, requestedBy: alexPhone, createdAt: now)
        XCTAssertEqual(page(.requested(.device(again)), summarized, phone)?.title, "Waiting for your Mac to summarize again")
        // Another device's request: nothing here to take back.
        XCTAssertEqual(page(.requested(.device(again)), summarized, Presentation.Inputs(words: .iPhone(id: "other"), local: .iPhone()))?.actions, [])
    }

    func testBehaviorAMacLastSeenAWhileAgoSaysHowLongAgo() {
        XCTAssertEqual(Presentation.MacStanding.ago(30), "1 min ago", "never 0 min")
        XCTAssertEqual(Presentation.MacStanding.ago(5 * 60), "5 min ago")
        XCTAssertEqual(Presentation.MacStanding.ago(2 * 3600), "2 h ago")
        XCTAssertEqual(Presentation.MacStanding.ago(47 * 3600), "47 h ago")
        XCTAssertEqual(Presentation.MacStanding.ago(3 * 86_400), "3 days ago")
        // Seen a moment ago: named, with nothing more to say.
        XCTAssertNil(Presentation.MacStanding.seen(name: "Studio Mac", at: now.addingTimeInterval(-60)).detail(at: now))
        XCTAssertEqual(Presentation.MacStanding.seen(name: "Studio Mac", at: now.addingTimeInterval(-60)).present(at: now), "Studio Mac")
        XCTAssertEqual(Presentation.MacStanding.noMac.detail(at: now), Presentation.MacStanding.noMacLine)
    }

    func testBehaviorAnUpgradeWaitingForItsMacUsesItsShortLineInRows() {
        let upgrade = ProcessingRequest.Upgrade(role: "transcription", model: "parakeet/ultra", quality: 90, device: studio)
        let request = ProcessingRequest(meetingID: UUID(), mode: .fullRetranscription, requestedBy: alexPhone, createdAt: now, upgrade: upgrade)
        let meeting = recorded(transcribed: true)
        for inputs in [mac, phone] {
            XCTAssertEqual(page(.requested(.device(request)), meeting, inputs)?.title, "Waiting for Studio Mac to upgrade the transcript")
            XCTAssertEqual(row(.requested(.device(request)), meeting, inputs)?.text, "Waiting for Studio Mac")
        }
        // Asked on this iPhone: Cancel brings the offer back. The cloud on offer doesn't make it Use the Cloud's wait.
        var cloud = phone
        cloud.placement.cloudOffered = true
        XCTAssertEqual(page(.requested(.device(request)), meeting, cloud),
                       Presentation(kind: .line, symbol: "clock", title: "Waiting for Studio Mac to upgrade the transcript",
                                    actions: [.cancelRequest(request.id)]))

        // New audio comes first: the page and the row both say what happens to it, not the upgrade.
        var arrived = meeting
        arrived.tracks.append(RecordingTrack(source: .soundcore, relativePath: "Originals/b.wav", fileName: "b.wav", duration: 60))
        XCTAssertTrue(arrived.hasUntranscribedAudio)
        let other = Presentation.Inputs(words: .mac(id: "this-mac"), local: .mac())
        for inputs in [mac, phone, other] {
            let shown = page(.requested(.device(request)), arrived, inputs)
            XCTAssertNotEqual(shown?.title, "Waiting for Studio Mac to upgrade the transcript")
            XCTAssertEqual(row(.requested(.device(request)), arrived, inputs)?.text, shown?.title, "\(inputs.words.here)")
        }
        XCTAssertEqual(row(.requested(.device(request)), arrived, other)?.text, "Requested from Alex’s iPhone")
    }

    func testBehaviorAFailureReadsTheSameWordsAndOffersItsFix() {
        let transcribing = ProcessingStatus.Failure(reason: "Download Parakeet Ultra in Models before processing.", hadTranscripts: false,
                                                    device: studio, kind: .modelsMissing)
        // Studio Mac failed: on Studio Mac itself, Download; anywhere else, Try Again.
        XCTAssertEqual(page(.failed(transcribing), nil, mac),
                       Presentation(kind: .box(.problem), symbol: "exclamationmark.triangle.fill", title: "Couldn’t finish transcribing",
                                    detail: "The models it needs aren’t on this Mac yet. The recording is saved.",
                                    actions: [.details(transcribing.reason), .downloadModels(bytes: 1_600_000_000)]))
        XCTAssertEqual(page(.failed(transcribing), nil, phone),
                       Presentation(kind: .box(.problem), symbol: "exclamationmark.triangle.fill", title: "Couldn’t finish transcribing",
                                    detail: "The models it needs aren’t on Studio Mac yet. The recording is saved.",
                                    actions: [.details(transcribing.reason), .tryAgain(.newAudio)]))

        // Once the models are here, the failure on this Mac offers to run again.
        var downloaded = mac
        downloaded.local.missingModelBytes = 0
        XCTAssertEqual(page(.failed(transcribing), nil, downloaded)?.actions, [.details(transcribing.reason), .tryAgain(.newAudio)])
        XCTAssertEqual(page(.failed(transcribing), Meeting(title: "Notes"), downloaded)?.actions,
                       [.details(transcribing.reason), .chooseModels], "nothing to run again: choose models")

        // No speech: nothing to retry.
        let silent = ProcessingStatus.Failure(reason: "No speech was recognized.", hadTranscripts: false, kind: .noSpeech)
        for inputs in [mac, phone] {
            XCTAssertEqual(page(.failed(silent), nil, inputs)?.actions, [.details("No speech was recognized.")])
            XCTAssertEqual(page(.failed(silent), nil, inputs)?.title, "No speech in this recording")
            XCTAssertEqual(row(.failed(silent), nil, inputs), ConversationRowStatus(kind: .failed, text: "No speech"))
        }

        // The cloud: a key's problem goes to Cloud Settings, and the summary can run here or on a Mac instead.
        let key = ProcessingStatus.Failure(reason: "Anthropic didn’t accept this key.", hadTranscripts: true, kind: .cloud(.badKey))
        XCTAssertEqual(page(.failed(key), recorded(transcribed: true), mac)?.actions, [.cloudSettings, .summarizeHere("This Mac")])
        XCTAssertEqual(page(.failed(key), recorded(transcribed: true), phone)?.actions, [.cloudSettings, .useYourMac])
        let offline = ProcessingStatus.Failure(reason: "You’re offline.", hadTranscripts: true, kind: .cloud(.offline))
        XCTAssertEqual(page(.failed(offline), recorded(transcribed: true), phone)?.actions, [.tryAgain(.summaryOnly), .useYourMac])

        // The summary model couldn't start here: choose another, or try again.
        let memory = ProcessingStatus.Failure(reason: "Out of memory", hadTranscripts: true, kind: .modelCouldNotStart)
        XCTAssertEqual(page(.failed(memory), recorded(transcribed: true), mac)?.actions, [.chooseModels, .tryAgain(.summaryOnly)])
        XCTAssertEqual(page(.failed(memory), recorded(transcribed: true), mac)?.detail,
                       "The summary model couldn’t start on this Mac. The recording is saved.")

        // At most two actions, always.
        for kind: ProcessingRequest.FailureKind in [.noSpeech, .modelsMissing, .modelCouldNotStart, .cloud(.badKey), .cloud(.busy), .plainReason, .other] {
            for inputs in [mac, phone] {
                let failure = ProcessingStatus.Failure(reason: "Words", hadTranscripts: true, device: studio, kind: kind)
                XCTAssertLessThanOrEqual(page(.failed(failure), recorded(transcribed: true), inputs)?.actions.count ?? 0, 2)
            }
        }
    }

    func testBehaviorWaitingForARecordingOffersNotToWait() {
        let awaited = [AwaitedRecording(deviceName: "Alex’s iPhone", deviceKind: DaybookPhoneIntegration.id, since: now)]
        for inputs in [mac, phone] {
            XCTAssertEqual(page(.awaitingRecordings(awaited), nil, inputs),
                           Presentation(kind: .line, symbol: "clock", title: "Waiting for audio from Alex’s iPhone", actions: [.dontWait]))
            XCTAssertEqual(row(.awaitingRecordings(awaited), nil, inputs), ConversationRowStatus(kind: .waiting, text: "Waiting for iPhone audio"))
        }
        // Where it is, when this device knows: one clause after the wait.
        var known = mac
        known.arrivals = [awaited[0].arrivalKey: .sending(0.4)]
        XCTAssertEqual(page(.awaitingRecordings(awaited), nil, known)?.title, "Waiting for audio from Alex’s iPhone · Sending 40%")
    }

    /// Past its wait, a recording that never came is a problem box with both ways on, and the row says so.
    func testBehaviorAudioThatDidntArriveOffersDontWaitAndWaitAgain() {
        let missing = [AwaitedRecording(deviceName: "Alex’s iPhone", deviceKind: DaybookPhoneIntegration.id, since: now)]
        for inputs in [mac, phone] {
            XCTAssertEqual(page(.missingRecordings(missing), nil, inputs),
                           Presentation(kind: .box(.problem), symbol: "exclamationmark.triangle.fill", title: "Alex’s iPhone audio didn’t arrive",
                                        actions: [.dontWait, .waitAgain]))
            XCTAssertEqual(row(.missingRecordings(missing), nil, inputs), ConversationRowStatus(kind: .failed, text: "iPhone audio didn’t arrive"))
        }
        XCTAssertEqual(Presentation.Action.waitAgain.title, "Wait Again")
    }

    /// The iPhone's own recording a Mac waits for, not on its way yet: the line the Mac's page matches.
    func testBehaviorTheIPhonesUnsentRecordingIsSaid() {
        var inputs = phone
        inputs.unsent = .storageFull
        XCTAssertEqual(page(.done, nil, inputs),
                       Presentation(kind: .line, symbol: "exclamationmark.icloud", title: "This iPhone’s audio can’t be sent · iCloud storage is full"))
        inputs.unsent = .sending(nil)
        XCTAssertEqual(page(.recorded, recorded(), inputs)?.title, "Sending this iPhone’s audio to your Mac")
    }

    func testBehaviorDoneSaysNothingButAnUpgradeOrANote() {
        XCTAssertNil(page(.done, nil, mac))
        var note = recorded()
        note.errorMessage = "Speaker detection failed for a.m4a."
        XCTAssertEqual(page(.done, note, phone), Presentation(kind: .box(.info), symbol: "info.circle.fill", title: "Speaker detection failed for a.m4a.",
                                                            actions: [.dismiss]))
        let offer = UpgradeOffer(role: .transcription, place: .mac(studio), model: "parakeet/ultra", quality: 90, current: "whisper/base", currentQuality: 60)
        var inputs = phone
        inputs.upgrade = offer
        XCTAssertEqual(page(.done, nil, inputs), Presentation(kind: .line, symbol: "arrow.up.circle", title: "Upgrade transcript on Studio Mac",
                                                             actions: [.upgrade(offer), .dismissUpgrade(offer)]))
        XCTAssertNil(row(.done, nil, inputs), "rows never offer an upgrade")
    }

    // MARK: Where the summary runs, the link, and this device's own states

    func testBehaviorWhereTheSummaryRunsComesFirst() {
        var inputs = mac
        inputs.placement.run = .thisDevice
        XCTAssertEqual(page(.transcribed, recorded(transcribed: true), inputs),
                       Presentation(kind: .line, symbol: nil, title: "Summarizing on this Mac", isWorking: true, actions: [.stopSummary]))
        XCTAssertEqual(row(.transcribed, recorded(transcribed: true), inputs), ConversationRowStatus(kind: .processing, text: "Summarizing on this Mac"))

        var cloud = phone
        cloud.placement.cloudOffered = true
        let request = ProcessingRequest(meetingID: UUID(), mode: .summaryOnly, requestedBy: alexPhone, createdAt: now)
        XCTAssertEqual(page(.requested(.device(request)), recorded(transcribed: true), cloud)?.title, "Waiting for a Mac to summarize")
        XCTAssertEqual(page(.requested(.device(request)), recorded(transcribed: true), cloud)?.actions, [.placement(.useCloud), .cancelRequest(request.id)])
        // Without the cloud, the request reads as any wait for a Mac.
        XCTAssertEqual(page(.requested(.device(request)), recorded(transcribed: true), phone)?.title, "Waiting for your Mac to summarize")
        XCTAssertEqual(page(.requested(.device(request)), recorded(transcribed: true), phone)?.actions, [.cancelRequest(request.id)])

        // This iPhone's own summary with no Mac reachable and the cloud on offer: it waits, with Use the Cloud, saying
        // when a Mac was last seen.
        let sonnet = CloudModel(provider: .anthropic, id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", tier: .balanced,
                                inputPrice: 2, outputPrice: 10, priceIsEstimated: false, contextTokens: 200_000, rank: 1)
        let waiting = SummaryPlacementPlanner(options: SummaryOptions(thisDeviceCanSummarize: false, reachableMacs: [], cloud: sonnet),
                                              preferences: CloudSummaryPreferences(), at: now)
        XCTAssertEqual(waiting.phase, .waitingForMac)
        var placed = phone
        placed.placement = .init(planner: waiting, cloudOffered: true)
        placed.mac = .seen(name: "Studio Mac", at: now.addingTimeInterval(-2 * 3600))
        XCTAssertEqual(page(.transcribed, recorded(transcribed: true), placed),
                       Presentation(kind: .line, symbol: "clock", title: "Waiting for a Mac to summarize", detail: "Last seen 2 h ago",
                                    actions: [.placement(.useCloud)]))
    }

    func testBehaviorACloudSummaryOnAMacsQueueOffersStopWithItsBar() {
        let sonnet = CloudModel(provider: .anthropic, id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", tier: .balanced,
                                inputPrice: 2, outputPrice: 10, priceIsEstimated: false, contextTokens: 200_000, rank: 1)
        var cloud = SummaryPlacementPlanner(options: SummaryOptions(thisDeviceCanSummarize: true, reachableMacs: [], cloud: sonnet),
                                            preferences: CloudSummaryPreferences(), at: now)
        XCTAssertTrue(cloud.perform(.useCloud, at: now))
        let transcribed = recorded(transcribed: true)
        var inputs = mac
        inputs.placement = .queue(cloud, running: true)
        // Before the cloud reports a figure: a spinner, and Stop.
        let starting = ProcessingStatus.processing(.init(stage: .summarizing, fraction: 0))
        XCTAssertEqual(page(starting, transcribed, inputs),
                       Presentation(kind: .line, symbol: nil, title: "Summarizing with Claude Sonnet 5.5", isWorking: true, actions: [.stopSummary]))
        // Then its figure and bar, still with Stop; the line animates only when its words change.
        let working = ProcessingStatus.processing(.init(stage: .summarizing, fraction: 0.35))
        let line = page(working, transcribed, inputs)
        XCTAssertEqual(line, Presentation(kind: .line, symbol: "cloud", title: "Summarizing with Claude Sonnet 5.5 · 35%", progress: 0.35,
                                          actions: [.stopSummary]))
        XCTAssertEqual(line?.phrase, "Summarizing with Claude Sonnet 5.5")
        XCTAssertEqual(Presentation.Action.stopSummary.title, "Stop")

        // Not the job running now: no Stop for work the queue hasn't started.
        inputs.placement = .queue(cloud, running: false)
        XCTAssertNil(inputs.placement.run)
        XCTAssertEqual(page(.requested(.queued(position: 0, after: nil)), transcribed, inputs)?.actions, [])

        // Started on the Mac itself: the queue's own line says it, with Stop.
        let here = SummaryPlacementPlanner(options: SummaryOptions(thisDeviceCanSummarize: true, reachableMacs: [], cloud: nil),
                                           preferences: CloudSummaryPreferences(), at: now, immediately: true)
        inputs.placement = .queue(here, running: true)
        XCTAssertNil(inputs.placement.run)
        XCTAssertEqual(page(working, transcribed, inputs)?.title, "Summarizing · 35%")
        XCTAssertEqual(page(working, transcribed, inputs)?.actions, [.stopSummary])
    }

    func testBehaviorAMacsLiveProgressOverTheLinkComesBeforeTheSyncedClaim() {
        var inputs = phone
        inputs.link = .init(phase: .identifyingSpeakers, fraction: 0.62, device: "Studio Mac")
        let claimed = ProcessingStatus.processing(.init(stage: .transcribing, fraction: 0.1, device: studio))
        XCTAssertEqual(page(claimed, nil, inputs)?.title, "Identifying speakers on Studio Mac · 62%")
        XCTAssertEqual(row(claimed, nil, inputs)?.text, "Identifying speakers on Studio Mac · 62%")
        inputs.link = .init(phase: .queued, device: "Studio Mac")
        XCTAssertEqual(page(.requested(.device(ProcessingRequest(meetingID: UUID(), mode: .newAudio, requestedBy: alexPhone))), nil, inputs)?.title,
                       "In line on Studio Mac")
        // A Mac's countdown to summarizing, with the choices sent to it.
        let message = LinkProcessingProgress(meetingID: UUID(), phase: .summaryCountdown, macName: "Studio Mac",
                                             countdown: LinkSummaryCountdown(secondsLeft: 12, cloudOffered: true))
        inputs.link = .init(message, receivedAt: now, answerable: true)
        let countdown = page(.transcribed, recorded(transcribed: true), inputs)
        XCTAssertEqual(countdown?.title, "Summarizing on Studio Mac in 12 s")
        XCTAssertEqual(countdown?.title(at: now.addingTimeInterval(5)), "Summarizing on Studio Mac in 7 s")
        XCTAssertEqual(countdown?.actions, [.placement(.useCloud), .placement(.startNow)])
        XCTAssertEqual(countdown?.phrase, "Summarizing in")
        XCTAssertEqual(row(.transcribed, recorded(transcribed: true), inputs)?.text(at: now.addingTimeInterval(2)), "Summarizing in 10 s")
    }

    func testBehaviorRowsSayRecordingPlayingAndJustFinished() {
        var inputs = mac
        inputs.isRecording = true
        XCTAssertNil(page(.recorded, nil, inputs), "the capture speaks while recording")
        XCTAssertEqual(row(.recorded, nil, inputs), ConversationRowStatus(kind: .recording, text: "Recording now"))
        inputs.isRecording = false
        inputs.isPlaying = true
        XCTAssertEqual(row(.done, nil, inputs), ConversationRowStatus(kind: .playing, text: nil))
        XCTAssertEqual(ConversationRowStatus.Kind.playing.symbol, "waveform")
        inputs.isPlaying = false
        inputs.justFinished = true
        XCTAssertEqual(row(.done, nil, inputs)?.kind, .justFinished)
        XCTAssertEqual(row(.done, nil, inputs)?.kind.symbol, "checkmark.circle.fill")
    }

    /// "Needs your Mac to summarize" offers this iPhone's own summary model where it could run one (P3, uxf-09): the
    /// download beside the fact, then how the whole set comes, then, for the summary it asked of a Mac, Summarize on This
    /// iPhone. Without the memory for one, or with processing here off, the fact stays bare; a Mac never offers it.
    func testBehaviorNeedsYourMacOffersThisIPhonesSummaryModelWhereItCouldRunOne() {
        let request = ProcessingRequest(meetingID: UUID(), mode: .summaryOnly, requestedBy: alexPhone, createdAt: now)
        let transcribed = recorded(transcribed: true)
        var inputs = phone
        inputs.mac = .noMac
        inputs.local = .iPhone(processesHere: true, summaryModelBytes: 3_580_000_000)
        let asked = page(.requested(.device(request)), transcribed, inputs)
        XCTAssertEqual(asked, Presentation(kind: .line, symbol: "desktopcomputer", title: "Needs your Mac to summarize",
                                           detail: Presentation.MacStanding.noMacLine,
                                           actions: [.downloadSummaryModel(bytes: 3_580_000_000), .cancelRequest(request.id)]))
        XCTAssertEqual(asked?.actions.first?.title, "Download · 3.6 GB")
        XCTAssertEqual(asked?.actions.first?.isPrimary, false, "a link on the line, as Cancel is")
        XCTAssertEqual(page(.transcribed, transcribed, inputs),
                       Presentation(kind: .line, symbol: "desktopcomputer", title: "Needs your Mac to summarize",
                                    detail: Presentation.MacStanding.noMacLine, actions: [.downloadSummaryModel(bytes: 3_580_000_000)]))
        XCTAssertEqual(row(.requested(.device(request)), transcribed, inputs)?.text, "Needs your Mac to summarize")

        // Asked for: the whole set's download (here, after the transcription models), with Cancel; the row waits for it.
        inputs.local = .iPhone(processesHere: true, models: .downloading(done: 1_772_000_000, total: 4_430_000_000), summaryModelAsked: true)
        let arriving = Presentation(kind: .line, symbol: "arrow.down.circle", title: "Downloading models · 40%", detail: "1.8 of 4.4 GB",
                                    progress: 0.4, actions: [.cancelDownload])
        XCTAssertEqual(page(.requested(.device(request)), transcribed, inputs), arriving)
        XCTAssertEqual(page(.transcribed, transcribed, inputs), arriving)
        XCTAssertEqual(row(.requested(.device(request)), transcribed, inputs), ConversationRowStatus(kind: .waitingForModels, text: "Waiting for models"))
        // Waiting for Wi‑Fi: an iPhone's downloads keep to it unless Settings allows cellular, so Cancel, not Download.
        inputs.local.models = .waitingForWiFi(bytes: 3_580_000_000)
        XCTAssertEqual(page(.transcribed, transcribed, inputs),
                       Presentation(kind: .line, symbol: "wifi", title: "Downloading models · Waiting for Wi‑Fi", detail: "3.6 GB",
                                    actions: [.cancelDownload]))
        inputs.local.models = .failed(model: "Gemma 4 E2B", bytes: 3_580_000_000)
        XCTAssertEqual(page(.transcribed, transcribed, inputs)?.title, "Couldn’t download Gemma 4 E2B")
        XCTAssertEqual(page(.transcribed, transcribed, inputs)?.actions, [.downloadModels(bytes: 3_580_000_000, again: true)])

        // Here: the summary it asked of a Mac, with no Mac around, can be made here now.
        inputs.local = .iPhone(processesHere: true, summarizes: true)
        XCTAssertEqual(page(.requested(.device(request)), transcribed, inputs)?.actions, [.summarizeHere("This iPhone"), .cancelRequest(request.id)])
        inputs.mac = .seen(name: "Studio Mac", at: now.addingTimeInterval(-3600))
        XCTAssertEqual(page(.requested(.device(request)), transcribed, inputs)?.actions, [.cancelRequest(request.id)], "a Mac will take it")
        inputs.mac = .noMac

        // No summary model fits, or processing here is off: a bare fact, never a promise.
        inputs.local = .iPhone(processesHere: true)
        XCTAssertEqual(page(.transcribed, transcribed, inputs)?.actions, [])
        inputs.local = .iPhone(processesHere: false, summaryModelBytes: 3_580_000_000)
        XCTAssertEqual(page(.transcribed, transcribed, inputs)?.actions, [])
        XCTAssertEqual(page(.requested(.device(request)), transcribed, inputs)?.actions, [.cancelRequest(request.id)])
        // A Mac's summarizer is its queue's.
        var onMac = mac
        onMac.mac = .noMac
        onMac.local = Presentation.LocalCapabilities(processesHere: true, transcribes: true, summarizes: false, controlsQueue: true,
                                                    managesModels: true, summaryModelBytes: 3_580_000_000)
        XCTAssertEqual(page(.transcribed, transcribed, onMac)?.actions, [])
    }

    /// An iPhone's own downloads read as the one set a Mac's do, never a model at a time: the transcript's wait says the
    /// whole set's figure and total, Wi‑Fi with Cancel, and a stopped download with Try Again.
    func testBehaviorAniPhonesOwnDownloadsReadAsTheWholeSet() {
        let request = ProcessingRequest(meetingID: UUID(), mode: .newAudio, requestedBy: alexPhone, createdAt: now)
        var inputs = phone
        inputs.mac = .noMac
        inputs.local = .iPhone(processesHere: true, download: .init(name: "Parakeet Ultra", fraction: 0.4),
                               models: .downloading(done: 1_772_000_000, total: 4_430_000_000))
        XCTAssertEqual(page(.requested(.device(request)), nil, inputs),
                       Presentation(kind: .line, symbol: "arrow.down.circle", title: "Downloading models · 40%", detail: "1.8 of 4.4 GB",
                                    progress: 0.4, actions: [.cancelDownload]))
        inputs.local = .iPhone(processesHere: true, download: .init(name: "Parakeet Ultra", fraction: 0), models: .waitingForWiFi(bytes: 852_000_000))
        XCTAssertEqual(page(.requested(.device(request)), nil, inputs),
                       Presentation(kind: .line, symbol: "wifi", title: "Downloading models · Waiting for Wi‑Fi", detail: "852 MB",
                                    actions: [.cancelDownload]))
        XCTAssertEqual(row(.requested(.device(request)), nil, inputs), ConversationRowStatus(kind: .waitingForModels, text: "Waiting for models"))
        inputs.local = .iPhone(processesHere: true, missingModelBytes: 852_000_000, models: .failed(model: "Parakeet Ultra", bytes: 852_000_000))
        XCTAssertEqual(page(.requested(.device(request)), nil, inputs),
                       Presentation(kind: .box(.problem), symbol: "exclamationmark.triangle.fill", title: "Couldn’t download Parakeet Ultra",
                                    actions: [.downloadModels(bytes: 852_000_000, again: true)]))
        inputs.local = .iPhone(processesHere: true, missingModelBytes: 852_000_000)
        XCTAssertEqual(page(.requested(.device(request)), nil, inputs)?.title, "Download models to transcribe this conversation")
    }

    func testBehaviorActionTitlesAreTheInterfacesWords() {
        XCTAssertEqual(Presentation.Action.tryAgain(.newAudio).title, "Try Again")
        XCTAssertEqual(Presentation.Action.details("x").title, "Details…")
        XCTAssertEqual(Presentation.Action.dontWait.title, "Don’t Wait")
        XCTAssertEqual(Presentation.Action.placement(.useCloud).title, "Use the Cloud")
        XCTAssertTrue(Presentation.Action.tryAgain(.newAudio).isPrimary)
        XCTAssertFalse(Presentation.Action.details("x").isPrimary)
    }
}
