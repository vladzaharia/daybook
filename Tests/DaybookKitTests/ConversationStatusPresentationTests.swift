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

    func testBehaviorAnotherDevicesWorkReadsTheSameEverywhereWithItsFigure() {
        let elsewhere = ProcessingStatus.processing(.init(stage: .transcribing, fraction: 0.4, device: studio))
        let words = DeviceWords.mac(id: "this-mac")
        let onMac = page(elsewhere, nil, Presentation.Inputs(words: words, local: .mac()))
        let onPhone = page(elsewhere, nil, phone)
        XCTAssertEqual(onMac?.title, "Transcribing on Studio Mac · 40%")
        XCTAssertEqual(onPhone?.title, onMac?.title)
        XCTAssertEqual(onPhone?.symbol, "desktopcomputer")
        XCTAssertEqual(onMac?.actions, [], "only the device doing it pauses it")
        XCTAssertEqual(row(elsewhere, nil, phone)?.text, "Transcribing on Studio Mac · 40%")
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
        XCTAssertEqual(page(.requested(.queued(position: 2, after: nil)), nil, inputs)?.title, "Waiting to transcribe · 3 ahead")
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
                       Presentation(kind: .line, symbol: "arrow.down.circle", title: "Downloading Parakeet Ultra · 42%", progress: 0.42,
                                    actions: [.cancelDownload]))
        XCTAssertEqual(page(.requested(.models), nil, phone), Presentation(kind: .line, symbol: "arrow.down.circle", title: "Waiting for models"))
        XCTAssertEqual(row(.requested(.models), nil, mac), ConversationRowStatus(kind: .waitingForModels, text: "Waiting for models"))
        XCTAssertEqual(ConversationRowStatus.Kind.waitingForModels.symbol, "arrow.down.circle")
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
                       Presentation(kind: .line, symbol: "clock", title: "Waiting for your Mac", detail: "Last seen 2 h ago", actions: [.cancelRequest]))
        inputs.mac = .connected("Studio Mac")
        XCTAssertEqual(page(.requested(.device(request)), nil, inputs)?.title, "Waiting for Studio Mac")
        XCTAssertNil(page(.requested(.device(request)), nil, inputs)?.detail)
        inputs.mac = .noMac
        XCTAssertEqual(page(.requested(.device(request)), nil, inputs)?.detail, "No Mac has checked in yet. Open Daybook on your Mac.")
        XCTAssertEqual(row(.requested(.device(request)), nil, phone), ConversationRowStatus(kind: .waiting, text: "Waiting for your Mac"))

        // A Mac that can take it offers to, once.
        let onMac = page(.requested(.device(request)), nil, Presentation.Inputs(words: .mac(id: "this-mac"), local: .mac()))
        XCTAssertEqual(onMac, Presentation(kind: .box(.accent), symbol: "waveform.circle.fill", title: "Requested from Alex’s iPhone",
                                           actions: [.transcribe(newAudio: false)]))
        XCTAssertEqual(row(.requested(.device(request)), nil, Presentation.Inputs(words: .mac(id: "this-mac"), local: .mac()))?.text,
                       "Requested from Alex’s iPhone")

        // A Summarize request with a summary already says "again".
        var summarized = recorded(transcribed: true)
        summarized.summary = MeetingSummary(overview: "Done")
        let again = ProcessingRequest(meetingID: summarized.id, mode: .summaryOnly, requestedBy: alexPhone, createdAt: now)
        XCTAssertEqual(page(.requested(.device(again)), summarized, phone)?.title, "Waiting for your Mac to summarize again")
    }

    func testBehaviorAnUpgradeWaitingForItsMacUsesItsShortLineInRows() {
        let upgrade = ProcessingRequest.Upgrade(role: "transcription", model: "parakeet/ultra", quality: 90, device: studio)
        let request = ProcessingRequest(meetingID: UUID(), mode: .fullRetranscription, requestedBy: alexPhone, createdAt: now, upgrade: upgrade)
        let meeting = recorded(transcribed: true)
        for inputs in [mac, phone] {
            XCTAssertEqual(page(.requested(.device(request)), meeting, inputs)?.title, "Waiting for Studio Mac to upgrade the transcript")
            XCTAssertEqual(row(.requested(.device(request)), meeting, inputs)?.text, "Waiting for Studio Mac")
        }
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

        // No speech: nothing to retry.
        let silent = ProcessingStatus.Failure(reason: "No speech was recognized.", hadTranscripts: false, kind: .noSpeech)
        for inputs in [mac, phone] {
            XCTAssertEqual(page(.failed(silent), nil, inputs)?.actions, [.details("No speech was recognized.")])
            XCTAssertEqual(page(.failed(silent), nil, inputs)?.title, "No speech in this recording")
            XCTAssertEqual(row(.failed(silent), nil, inputs), ConversationRowStatus(kind: .failed, text: "No speech"))
        }

        // The cloud: a key's problem goes to Cloud Settings, and the summary can run here or on a Mac instead.
        let key = ProcessingStatus.Failure(reason: "Anthropic didn’t accept this key.", hadTranscripts: true, kind: .cloud(.badKey))
        XCTAssertEqual(page(.failed(key), recorded(transcribed: true), mac)?.actions, [.cloudSettings, .summarizeHere])
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
        XCTAssertEqual(page(.requested(.device(request)), recorded(transcribed: true), cloud)?.actions, [.placement(.useCloud)])
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

    func testBehaviorActionTitlesAreTheInterfacesWords() {
        XCTAssertEqual(Presentation.Action.tryAgain(.newAudio).title, "Try Again")
        XCTAssertEqual(Presentation.Action.details("x").title, "Details…")
        XCTAssertEqual(Presentation.Action.dontWait.title, "Don’t Wait")
        XCTAssertEqual(Presentation.Action.placement(.useCloud).title, "Use the Cloud")
        XCTAssertTrue(Presentation.Action.tryAgain(.newAudio).isPrimary)
        XCTAssertFalse(Presentation.Action.details("x").isPrimary)
    }
}
