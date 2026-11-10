import DaybookCore
import DaybookLink
import Foundation
import XCTest
@testable import DaybookKit

/// What the status offers when the person can do something about it, the same on both apps: taking back a request
/// this device made, a cloud summary that couldn't run, a download this iPhone could make to do the work itself, and a
/// summary that nothing within reach can make.
final class ConversationStatusChoicesTests: XCTestCase {
    typealias Presentation = ConversationStatusPresentation
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let studio = ProcessingRequest.Device(id: "studio", name: "Studio Mac")
    private let phoneDevice = ProcessingRequest.Device(id: "phone", name: "Alex’s iPhone")
    private var mac: Presentation.Inputs { .init(words: .mac(id: "studio"), local: .mac()) }
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

    // MARK: Cancel

    func testBehaviorOnlyTheDeviceThatAskedCanCancelAWaitingRequest() {
        let mine = ProcessingRequest(meetingID: UUID(), mode: .newAudio, requestedBy: phoneDevice, createdAt: now)
        XCTAssertEqual(page(.requested(.device(mine)), nil, phone)?.actions, [.cancelRequest(mine.id)])
        XCTAssertEqual(Presentation.Action.cancelRequest(mine.id).title, "Cancel")
        // On a Mac that didn't ask, it's someone else's request: it takes it, it doesn't cancel it.
        XCTAssertFalse(page(.requested(.device(mine)), nil, Presentation.Inputs(words: .mac(id: "other"), local: .mac()))?
            .actions.contains(.cancelRequest(mine.id)) ?? true)
    }

    func testBehaviorAnUpgradeWaitingForItsMacCanBeCancelledWhereItWasAccepted() {
        let upgrade = ProcessingRequest.Upgrade(role: "transcription", model: "parakeet/ultra", quality: 90, device: studio)
        for (inputs, asker) in [(phone, phoneDevice), (Presentation.Inputs(words: .mac(id: "laptop"), local: .mac()),
                                                       ProcessingRequest.Device(id: "laptop", name: "Vlad’s MacBook Pro"))] {
            let request = ProcessingRequest(meetingID: UUID(), mode: .fullRetranscription, requestedBy: asker, createdAt: now, upgrade: upgrade)
            XCTAssertEqual(page(.requested(.device(request)), recorded(transcribed: true), inputs),
                           Presentation(kind: .line, symbol: "clock", title: "Waiting for Studio Mac to upgrade the transcript",
                                        actions: [.cancelRequest(request.id)]))
            XCTAssertEqual(Presentation.row(.requested(.device(request)), meeting: recorded(transcribed: true), inputs: inputs, now: now)?.text,
                           "Waiting for Studio Mac", "the row names the Mac it waits for, never the one that asked")
        }
    }

    func testBehaviorCancellingBringsTheConversationBackToWhereItWas() {
        var meeting = recorded()
        let request = ProcessingRequest(meetingID: meeting.id, mode: .newAudio, requestedBy: phoneDevice, createdAt: now)
        meeting.upsertProcessingRequest(request)
        meeting.withdrawProcessingRequest(request.id, by: phoneDevice, at: now, observations: ClaimObservations())
        let status = ProcessingStatus(meeting, now: now)
        XCTAssertEqual(page(status, meeting, phone)?.title, "Not transcribed yet")
    }

    // MARK: The cloud

    func testBehaviorACloudFailureNamesTheModelAndOffersWhatHelps() {
        let key = ProcessingStatus.Failure(reason: "Anthropic didn’t accept this key.", hadTranscripts: true, device: studio, kind: .cloud(.badKey))
        var inputs = mac
        inputs.cloudModel = "Claude Sonnet 5.5"
        let box = page(.failed(key), recorded(transcribed: true), inputs)
        XCTAssertEqual(box?.title, "Couldn’t summarize with Claude Sonnet 5.5")
        XCTAssertEqual(box?.detail, "Anthropic didn’t accept this key. The recording is saved.", "the cloud's own sentence, never “Something went wrong”")
        XCTAssertEqual(box?.actions, [.cloudSettings, .summarizeHere("This Mac")])
        XCTAssertEqual(Presentation.Action.summarizeHere("This Mac").title, "Summarize on This Mac")
        XCTAssertEqual(Presentation.Action.cloudSettings.title, "Cloud Settings…")

        // The same failure on another device names no model it can't know.
        XCTAssertEqual(page(.failed(key), recorded(transcribed: true), Presentation.Inputs(words: .mac(id: "laptop"), local: .mac(),
                                                                                             cloudModel: "Claude Sonnet 5.5"))?.title,
                       "Couldn’t finish summarizing")

        // Only the cloud's passing troubles are worth trying again.
        for cloud in ProcessingRequest.FailureKind.CloudFailure.allCases {
            let failure = ProcessingStatus.Failure(reason: "Words.", hadTranscripts: true, device: studio, kind: .cloud(cloud))
            let actions = page(.failed(failure), recorded(transcribed: true), inputs)?.actions ?? []
            XCTAssertEqual(actions.contains(.tryAgain(.summaryOnly)), ProcessingRequest.FailureKind.cloud(cloud).isTransient, "\(cloud)")
            XCTAssertEqual(actions.contains(.cloudSettings), [.badKey, .noCredit, .modelUnavailable].contains(cloud), "\(cloud)")
            XCTAssertTrue(actions.contains(.summarizeHere("This Mac")), "\(cloud): a Mac always summarizes itself")
            XCTAssertLessThanOrEqual(actions.count, 2)
        }
    }

    func testBehaviorAniPhoneWithoutASummarizerAsksItsMacOnlyWhenThereIsOne() {
        let offline = ProcessingStatus.Failure(reason: "You’re offline.", hadTranscripts: true, device: phoneDevice, kind: .cloud(.offline))
        var inputs = phone
        inputs.cloudModel = "Claude Sonnet 5.5"
        inputs.mac = .seen(name: "Studio Mac", at: now.addingTimeInterval(-3600))
        let box = page(.failed(offline), recorded(transcribed: true), inputs)
        XCTAssertEqual(box?.title, "Couldn’t summarize with Claude Sonnet 5.5", "this iPhone's own cloud summary")
        XCTAssertEqual(box?.actions, [.tryAgain(.summaryOnly), .useYourMac])
        inputs.mac = .noMac
        XCTAssertEqual(page(.failed(offline), recorded(transcribed: true), inputs)?.actions, [.details("You’re offline."), .tryAgain(.summaryOnly)],
                       "no Mac to ask")
        inputs.local = .iPhone(processesHere: true, summarizes: true)
        XCTAssertEqual(page(.failed(offline), recorded(transcribed: true), inputs)?.actions, [.tryAgain(.summaryOnly), .summarizeHere("This iPhone")])
    }

    // MARK: This iPhone's own work

    func testBehaviorAniPhoneThatCouldTranscribeItsOwnRecordingOffersTheDownload() {
        let request = ProcessingRequest(meetingID: UUID(), mode: .newAudio, requestedBy: phoneDevice, createdAt: now)
        var inputs = phone
        inputs.local = .iPhone(processesHere: true, missingModelBytes: 852_900_000)
        inputs.mac = .noMac
        XCTAssertEqual(page(.requested(.device(request)), nil, inputs),
                       Presentation(kind: .box(.accent), symbol: "arrow.down.circle.fill", title: "Download models to transcribe this conversation",
                                    detail: ByteSize.format(852_900_000), actions: [.downloadModels(bytes: 852_900_000)]))
        XCTAssertEqual(Presentation.row(.requested(.device(request)), meeting: recorded(), inputs: inputs, now: now),
                       ConversationRowStatus(kind: .waitingForModels, text: "Waiting for models"))

        // Downloading: its figure, and Cancel.
        inputs.local = .iPhone(processesHere: true, missingModelBytes: 852_900_000, download: .init(name: "Parakeet", fraction: 0.4))
        XCTAssertEqual(page(.requested(.device(request)), nil, inputs)?.title, "Downloading models · 40%")
        XCTAssertEqual(page(.requested(.device(request)), nil, inputs)?.actions, [.cancelDownload])

        // A Mac that's around does it anyway; a recording that isn't this iPhone's is the Mac's; processing here off waits.
        inputs.local = .iPhone(processesHere: true, missingModelBytes: 852_900_000)
        inputs.mac = .connected("Studio Mac")
        XCTAssertEqual(page(.requested(.device(request)), nil, inputs)?.title, "Waiting for Studio Mac")
        inputs.mac = .noMac
        inputs.ownsUntranscribed = false
        XCTAssertEqual(page(.requested(.device(request)), nil, inputs)?.title, "Waiting for your Mac")
        inputs.ownsUntranscribed = true
        inputs.local = .iPhone(processesHere: false, missingModelBytes: 852_900_000)
        XCTAssertEqual(page(.requested(.device(request)), nil, inputs)?.title, "Waiting for your Mac")
    }

    func testBehaviorASummaryNothingCanMakeSaysSoInsteadOfWaiting() {
        let request = ProcessingRequest(meetingID: UUID(), mode: .summaryOnly, requestedBy: phoneDevice, createdAt: now)
        var inputs = phone
        inputs.mac = .noMac
        let line = page(.requested(.device(request)), recorded(transcribed: true), inputs)
        XCTAssertEqual(line?.title, "Needs your Mac to summarize")
        XCTAssertEqual(line?.symbol, "desktopcomputer", "a fact, not the clock")
        XCTAssertEqual(line?.detail, "No Mac has synced this library yet. Open Daybook on your Mac.")
        XCTAssertEqual(line?.actions, [.cancelRequest(request.id)])
        XCTAssertEqual(page(.transcribed, recorded(transcribed: true), inputs)?.title, "Needs your Mac to summarize")
        XCTAssertEqual(page(.transcribed, recorded(transcribed: true), inputs)?.actions, [], "Summarize would only wait")

        // A Mac seen once, the cloud on offer, or a summarizer here: it can be made.
        inputs.mac = .seen(name: "Studio Mac", at: now.addingTimeInterval(-86_400))
        XCTAssertEqual(page(.requested(.device(request)), recorded(transcribed: true), inputs)?.title, "Waiting for your Mac to summarize")
        inputs.mac = .noMac
        inputs.placement.cloudOffered = true
        XCTAssertEqual(page(.requested(.device(request)), recorded(transcribed: true), inputs)?.title, "Waiting for a Mac to summarize")
        XCTAssertEqual(page(.requested(.device(request)), recorded(transcribed: true), inputs)?.actions,
                       [.placement(.useCloud), .cancelRequest(request.id)])
        inputs.placement.cloudOffered = false
        inputs.local = .iPhone(processesHere: true, summarizes: true)
        XCTAssertEqual(page(.transcribed, recorded(transcribed: true), inputs)?.title, "Not summarized yet")
    }

    // MARK: A Mac's whereabouts

    func testBehaviorAMacsWhereaboutsReadOneWayEverywhere() {
        let request = ProcessingRequest(meetingID: UUID(), mode: .newAudio, requestedBy: phoneDevice, createdAt: now)
        var inputs = phone
        inputs.mac = .busy("Studio Mac")
        XCTAssertEqual(page(.requested(.device(request)), nil, inputs)?.title, "Waiting for Studio Mac")
        XCTAssertEqual(page(.requested(.device(request)), nil, inputs)?.detail, "Studio Mac is working on another conversation")
        inputs.mac = .recording("Studio Mac")
        XCTAssertEqual(page(.requested(.device(request)), nil, inputs)?.detail, "Studio Mac is recording")
        inputs.mac = .needsICloud
        XCTAssertEqual(page(.requested(.device(request)), nil, inputs)?.title, "Waiting for your Mac")
        XCTAssertEqual(page(.requested(.device(request)), nil, inputs)?.detail, "Needs iCloud")
        inputs.mac = .seen(name: "Studio Mac", at: now.addingTimeInterval(-3 * 86_400))
        XCTAssertEqual(page(.requested(.device(request)), nil, inputs)?.detail, "Last seen 3 days ago")
    }

    func testBehaviorAMacsLiveProgressReadsOnThePageOfAnyRequest() {
        let request = ProcessingRequest(meetingID: UUID(), mode: .newAudio, requestedBy: phoneDevice, createdAt: now)
        var inputs = phone
        inputs.link = .init(phase: .transcribing, fraction: 0.396, device: "Studio Mac")
        let line = page(.requested(.device(request)), nil, inputs)
        XCTAssertEqual(line?.title, "Transcribing on Studio Mac · 39%", "whole percents, rounded down, on every device")
        XCTAssertEqual(line?.progress ?? 0, 0.396, accuracy: 0.0001)
        XCTAssertEqual(line?.phrase, "Transcribing on Studio Mac", "the words animate, not the figure")
    }
}
