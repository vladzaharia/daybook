import DaybookCore
import Foundation
import XCTest
@testable import DaybookKit

/// A failure's kind is stored with its request's outcome, set where the error was caught, and both apps word it
/// from the kind: rewording an error never turns a silent recording into one that offers Try Again, and a recording
/// iCloud couldn't download never reads as a missing model.
final class FailureWordsTests: XCTestCase {
    private let mac = ProcessingRequest.Device(id: "studio", name: "Studio Mac")
    private let phone = ProcessingRequest.Device(id: "phone", name: "Alex’s iPhone")
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let observations = ClaimObservations()

    private func failedRequest(_ kind: ProcessingRequest.FailureKind?, reason: String) throws -> ProcessingRequest {
        let request = ProcessingRequest(meetingID: UUID(), mode: .newAudio, requestedBy: phone, createdAt: now)
        let claimed = try XCTUnwrap(request.claimed(by: mac, at: now, observations: observations))
        return try XCTUnwrap(claimed.failed(by: mac, at: now.addingTimeInterval(5), reason: reason, kind: kind, observations: observations))
    }

    // MARK: Kinds

    func testBehaviorTheKindIsStoredWithTheOutcomeAndSurvivesSync() throws {
        let failed = try failedRequest(.noSpeech, reason: "Nothing was heard.")
        XCTAssertEqual(failed.outcome?.failureKind, .noSpeech, "the kind, not the words")
        let data = try JSONEncoder().encode(failed)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"failure\":\"noSpeech\""))
        XCTAssertEqual(try JSONDecoder().decode(ProcessingRequest.self, from: data).outcome?.failureKind, .noSpeech)

        let cloud = try failedRequest(.cloud(.noCredit), reason: "Your Anthropic account is out of credit.")
        let decoded = try JSONDecoder().decode(ProcessingRequest.self, from: try JSONEncoder().encode(cloud))
        XCTAssertEqual(decoded.outcome?.failureKind, .cloud(.noCredit))
    }

    func testBehaviorAKindANewerDaybookWroteReadsAsOtherAndIsWrittenBackUnchanged() throws {
        let failed = try failedRequest(.other, reason: "It broke.")
        let json = String(decoding: try JSONEncoder().encode(failed), as: UTF8.self)
            .replacingOccurrences(of: "\"failure\":\"other\"", with: "\"failure\":\"gpuReset\"")
        let decoded = try JSONDecoder().decode(ProcessingRequest.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.outcome?.failureKind, .other)
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self).contains("\"failure\":\"gpuReset\""),
                      "other devices still need the original")
    }

    func testBehaviorAnOlderRecordWithoutAKindReadsFromItsWords() throws {
        let old = try failedRequest(nil, reason: "No speech was recognized.")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(old), as: UTF8.self).contains("\"failure\""), "nothing written for nil")
        XCTAssertEqual(old.outcome?.failureKind, .noSpeech)
        let completed = try XCTUnwrap(ProcessingRequest(meetingID: UUID(), mode: .newAudio, requestedBy: phone)
            .claimed(by: mac, at: now, observations: observations)?.completed(by: mac, at: now, observations: observations))
        XCTAssertNil(completed.outcome?.failureKind, "a success has none")
    }

    func testBehaviorTheFallbackMatchesOnlyTheSentencesWrittenForEachKind() {
        typealias Kind = ProcessingRequest.FailureKind
        XCTAssertEqual(Kind(legacyMessage: "No speech was recognized."), .noSpeech)
        XCTAssertEqual(Kind(legacyMessage: "No speech was detected in this recording."), .noSpeech)
        XCTAssertEqual(Kind(legacyMessage: "Download Parakeet Ultra in Models before processing."), .modelsMissing)
        XCTAssertEqual(Kind(legacyMessage: "The speech model isn’t downloaded."), .modelsMissing)
        XCTAssertEqual(Kind(legacyMessage: "Parakeet is not installed."), .modelsMissing)
        XCTAssertEqual(Kind(legacyMessage: "iCloud couldn’t download this recording: The request timed out."), .other,
                       "a recording that isn't here is not a missing model")
        XCTAssertEqual(Kind(legacyMessage: "iCloud is still downloading this recording. Try again in a moment."), .other)
        XCTAssertEqual(Kind(legacyMessage: "The language model couldn’t allocate enough memory."), .modelCouldNotStart)
        XCTAssertEqual(Kind(legacyMessage: "Out of memory"), .modelCouldNotStart)
        XCTAssertEqual(Kind(legacyMessage: "Anthropic didn’t accept this key."), .cloud(.badKey))
        XCTAssertEqual(Kind(legacyMessage: "Your OpenAI account is out of credit."), .cloud(.noCredit))
        XCTAssertEqual(Kind(legacyMessage: "You’re offline."), .cloud(.offline))
        XCTAssertEqual(Kind(legacyMessage: "Anthropic is busy. Try again in a few minutes."), .cloud(.busy))
        XCTAssertEqual(Kind(legacyMessage: "The connection to OpenAI was lost."), .cloud(.connectionLost))
        XCTAssertEqual(Kind(legacyMessage: "Transcription stopped: the model process exited unexpectedly (code 5)."), .other)
        XCTAssertEqual(Kind(legacyMessage: ""), .other)
    }

    func testBehaviorErrorsKnowTheirOwnKind() {
        typealias Kind = ProcessingRequest.FailureKind
        XCTAssertEqual(Kind(DaybookError.noSpeech), .noSpeech)
        XCTAssertEqual(Kind(DaybookError.invalidAudio("Call.m4a")), .plainReason)
        XCTAssertEqual(Kind(DaybookError.libraryUnavailable), .plainReason)
        XCTAssertEqual(Kind(DaybookError.saveFailed("No space left on device")), .other, "the system's words go behind Details")
        let save = FailureWords(kind: Kind(DaybookError.saveFailed("No space left on device")),
                                reason: DaybookError.saveFailed("No space left on device").localizedDescription, hadTranscripts: false, device: "this Mac")
        XCTAssertEqual(save.message, "Something went wrong on this Mac. The recording is saved.")
        XCTAssertEqual(Kind(AudioFetchError.downloadTimedOut), .plainReason)
        XCTAssertEqual(Kind(AudioFetchError.downloadFailed("The request timed out.")), .other, "the system's words go behind Details")
        XCTAssertEqual(Kind(CloudError.badKey(.anthropic, details: "401")), .cloud(.badKey))
        XCTAssertEqual(Kind(CloudError.noKey(.openai)), .cloud(.badKey))
        XCTAssertEqual(Kind(CloudError.rateLimited(.anthropic, retryAfter: 30, details: "")), .cloud(.rateLimited))
        XCTAssertEqual(Kind(CloudError.refused(model: "Claude", category: nil, details: "")), .cloud(.other))
        XCTAssertTrue(Kind.cloud(.offline).isTransient)
        XCTAssertFalse(Kind.cloud(.badKey).isTransient)
        for kind: Kind in [.noSpeech, .modelsMissing, .modelCouldNotStart, .recordingDidNotStart, .plainReason, .other]
            + Kind.CloudFailure.allCases.map(Kind.cloud) {
            XCTAssertEqual(Kind(rawValue: kind.rawValue), kind, kind.rawValue)
        }
    }

    func testBehaviorTheStatusCarriesTheStoredKindNotTheWords() throws {
        var meeting = Meeting(title: "Board prep", tracks: [RecordingTrack(source: .microphone, relativePath: "Originals/a.m4a", fileName: "a.m4a")])
        // Worded like a missing model, stored as what it was.
        let failed = try failedRequest(.plainReason, reason: "Download the recording again before processing.")
        meeting.upsertProcessingRequest(ProcessingRequest(id: failed.id, meetingID: meeting.id, mode: failed.mode, requestedBy: failed.requestedBy,
                                                          createdAt: failed.createdAt, claim: failed.claim, outcome: failed.outcome))
        guard case .failed(let failure) = ProcessingStatus(meeting, now: now.addingTimeInterval(10)) else { return XCTFail("couldn't finish") }
        XCTAssertEqual(failure.kind, .plainReason)
        XCTAssertEqual(failure.device, mac)

        // A failure kept only on the conversation (this Mac's own work) reads from its message.
        var local = Meeting(title: "Hallway chat", tracks: meeting.tracks, status: .failed, errorMessage: "No speech was recognized.")
        local.updatedAt = now
        guard case .failed(let own) = ProcessingStatus(local, now: now) else { return XCTFail("couldn't finish") }
        XCTAssertTrue(own.isNoSpeech)
    }

    // MARK: Words

    func testBehaviorEachKindReadsTheSameOnBothDevicesWithTheDeviceNamed() {
        typealias Kind = ProcessingRequest.FailureKind
        let thisMac = DeviceWords.mac(id: "studio"), thisPhone = DeviceWords.iPhone(id: "phone")
        func words(_ kind: Kind, reason: String = "x", transcripts: Bool = false, by device: ProcessingRequest.Device?,
                   _ deviceWords: DeviceWords) -> FailureWords {
            FailureWords(ProcessingStatus.Failure(reason: reason, hadTranscripts: transcripts, device: device, kind: kind), words: deviceWords)
        }
        // No speech: nothing to retry, and the one phrase.
        XCTAssertEqual(words(.noSpeech, by: mac, thisMac), FailureWords(title: "No speech in this recording", message: "The recording is saved."))
        XCTAssertEqual(words(.noSpeech, by: mac, thisPhone), words(.noSpeech, by: mac, thisMac))
        // Missing models, named where they're missing.
        XCTAssertEqual(words(.modelsMissing, by: mac, thisMac).message, "The models it needs aren’t on this Mac yet. The recording is saved.")
        XCTAssertEqual(words(.modelsMissing, by: mac, thisPhone).message, "The models it needs aren’t on Studio Mac yet. The recording is saved.")
        XCTAssertEqual(words(.modelsMissing, by: phone, thisPhone).message, "The models it needs aren’t on this iPhone yet. The recording is saved.")
        XCTAssertEqual(words(.modelsMissing, by: nil, thisPhone).message, "The models it needs aren’t on your Mac yet. The recording is saved.",
                       "an iPhone that doesn't know which device says your Mac")
        XCTAssertEqual(words(.modelsMissing, by: nil, thisMac).message, "The models it needs aren’t on this Mac yet. The recording is saved.")
        XCTAssertEqual(words(.modelsMissing, by: mac, thisMac).title, "Couldn’t finish transcribing")
        // The model couldn't start: the summary's, once there are transcripts.
        XCTAssertEqual(words(.modelCouldNotStart, transcripts: true, by: mac, thisPhone),
                       FailureWords(title: "Couldn’t finish summarizing", message: "The summary model couldn’t start on Studio Mac. The recording is saved."))
        // The cloud's own sentence passes through.
        XCTAssertEqual(words(.cloud(.noCredit), reason: "Your Anthropic account is out of credit.", transcripts: true, by: mac, thisMac),
                       FailureWords(title: "Couldn’t finish summarizing", message: "Your Anthropic account is out of credit. The recording is saved."))
        XCTAssertEqual(words(.cloud(.offline), reason: "", transcripts: true, by: mac, thisMac).message, "You’re offline. The recording is saved.")
        // Daybook's own plain sentence passes through; anything else stays behind Details.
        XCTAssertEqual(words(.plainReason, reason: "Call.m4a contains no readable audio.", by: nil, thisMac).message,
                       "Call.m4a contains no readable audio. The recording is saved.")
        XCTAssertEqual(words(.other, reason: "EXC_BAD_ACCESS in mlx_eval", by: mac, thisPhone).message,
                       "Something went wrong on Studio Mac. The recording is saved.")
        XCTAssertEqual(words(.recordingDidNotStart, reason: "", by: nil, thisMac), FailureWords(title: "Recording didn’t start", message: "Nothing was recorded."))
        // Every message ends with the one phrase, once (a recording that didn't start has none to save).
        for kind: Kind in [.noSpeech, .modelsMissing, .modelCouldNotStart, .cloud(.busy), .plainReason, .other] {
            for deviceWords in [thisMac, thisPhone] {
                let message = words(kind, reason: "It stopped.", by: mac, deviceWords).message
                XCTAssertTrue(message.hasSuffix(FailureWords.saved), message)
                XCTAssertEqual(message.components(separatedBy: FailureWords.saved).count, 2, message)
            }
        }
    }

    // MARK: Claims

    func testBehaviorARequestIsLostWhenItFinishedElsewhereOrAnotherDeviceHoldsIt() throws {
        let request = ProcessingRequest(meetingID: UUID(), mode: .newAudio, requestedBy: phone, createdAt: now)
        XCTAssertFalse(request.isLost(for: mac, at: now, observations: observations), "unclaimed: still this device's to take")
        let mine = try XCTUnwrap(request.claimed(by: mac, at: now, observations: observations))
        XCTAssertFalse(mine.isLost(for: mac, at: now, observations: observations))
        XCTAssertTrue(mine.isLost(for: phone, at: now, observations: observations), "another device holds it")
        let done = try XCTUnwrap(mine.completed(by: mac, at: now, observations: observations))
        XCTAssertTrue(done.isLost(for: mac, at: now, observations: observations), "finished: nothing left to do")
        // A lease that ran out is anyone's again.
        let lapsed = mine.isLost(for: phone, at: now.addingTimeInterval(ProcessingRequest.defaultLease + ClaimObservations.staleAfter + 1),
                                 observations: observations)
        XCTAssertFalse(lapsed)
        // One asked for in a way this version doesn't know (a newer Daybook's mode) isn't this device's either.
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(mine)) as? [String: Any])
        json["mode"] = "translate"
        let newer = try JSONDecoder().decode(ProcessingRequest.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(newer.isUnderstood)
        XCTAssertTrue(newer.isLost(for: mac, at: now, observations: observations))
        // Both queues ask the one question: lost is exactly no longer claimable.
        for request in [request, mine, done, newer] {
            for device in [mac, phone] {
                XCTAssertEqual(request.isLost(for: device, at: now, observations: observations),
                               !request.isClaimable(by: device, at: now, observations: observations))
            }
        }
    }
}
