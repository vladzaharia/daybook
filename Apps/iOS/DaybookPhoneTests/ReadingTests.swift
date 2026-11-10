import DaybookCaptions
import DaybookKit
import DaybookLink
import DaybookUI
import ImageIO
import Observation
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import DaybookPhone

/// The library and reading: loading a Mac library, the words for processing states, evidence,
/// the transcript's shape, playback targets, Version History's marks, export, and the session that
/// carries reading across folds.
@MainActor
final class ReadingTests: XCTestCase {
    // MARK: Fixtures

    private let trackID = UUID()
    private let phone = ProcessingRequest.Device(id: "local", name: "Alex's iPhone")
    private let studio = ProcessingRequest.Device(id: "mac-studio", name: "Studio")
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// The seeded demo's "Weekly product sync": three speakers, a summary, a note, a bookmark.
    private func weekly() -> Meeting {
        let lines: [(Int, String, Double, Double)] = [
            (0, "Okay, let's get started. The main thing today is whether the beta ships on the fourteenth.", 0, 5.2),
            (1, "Engineering is mostly there. Sync conflict handling is the last open piece, and I'd like two more days of testing on it.", 5.6, 12.9),
            (2, "Support is ready either way. We drafted the help articles last week, so it's really about the release notes.", 13.3, 19.8),
            (0, "Then let's hold the fourteenth, but make the conflict fix the gate. If it isn't green by Friday, we move a week.", 20.2, 26.6),
            (1, "That works. I'll post a status in the channel Thursday afternoon.", 27.0, 31.4),
            (2, "One more thing: three customers asked about exporting to Markdown. Is that in the beta?", 31.8, 37.6),
            (2, "Release notes are on me.", 37.9, 39.0),
            (1, "I can review the release notes too.", 39.4, 41.0),
        ]
        let speakers = ["Maya", "Daniel", "Priya"].enumerated().map { Speaker(id: "S\($0.offset)", name: $0.element, sourceTrackID: trackID) }
        let segments = lines.map { speaker, text, start, end -> TranscriptSegment in
            let id = UUID()
            return TranscriptSegment(id: id, trackID: trackID, start: start, end: end, text: text, speakerID: "S\(speaker)",
                                     provenance: [SegmentProvenance(trackID: trackID, segmentID: id, start: start, end: end, text: text)])
        }
        let summary = MeetingSummary(overview: "The team agreed to keep the beta date of the 14th, gated on the sync conflict fix.",
                                     sections: [SummarySection(heading: "Decisions", body: "- Keep the **14th** as the beta date.\n- The sync conflict fix is the release gate.")],
                                     actionItems: [ActionItem(text: "Post a status update on the conflict fix", owner: "Daniel"),
                                                   ActionItem(text: "Finish the release notes, including Markdown export", owner: "Priya")],
                                     createdAt: now.addingTimeInterval(-3600))
        return Meeting(title: "Weekly product sync", date: now.addingTimeInterval(-7200), kind: .general,
                       notes: "Beta date — hold the 14th?\nAsk about export for the release notes",
                       tracks: [RecordingTrack(id: trackID, source: .microphone, relativePath: "Originals/Microphone.wav", fileName: "Microphone.wav",
                                               duration: 41.5, offset: 0)],
                       transcripts: [TrackTranscript(trackID: trackID, segments: segments, modelID: "whisper-small", createdAt: now.addingTimeInterval(-3700))],
                       unifiedTranscript: segments, summary: summary,
                       highlights: [Highlight(time: 14.5, text: "Gate on the conflict fix")], speakers: speakers, status: .ready,
                       timedNotes: [TimedNote(time: 2, text: "Beta date — hold the 14th?"), TimedNote(time: 24, text: "Ask about export for the release notes")])
    }

    private func recorded() -> Meeting {
        Meeting(title: "Onboarding design review", date: now, tracks: [RecordingTrack(id: trackID, source: .microphone, relativePath: "Originals/a.m4a",
                                                                                         fileName: "a.m4a", duration: 11, offset: 0)],
                status: .imported)
    }

    // MARK: The demo library

    /// A library written by the Mac (JSON with reference-date seconds, as the demo seeder writes)
    /// loads, and what reads it is told, which the list relies on: the controller is `@Observable`, so a
    /// view reading `PhoneLibrary.conversations` (or the controller) redraws once it loads.
    func testAMacLibraryLoadsAndPublishesItsConversations() async throws {
        let root = try temporaryDirectory()
        let id = UUID()
        let directory = root.appendingPathComponent("Meetings/\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json: [String: Any] = [
            "schemaVersion": 1, "id": id.uuidString, "title": "Weekly product sync", "date": 800_000_000.0, "updatedAt": 800_003_600.0,
            "kind": "auto", "notes": "Beta date?", "tracks": [], "transcripts": [], "unifiedTranscript": [], "alignmentReports": [],
            "revisions": [], "highlights": [], "speakers": [], "status": "ready", "folderID": UUID().uuidString, "tags": ["launch"],
        ]
        try JSONSerialization.data(withJSONObject: json).write(to: directory.appendingPathComponent("meeting.json"))
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "folders": [], "templates": [], "vocabulary": []] as [String: Any])
            .write(to: root.appendingPathComponent("library.json"))

        let library = PhoneLibrary(rootURL: root, installation: "TEST")
        let told = Told()
        withObservationTracking { _ = library.conversations } onChange: { told.set() }
        XCTAssertTrue(library.controller.meetings.isEmpty, "nothing before the app's launch loads it")
        try await library.reload()
        XCTAssertTrue(told.value, "a list drawn before the library loaded redraws once it loads")
        XCTAssertEqual(LibraryPlace.section(.all).meetings(in: library.controller.meetings).map(\.title), ["Weekly product sync"])
        XCTAssertEqual(library.controller.allTags, ["launch"])
    }

    // MARK: Processing states

    /// The page's status, as this iPhone draws it: the shared presentation with what the iPhone knows.
    private func pageStatus(_ status: ProcessingStatus, _ meeting: Meeting, mac: ConversationStatusPresentation.MacStanding? = nil,
                            local: ConversationStatusPresentation.LocalCapabilities = .iPhone(),
                            live: LiveProgress? = nil) -> ConversationStatusPresentation? {
        var inputs = ConversationStatusPresentation.Inputs(words: .iPhone(id: phone.id), local: local)
        inputs.mac = mac
        inputs.link = live.map(ConversationStatusPresentation.LinkWork.init(live:))
        return ConversationStatusPresentation.page(status, meeting: meeting, inputs: inputs, now: now)
    }

    /// The row's status, as this iPhone's list draws it (`PhoneRowStatus`): the shared presentation's row.
    private func rowStatus(_ status: ProcessingStatus, _ meeting: Meeting) -> ConversationRowStatus? {
        let inputs = ConversationStatusPresentation.Inputs(words: .iPhone(id: phone.id), local: .iPhone())
        return ConversationStatusPresentation.row(status, meeting: meeting, inputs: inputs, now: now)
    }

    func testRecordedIsACalmCompleteState() {
        let meeting = recorded()
        XCTAssertEqual(ProcessingStatus(meeting, now: now), .recorded)
        let page = pageStatus(.recorded, meeting)
        XCTAssertEqual(page?.kind, .box(.accent), "the same box as the Mac's")
        XCTAssertEqual(page?.title, "Not transcribed yet")
        XCTAssertEqual(page?.actions, [.transcribe(newAudio: false)], "it offers Transcribe")
        XCTAssertEqual(rowStatus(.recorded, meeting), ConversationRowStatus(kind: .notTranscribed, text: "Not transcribed yet"))
    }

    func testATranscriptWithoutASummaryOffersSummarize() {
        var meeting = recorded()
        let words = TranscriptSegment(trackID: meeting.tracks[0].id, start: 0, end: 2, text: "Come back in six months.")
        meeting.transcripts = [TrackTranscript(trackID: meeting.tracks[0].id, segments: [words], createdAt: now)]
        meeting.unifiedTranscript = [words]
        XCTAssertEqual(ProcessingStatus(meeting, now: now), .transcribed)
        let page = pageStatus(.transcribed, meeting, mac: .seen(name: "Studio", at: now.addingTimeInterval(-3600)))
        XCTAssertEqual(page?.kind, .line)
        XCTAssertEqual(page?.title, "Not summarized yet")
        XCTAssertEqual(page?.actions, [.summarize], "the line offers Summarize")
        XCTAssertNil(rowStatus(.transcribed, meeting), "the row shows its preview: the transcript reads")
        // With no Mac, no summarizer here, and no cloud, Summarize would only wait.
        XCTAssertEqual(pageStatus(.transcribed, meeting, mac: .noMac)?.title, "Needs your Mac to summarize")
    }

    /// An iPhone with `gigabytes` of memory and language models running or not, its downloads held halfway.
    private func phoneModels(_ gigabytes: Double, limit: UInt64? = nil, runsLanguageModels: Bool = true,
                             network: PhoneModelsTests.ScriptedNetwork = .init(),
                             fetcher: PhoneModelsTests.HalfwayFetcher = .init()) throws -> PhoneModels {
        PhoneModels(root: try temporaryDirectory("Models"), defaults: makeTestDefaults("ReadingTests"), fetcher: fetcher,
                    network: network.network, physicalMemory: UInt64(gigabytes * 1e9), memoryLimit: limit,
                    runsLanguageModels: runsLanguageModels)
    }

    /// "Needs your Mac to summarize" offers the summary model only where this iPhone could run it (P3, uxf-09): an
    /// 18 Pro gets "Download · 3.6 GB"; an iPhone without the memory, or language models, keeps the bare fact.
    func testNeedsYourMacOffersTheSummaryModelOnlyWhereThisIPhoneCouldRunIt() async throws {
        var meeting = recorded()
        let words = TranscriptSegment(trackID: meeting.tracks[0].id, start: 0, end: 2, text: "Come back in six months.")
        meeting.transcripts = [TrackTranscript(trackID: meeting.tracks[0].id, segments: [words], createdAt: now)]
        meeting.unifiedTranscript = [words]

        let capable = try phoneModels(12, limit: 5_400_000_000)
        let summary = try XCTUnwrap(capable.summaryModel)
        let page = pageStatus(.transcribed, meeting, mac: .noMac, local: SummaryPage.local(capable, processesHere: true, summarizes: false))
        XCTAssertEqual(page?.title, "Needs your Mac to summarize")
        XCTAssertEqual(page?.actions, [.downloadSummaryModel(bytes: summary.approximateBytes)])
        XCTAssertEqual(page?.actions.first?.title, "Download · 3.6 GB")
        XCTAssertEqual(pageStatus(.transcribed, meeting, mac: .noMac, local: SummaryPage.local(capable, processesHere: false, summarizes: false))?.actions,
                       [], "processing here off: the model wouldn't be used")

        // Too little room for it: the fact stays bare (Settings › Models says what it needs).
        capable.readSpace = { _ in ModelSpace(free: 1_000_000_000) }
        await capable.refresh()
        XCTAssertEqual(pageStatus(.transcribed, meeting, mac: .noMac, local: SummaryPage.local(capable, processesHere: true, summarizes: false))?.actions, [])

        for incapable in [try phoneModels(6), try phoneModels(12, limit: 5_400_000_000, runsLanguageModels: false)] {
            let bare = pageStatus(.transcribed, meeting, mac: .noMac, local: SummaryPage.local(incapable, processesHere: true, summarizes: false))
            XCTAssertEqual(bare?.title, "Needs your Mac to summarize")
            XCTAssertEqual(bare?.actions, [], "never a summary it can't make")
        }
    }

    /// The page's download reads the whole set this iPhone asked for (W1-E's leftover), never one model's figure: its
    /// fraction, and what's here of the total, the summary model waiting its turn included.
    func testTheOwnDownloadReadsTheWholeSetsFigure() async throws {
        let network = PhoneModelsTests.ScriptedNetwork(), fetcher = PhoneModelsTests.HalfwayFetcher()
        network.set(.unrestricted)
        let models = try phoneModels(12, limit: 5_400_000_000, network: network, fetcher: fetcher)
        let transcribing = models.processingMissing
        for model in transcribing { models.download(model) }
        let summary = try XCTUnwrap(models.summaryModel)
        models.download(summary)
        try await waitUntil("each transcribing model halfway") {
            transcribing.allSatisfy { if case .downloading(let fraction) = models.status(of: $0) { return fraction > 0 } else { return false } }
        }

        var meeting = recorded()
        meeting.upsertProcessingRequest(ProcessingRequest(meetingID: meeting.id, mode: .newAudio, requestedBy: phone, createdAt: now))
        let status = ProcessingStatus(meeting, now: now)
        let page = pageStatus(status, meeting, mac: .noMac, local: SummaryPage.local(models, processesHere: true, summarizes: false))
        guard case .downloading(let done, let total)? = models.processingDownloadState else { return XCTFail("the set arrives") }
        XCTAssertEqual(total, (transcribing + [summary]).reduce(0) { $0 + $1.approximateBytes }, "the summary model in the total")
        let fraction = Double(done) / Double(total)
        XCTAssertEqual(page?.title, ProcessingWords.downloadingModels(fraction))
        XCTAssertEqual(try XCTUnwrap(page?.progress), fraction, accuracy: 1e-9)
        XCTAssertEqual(page?.detail, ByteSize.progress(done, of: total))
        XCTAssertEqual(page?.actions, [.cancelDownload])
        guard case .downloading(let one) = models.status(of: transcribing[0]) else { return XCTFail() }
        XCTAssertNotEqual(page?.progress, one, "not one model's figure")
        // Settings › Models' row agrees.
        XCTAssertEqual(SettingsScreen.modelsDetail(models, processesHere: true, transcribes: false), ModelStatus.downloading(fraction).label)
        fetcher.held.release()
    }

    func testWaitingSaysWhenAMacWasLastSeen() {
        var meeting = recorded()
        let request = ProcessingRequest(meetingID: meeting.id, mode: .newAudio, requestedBy: phone, createdAt: now)
        meeting.upsertProcessingRequest(request)
        let status = ProcessingStatus(meeting, now: now)
        guard case .requested(.device) = status else { return XCTFail("expected a request waiting for a Mac, got \(status)") }

        let old = pageStatus(status, meeting, mac: .phone(presence: nil, sighting: MacSighting(name: "Studio", date: now.addingTimeInterval(-2 * 3600)),
                                                          connected: [], liveProgress: [:], meetingID: meeting.id, now: now))
        XCTAssertEqual(old?.title, "Waiting for your Mac")
        XCTAssertEqual(old?.detail, "Last seen 2 h ago")
        XCTAssertEqual(old?.actions, [.cancelRequest(request.id)], "this iPhone asked: it can take it back")
        let recent = pageStatus(status, meeting, mac: .seen(name: "Studio", at: now.addingTimeInterval(-60)))
        XCTAssertEqual(recent?.title, "Waiting for Studio", "a Mac that checked in recently is named")
        XCTAssertNil(recent?.detail)
        let never = pageStatus(status, meeting, mac: .phone(presence: nil, sighting: nil, connected: [], liveProgress: [:], meetingID: meeting.id))
        XCTAssertEqual(never?.detail, "No Mac has synced this library yet. Open Daybook on your Mac.", "one way of saying it, as Settings does")
        XCTAssertEqual(ConversationStatusPresentation.MacStanding.noMacLine, never?.detail)
        XCTAssertEqual(rowStatus(status, meeting)?.text, "Waiting for your Mac")

        // A Summarize request says "again" only when there's a summary already.
        var transcribed = recorded()
        let words = TranscriptSegment(trackID: trackID, start: 0, end: 2, text: "Come back in six months.")
        transcribed.transcripts = [TrackTranscript(trackID: trackID, segments: [words], createdAt: now)]
        transcribed.unifiedTranscript = [words]
        let summarize = ProcessingRequest(meetingID: transcribed.id, mode: .summaryOnly, requestedBy: phone, createdAt: now)
        transcribed.upsertProcessingRequest(summarize)
        let first = ProcessingStatus(transcribed, now: now)
        XCTAssertEqual(pageStatus(first, transcribed)?.title, "Waiting for your Mac to summarize", "a first summary")
        XCTAssertEqual(rowStatus(first, transcribed)?.text, "Waiting for your Mac to summarize")
        transcribed.summary = MeetingSummary(overview: "Come back in six months.", createdAt: now.addingTimeInterval(-3600))
        XCTAssertEqual(pageStatus(ProcessingStatus(transcribed, now: now), transcribed)?.title, "Waiting for your Mac to summarize again")
    }

    func testTheWaitingLineSaysWhatTheMacIsDoing() {
        let id = UUID()
        let presence = MacPresence.connected(name: "Studio")
        var mac = PhoneLink.Mac(id: UUID(), name: "Studio", pairedAt: now)
        XCTAssertEqual(ConversationStatusPresentation.MacStanding.phone(presence: presence, sighting: nil, connected: [mac], liveProgress: [:], meetingID: id),
                       .connected("Studio"))
        let other = LiveProgress(LinkProcessingProgress(meetingID: UUID(), phase: .transcribing, fraction: 0.2, macName: "Studio"), receivedAt: now)
        XCTAssertEqual(ConversationStatusPresentation.MacStanding.phone(presence: presence, sighting: nil, connected: [mac],
                                                                         liveProgress: [other.meetingID: other], meetingID: id), .busy("Studio"))
        mac.recording = LinkRecordingState(phase: .recording, conversationID: UUID(), startedAt: now, elapsed: 30, sentAt: now)
        XCTAssertEqual(ConversationStatusPresentation.MacStanding.phone(presence: presence, sighting: nil, connected: [mac], liveProgress: [:], meetingID: id),
                       .recording("Studio"))
        XCTAssertEqual(ConversationStatusPresentation.MacStanding.phone(presence: .unavailable("Sign in to iCloud."), sighting: nil, connected: [],
                                                                         liveProgress: [:], meetingID: id), .needsICloud)
        // The library's own evidence counts when it's newer than the Mac's presence.
        let presenceSeen = MacPresence.seen(name: "Studio", lastSeen: now.addingTimeInterval(-7200))
        XCTAssertEqual(ConversationStatusPresentation.MacStanding.phone(presence: presenceSeen, sighting: MacSighting(name: "Studio", date: now.addingTimeInterval(-60)),
                                                                         connected: [], liveProgress: [:], meetingID: id),
                       .seen(name: "Studio", at: now.addingTimeInterval(-60)))
    }

    func testTheMacsLiveProgressReadsOnThePageBeforeSyncSaysSo() {
        // A Mac took the request a moment ago: the link knows before the next sync pass brings the claim.
        var meeting = recorded()
        meeting.upsertProcessingRequest(ProcessingRequest(meetingID: meeting.id, mode: .newAudio, requestedBy: phone, createdAt: now))
        let status = ProcessingStatus(meeting, now: now)
        let live = LiveProgress(LinkProcessingProgress(meetingID: meeting.id, phase: .transcribing, fraction: 0.4, macName: "Studio Mac"), receivedAt: now)
        let page = pageStatus(status, meeting, mac: .connected("Studio Mac"), live: live)
        XCTAssertEqual(page?.title, "Transcribing on Studio Mac · 40%")
        XCTAssertEqual(page?.progress, 0.4)
    }

    func testProcessingNamesTheMacAndNeverInventsProgress() {
        let reported = ProcessingStatus.Progress(stage: .transcribing, fraction: 0.4, device: studio)
        let page = pageStatus(.processing(reported), recorded())
        XCTAssertEqual(page?.title, "Transcribing on Studio · 40%")
        XCTAssertEqual(page?.progress, 0.4)
        XCTAssertEqual(page?.isWorking, false)

        let silent = ProcessingStatus.Progress(stage: .summarizing, fraction: nil, device: studio)
        let line = pageStatus(.processing(silent), recorded())
        XCTAssertEqual(line?.title, "Summarizing on Studio")
        XCTAssertNil(line?.progress, "no figure, no bar")
        XCTAssertEqual(line?.isWorking, true)
        // This iPhone's own work names it, with the same rounding as everywhere: down.
        let here = pageStatus(.processing(.init(stage: .transcribing, fraction: 0.396)), recorded())
        XCTAssertEqual(here?.title, "Transcribing on this iPhone · 39%")
        XCTAssertEqual(rowStatus(.processing(reported), recorded()),
                       ConversationRowStatus(kind: .processing, text: "Transcribing on Studio · 40%", fraction: 0.4))
    }

    func testCouldntFinishOffersTryAgainWithTheFailedRequestsMode() {
        var meeting = weekly()
        let request = ProcessingRequest(meetingID: meeting.id, mode: .speakerRefresh, requestedBy: phone, createdAt: now)
        let failed = request.failed(by: studio, at: now, reason: "The speaker model isn't downloaded", kind: .modelsMissing)!
        meeting.upsertProcessingRequest(failed)
        let status = ProcessingStatus(meeting, now: now)
        guard case .failed(let failure) = status else { return XCTFail("expected a failure, got \(status)") }
        let page = pageStatus(status, meeting)
        XCTAssertEqual(page?.kind, .box(.problem))
        XCTAssertEqual(page?.title, "Couldn’t finish summarizing")
        XCTAssertEqual(page?.detail, "The models it needs aren’t on Studio yet. The recording is saved.")
        XCTAssertEqual(page?.actions, [.details(failure.reason), .tryAgain(.speakerRefresh)], "the Mac's order: Details, then the fix")

        // Trying again can't find speech that isn't there.
        let silent = pageStatus(.failed(.init(reason: "No speech was recognized.", hadTranscripts: false)), recorded())
        XCTAssertEqual(silent?.title, "No speech in this recording")
        XCTAssertEqual(silent?.detail, "The recording is saved.")
        XCTAssertEqual(silent?.actions, [.details("No speech was recognized.")])
    }

    func testThisiPhonesOwnRecordingOffersItsDownloadWhenNoMacIsAround() {
        var meeting = recorded()
        let request = ProcessingRequest(meetingID: meeting.id, mode: .newAudio, requestedBy: phone, createdAt: now)
        meeting.upsertProcessingRequest(request)
        let status = ProcessingStatus(meeting, now: now)
        let page = pageStatus(status, meeting, mac: .noMac, local: .iPhone(processesHere: true, missingModelBytes: 852_900_000))
        XCTAssertEqual(page?.title, "Download models to transcribe this conversation")
        XCTAssertEqual(page?.actions, [.downloadModels(bytes: 852_900_000)])
        XCTAssertEqual(page?.detail, ByteSize.format(852_900_000))
    }

    func testTheLastSightingIsTheNewestSignOfAMacAtWork() {
        var meeting = recorded()
        var request = ProcessingRequest(meetingID: meeting.id, mode: .newAudio, requestedBy: phone, createdAt: now.addingTimeInterval(-600))
        request = request.claimed(by: studio, at: now.addingTimeInterval(-300))!
        meeting.upsertProcessingRequest(request)
        let sighting = MacSighting.latest(in: [weekly(), meeting], excluding: phone.id)
        XCTAssertEqual(sighting, MacSighting(name: "Studio", date: now.addingTimeInterval(-300)))
        XCTAssertNil(MacSighting.latest(in: [recorded()], excluding: phone.id))
        XCTAssertEqual(ConversationStatusPresentation.MacStanding.ago(3 * 86_400), "3 days ago")
    }

    /// This iPhone's own work is no sign of a Mac: a transcript of a recording it owns, and a summary it made. So an
    /// iPhone that transcribed alone reads "Needs your Mac to summarize", with its own summary model where it fits.
    func testThisIPhonesOwnTranscriptsAndSummariesAreNoSignOfAMac() {
        var meeting = recorded()
        let words = TranscriptSegment(trackID: trackID, start: 0, end: 2, text: "Come back in six months.")
        meeting.transcripts = [TrackTranscript(trackID: trackID, segments: [words], createdAt: now)]
        meeting.unifiedTranscript = [words]
        XCTAssertEqual(MacSighting.latest(in: [meeting], excluding: phone.id), MacSighting(name: nil, date: now), "whose, unknown: a Mac's")
        XCTAssertNil(MacSighting.latest(in: [meeting], excluding: phone.id, owns: { $0.id == self.trackID }), "its own recording")
        let standing = ConversationStatusPresentation.MacStanding.phone(
            presence: .noMac, sighting: MacSighting.latest(in: [meeting], excluding: phone.id, owns: { $0.id == self.trackID }),
            connected: [], liveProgress: [:], meetingID: meeting.id, now: now)
        XCTAssertEqual(standing, .noMac)
        XCTAssertEqual(pageStatus(.transcribed, meeting, mac: standing, local: .iPhone(processesHere: true, summaryModelBytes: 3_580_000_000))?.actions,
                       [.downloadSummaryModel(bytes: 3_580_000_000)])

        meeting.summary = MeetingSummary(overview: "Come back in six months.", createdAt: now.addingTimeInterval(60))
            .placed(.thisDevice, by: phone, inputs: [:])
        XCTAssertEqual(meeting.summary?.origin.deviceID, phone.id)
        XCTAssertNil(MacSighting.latest(in: [meeting], excluding: phone.id, owns: { $0.id == self.trackID }), "a summary it made")
    }

    // MARK: Evidence

    func testNextStepsAndBulletsFindTheirEvidence() {
        let meeting = weekly()
        let index = EvidenceIndex(meeting)
        let text = { (id: UUID?) in meeting.unifiedTranscript.first { $0.id == id }?.text }
        XCTAssertEqual(text(index.segment(for: "Post a status update on the conflict fix", owner: "Daniel")),
                       "That works. I'll post a status in the channel Thursday afternoon.")
        XCTAssertEqual(text(index.segment(for: "The sync conflict fix is the release gate.")),
                       "Then let's hold the fourteenth, but make the conflict fix the gate. If it isn't green by Friday, we move a week.")
        // The owner's own passage wins over equally good ones.
        XCTAssertEqual(text(index.segment(for: "Release notes", owner: "Daniel")), "I can review the release notes too.")
        XCTAssertEqual(text(index.segment(for: "Release notes")), meeting.unifiedTranscript[2].text, "without an owner, the first")
        XCTAssertNil(index.segment(for: "Lunch is at noon"), "nothing shared, nothing found")
        XCTAssertEqual(["notes", "status", "boxes", "stories", "drafted", "testing"].map(EvidenceIndex.stem),
                       ["note", "status", "box", "story", "draft", "test"])
        XCTAssertNil(index.segment(for: "The team will make the thing well"), "common words aren't evidence")
    }

    // MARK: Saved live captions

    func testLiveCaptionsStandInOnlyUntilTheMacsTranscriptArrives() throws {
        let meeting = recorded()
        let captions = LiveCaptions(meetingID: meeting.id, trackID: trackID, localeIdentifier: "en_US", segments: [
            LiveCaptionSegment(start: 0.4, end: 3.1, text: "The new onboarding has three screens.", isTentative: false),
            LiveCaptionSegment(start: 3.2, end: 5.4, text: "The model download moved", isTentative: true),
        ])
        XCTAssertEqual(SavedCaptions.shown(captions, for: meeting), captions)
        XCTAssertNil(SavedCaptions.shown(captions, for: weekly()), "another conversation's captions never show")
        var transcribed = meeting
        transcribed.transcripts = [TrackTranscript(trackID: trackID, segments: [], modelID: "whisper")]
        XCTAssertNil(SavedCaptions.shown(captions, for: transcribed), "the Mac's transcript replaces them")
        XCTAssertNil(SavedCaptions.shown(LiveCaptions(meetingID: meeting.id, localeIdentifier: "en_US", segments: [
            LiveCaptionSegment(start: 0, end: 1, text: "  ", isTentative: true)]), for: meeting), "nothing to read, nothing shown")

        XCTAssertEqual(SavedCaptions.playback(captions.segments[1], captions: captions, in: meeting), .source(meeting.tracks[0], 3.2),
                       "a caption's time plays the phone's recording")
        XCTAssertEqual(SavedCaptions.playing(at: 4, trackID: trackID, captions: captions, in: meeting), captions.segments[1].id)
        XCTAssertNil(SavedCaptions.playing(at: 4, trackID: UUID(), captions: captions, in: meeting))
        XCTAssertEqual(ProcessingStatus(meeting, now: now), .recorded, "captions don't change the processing state")
        XCTAssertNil(EvidenceIndex(meeting).segment(for: "three screens onboarding"), "captions are never evidence")

        let store = LiveCaptionStore(libraryRoot: try temporaryDirectory())
        try store.save(captions)
        let hits = SavedCaptions.hits(in: [meeting, weekly()], query: "download", store: store)
        XCTAssertEqual(hits.map(\.meeting.id), [meeting.id])
        XCTAssertEqual(hits.first?.segment.text, "The model download moved")
        XCTAssertEqual(SavedCaptions.searchLocation(captions.segments[1]), "Live captions · tentative · 0:03")
        XCTAssertTrue(SavedCaptions.hits(in: [transcribed], query: "download", store: store).isEmpty)
    }

    func testLiveCaptionsOfARecordingIntoATranscribedConversationReadAfterItsTranscript() throws {
        // A conversation transcribed before, recorded into again with captions on: the earlier transcript
        // doesn't cover what they heard, so they show after it, by the rule the Mac reads too.
        var meeting = weekly()
        let began = try XCTUnwrap(meeting.transcripts.map(\.createdAt).max()).addingTimeInterval(600)
        let captions = LiveCaptions(meetingID: meeting.id, localeIdentifier: "en_US", segments: [
            LiveCaptionSegment(start: 0.4, end: 3.1, text: "One more thing about the launch email.", isTentative: false),
        ], createdAt: began)
        XCTAssertFalse(meeting.unifiedTranscript.isEmpty)
        XCTAssertEqual(SavedCaptions.shown(captions, for: meeting), captions)
        XCTAssertFalse(SavedCaptions.standsIn(for: meeting), "after the transcript, not in its place")
        let store = LiveCaptionStore(libraryRoot: try temporaryDirectory())
        try store.save(captions)
        XCTAssertEqual(SavedCaptions.hits(in: [meeting], query: "launch email", store: store).map(\.meeting.id), [meeting.id])

        // The new recording's transcript replaces them.
        meeting.transcripts.append(TrackTranscript(trackID: UUID(), segments: [], createdAt: began.addingTimeInterval(60)))
        XCTAssertNil(SavedCaptions.shown(captions, for: meeting))
        XCTAssertTrue(SavedCaptions.hits(in: [meeting], query: "launch email", store: store).isEmpty)
    }

    // MARK: The transcript

    func testTurnsGroupASpeakersPassagesAndNotesSitAtTheirTimes() {
        let meeting = weekly()
        let rows = TranscriptRow.rows(in: meeting)
        let turns = rows.compactMap { row -> String? in if case .turn(let speaker, _) = row { return speaker } else { return nil } }
        XCTAssertEqual(turns, ["S0", "S1", "S2", "S0", "S1", "S2", "S1"], "Priya's last two passages are one turn")
        let notes = rows.enumerated().compactMap { index, row -> Int? in if case .note = row { return index } else { return nil } }
        XCTAssertEqual(notes.count, 2)
        guard case .passage(let before) = rows[notes[1] - 1] else { return XCTFail("a passage before the 0:24 note") }
        XCTAssertEqual(before.start, 20.2, "the 0:24 note follows the passage it was written during")
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count, "every row is its own scroll target")
    }

    func testABookmarkMarksThePassageItFallsIn() {
        let meeting = weekly()
        let marks = BookmarkMarks(meeting: meeting)
        let holder = meeting.unifiedTranscript[2].id
        XCTAssertEqual(marks.holders, [holder])
        XCTAssertEqual(marks.labelSegments[holder], "Gate on the conflict fix")
        XCTAssertEqual(BookmarkMarks.holder(of: meeting.highlights[0], in: meeting), holder)
    }

    func testPhotosAppearAtTheirTimesAndBreakSpeakerTurns() {
        var meeting = weekly()
        let photo = MeetingPhoto(relativePath: "Originals/Photos/a.jpg", fileName: "a.jpg", sha256: "",
                                 capturedAt: now, time: 5.4, caption: "Whiteboard")
        meeting.photos = [photo]
        let rows = TranscriptRow.rows(in: meeting)
        let index = rows.firstIndex { $0.id == photo.id.uuidString }
        XCTAssertNotNil(index)
        if let index, case .photo(let placed, let time) = rows[index] {
            XCTAssertEqual(placed.id, photo.id)
            XCTAssertEqual(time, 5.4)
            XCTAssertGreaterThan(index, 0)
            XCTAssertLessThan(index, rows.count - 1)
        } else { XCTFail("The photo needs its own transcript row") }
        meeting.removePhoto(photo.id)
        XCTAssertFalse(TranscriptRow.rows(in: meeting).contains { $0.id == photo.id.uuidString })
    }

    func testThePhotoProviderReadsAnOriginalAndReportsMissingPhotos() async throws {
        let root = try temporaryDirectory()
        let library = PhoneLibrary(rootURL: root, installation: "TEST")
        try await library.reload()
        let id = library.controller.newMeeting(title: "Photos")
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 40))
        let bytes = renderer.pngData { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        }
        await library.controller.acquireLock()
        let photo = try await library.controller.addPhoto(data: bytes, to: id)
        library.controller.releaseLock()
        let provider = LocalAudioProvider(library: library)
        let url = try await provider.localPhoto(for: photo, in: id)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertNotNil(PhotoImage.thumbnail(url, maxPixels: 40))
        let meeting = try XCTUnwrap(library.controller.meeting(id))
        let archive = try ExportFiles.markdownWithPhotos(meeting, originals: [photo.id: url], in: root)
        XCTAssertEqual(archive.pathExtension, "zip")
        XCTAssertEqual(Array(try Data(contentsOf: archive).prefix(4)), [0x50, 0x4b, 0x03, 0x04])
        try FileManager.default.removeItem(at: url)
        do {
            _ = try await provider.localPhoto(for: photo, in: id)
            XCTFail("A missing photo must be reported")
        } catch {
            XCTAssertTrue(error is PhotoProvidingError)
        }
    }

    func testPlaybackTargetsResolveToARecordingAndATime() throws {
        let meeting = weekly()
        let passage = meeting.unifiedTranscript[3]
        let resolved = try XCTUnwrap(PlaybackTarget.segment(passage).resolve(in: meeting))
        XCTAssertEqual(resolved.track.id, trackID)
        XCTAssertEqual(resolved.seconds, 20.2)
        XCTAssertEqual(PlaybackTarget.timeline(24).resolve(in: meeting)?.seconds, 24)
        XCTAssertEqual(PlaybackTarget.source(meeting.tracks[0], -3).resolve(in: meeting)?.seconds, 0)
        XCTAssertNil(PlaybackTarget.timeline(3).resolve(in: Meeting(title: "Notes only")))

        let playhead = PlayheadIndex(meeting: meeting)
        XCTAssertEqual(playhead.segmentID(at: 15, trackID: trackID), meeting.unifiedTranscript[2].id)
        XCTAssertNil(playhead.segmentID(at: 13.1, trackID: trackID), "between passages, nothing is playing")
    }

    func testSummaryLinesSplitLikeTheMacsMarkdown() {
        let lines = SummaryLine.lines("Intro line\ncontinued\n\n- First\n* Second\n2. Numbered\n## Heading")
        XCTAssertEqual(lines, [.paragraph("Intro line\ncontinued"), .item(marker: "•", text: "First"), .item(marker: "•", text: "Second"),
                               .item(marker: "2.", text: "Numbered"), .heading("Heading")])
    }

    // MARK: Version History and export

    func testWordChangesMarkOnlyTheWordsThatChanged() {
        let changes = WordChanges.changes(old: WordChanges.tokens("The sink conflict fix"), new: WordChanges.tokens("The sync conflict fix"))
        XCTAssertEqual(Array(changes.removed), [1])
        XCTAssertEqual(Array(changes.inserted), [1])
        let marked = WordChanges.marked(old: AttributedString("The sink conflict fix"), new: AttributedString("The sync conflict fix"),
                                        removed: RevisionMarks.removed(dark: false), inserted: RevisionMarks.inserted(dark: false))
        XCTAssertEqual(String(marked.new.characters), "The sync conflict fix", "marking never changes the text")
    }

    func testMarkdownExportIsAFileNamedAfterTheConversation() throws {
        var meeting = weekly()
        meeting.title = "Q4: launch / beta?"
        let url = try ExportFiles.markdown(meeting, in: try temporaryDirectory())
        XCTAssertEqual(url.lastPathComponent, "Q4- launch - beta-.md")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("# Q4: launch / beta?"))
        XCTAssertTrue(text.contains("**Daniel:** That works."))
        XCTAssertEqual(MeetingExport.fileName(for: "  ...  "), "Conversation")
    }

    /// The recording shared under the conversation's name, the same as the Mac names an export; with several, each
    /// says which it is.
    func testAudioExportIsNamedAfterTheConversation() throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("Microphone.wav")
        try Data("RIFF".utf8).write(to: source)
        var meeting = weekly()
        meeting.title = "Q4: launch / beta?"
        let one = try ExportFiles.audio(source, meeting: meeting, track: meeting.tracks[0], in: directory)
        XCTAssertEqual(one.lastPathComponent, "Q4- launch - beta-.wav", "one recording: the conversation's name alone")

        let soundcore = RecordingTrack(source: .soundcore, relativePath: "Originals/REC0042.wav", fileName: "REC0042.wav", duration: 38)
        meeting.tracks.append(soundcore)
        let second = try ExportFiles.audio(source, meeting: meeting, track: soundcore, in: directory)
        let name = MeetingExport.fileName(for: RecordingWords.name(soundcore, in: meeting))
        XCTAssertEqual(second.lastPathComponent, "Q4- launch - beta- (\(name)).wav")
        ExportFiles.clear([one, second], in: directory)
    }

    /// Exports wait in tmp only until the share sheet is done; a library original handed to it
    /// is never removed.
    func testSharedExportsAreClearedAndNothingElseIs() throws {
        let directory = try temporaryDirectory()
        let meeting = weekly()
        let first = try ExportFiles.markdown(meeting, in: directory)
        var other = weekly()
        other.id = UUID()
        let second = try ExportFiles.markdown(other, in: directory)
        let original = directory.appendingPathComponent("Library/Originals/Photos/a.jpg")
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("photo".utf8).write(to: original)

        ExportFiles.clear([first, original], in: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path), "another export waits for its own share sheet")
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path), "never a file outside the exports")

        ExportFiles.clear(in: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ExportFiles.root(in: directory).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    /// Share Photo hands over a copy without location or camera details, named after its caption.
    func testASharedPhotoLeavesLocationBehind() throws {
        let directory = try temporaryDirectory()
        let original = directory.appendingPathComponent("IMG_0412.jpg")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20)).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        }
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLatitudeRef: "N"]
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try (data as Data).write(to: original)

        let shared = try ExportFiles.photo(original, caption: "Whiteboard: Q4 plan", in: directory)
        XCTAssertEqual(shared.lastPathComponent, "Whiteboard- Q4 plan.jpg")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(shared as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int, 6)
        XCTAssertEqual(try Data(contentsOf: original), data as Data, "the library's original is untouched")
        ExportFiles.clear([shared], in: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.path))
    }

    // MARK: Copy

    private final class PasteboardRecorder: LocalPasteboardWriting {
        var writes: [(items: [[String: Any]], options: [UIPasteboard.OptionsKey: Any])] = []
        func setItems(_ items: [[String: Any]], options: [UIPasteboard.OptionsKey: Any]) { writes.append((items, options)) }
    }

    func testCopiedTextStaysOnThisIPhone() {
        let recorder = PasteboardRecorder()
        LocalPasteboard.copy("We agreed on Friday.", to: recorder)
        XCTAssertEqual(recorder.writes.count, 1)
        XCTAssertEqual(recorder.writes.first?.options[.localOnly] as? Bool, true, "never Universal Clipboard")
        XCTAssertNil(recorder.writes.first?.options[.expirationDate])
        XCTAssertEqual(recorder.writes.first?.items.first?["public.utf8-plain-text"] as? String, "We agreed on Friday.")

        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        LocalPasteboard.copy("Ship it", to: pasteboard)
        XCTAssertEqual(pasteboard.string, "Ship it")
    }

    // MARK: The session across folds

    func testANewNoteIsAConversationWithoutAudioInThePlaceBeingViewed() async throws {
        let library = PhoneLibrary(rootURL: try temporaryDirectory(), installation: "TEST")
        try await library.reload()
        let session = ReadingSession()
        session.place = .library(.section(.work))
        let id = session.newNote(in: library.controller)
        let meeting = try XCTUnwrap(library.controller.meeting(id))
        XCTAssertTrue(meeting.title.hasPrefix("Note at "))
        XCTAssertTrue(meeting.tracks.isEmpty)
        XCTAssertEqual(meeting.placement, .work)
        XCTAssertEqual(ProcessingStatus(meeting), .done, "nothing to transcribe, nothing to wait for")
        XCTAssertEqual(session.openID, id)
        XCTAssertTrue(session.reading)
        XCTAssertEqual(session.pageMode, .summary)
        XCTAssertEqual(session.focusNotesFor, id)

        let folder = library.controller.createFolder(named: "Ideas")
        session.place = .library(.folder(folder))
        let filed = try XCTUnwrap(library.controller.meeting(session.newNote(in: library.controller)))
        XCTAssertEqual(filed.folderID, folder)
    }

    /// The library's rows and the mini player read the player through the reading session: they're told when what
    /// plays, or whether it plays, changes, and not as the position moves.
    func testThePlayerTellsWhatReadsItThroughTheSession() throws {
        let session = ReadingSession()
        let meeting = Meeting(title: "Notes only", date: now)
        let row = Told(), mini = Told(), position = Told()
        withObservationTracking { _ = session.player.meetingID; _ = session.player.isPlaying } onChange: { row.set() }
        withObservationTracking { _ = session.player.isActive(for: meeting.id) } onChange: { mini.set() }
        withObservationTracking { _ = session.player.position } onChange: { position.set() }
        session.player.play(.timeline(0), in: meeting, provider: NoAudio())
        XCTAssertTrue(row.value, "the row that says Playing redraws")
        XCTAssertTrue(mini.value, "the mini player appears")
        XCTAssertFalse(position.value)
        XCTAssertTrue(session.player.isActive(for: meeting.id))
        guard case .unavailable = session.player.phase else { return XCTFail("a conversation without a recording can't play") }
    }

    func testTheSessionCarriesReadingAcrossLayouts() throws {
        let session = ReadingSession()
        let first = UUID(), second = UUID(), segment = UUID()
        session.select(first)
        XCTAssertFalse(session.reading, "on two pages a tap shows the page beside the list")
        XCTAssertTrue(session.chosen)
        session.isNotebook = true
        session.showInTranscript(segment)
        XCTAssertTrue(session.reading, "a jump to the transcript opens the spread on two pages")
        XCTAssertEqual(session.pageMode, .transcript)
        XCTAssertEqual(session.transcriptRequest?.target, segment.uuidString)
        XCTAssertEqual(session.flashedSegment, segment)

        session.transcriptAnchor = segment.uuidString
        session.open(second)
        XCTAssertNil(session.transcriptAnchor, "another conversation opens at its top")
        session.forget(second)
        XCTAssertNil(session.openID)
        XCTAssertFalse(session.reading)

        let meeting = weekly()
        let hit = try XCTUnwrap(LibrarySearch.hits(in: [meeting], text: "Thursday afternoon", tokens: [], scope: .all).first)
        XCTAssertEqual(hit.field, .transcript)
        session.isNotebook = false
        session.pageMode = .summary
        session.open(hit)
        XCTAssertEqual(session.openID, meeting.id)
        XCTAssertTrue(session.reading)
        XCTAssertEqual(session.pageMode, .transcript, "a passage hit opens at the passage")
        XCTAssertEqual(session.transcriptRequest?.target, hit.segmentID?.uuidString)
        XCTAssertNotEqual(first, segment)
    }

    func testTheCreaseIsTheMiddleOfTheWholeDisplay() {
        // iPhone Duo open: 951 pt wide, the status bar column takes 84 pt on the right.
        XCTAssertEqual(CreaseGeometry.crease(width: 867, leadingInset: 0, trailingInset: 84), 475.5)
        XCTAssertEqual(CreaseGeometry.crease(width: 874, leadingInset: 0, trailingInset: 0), 437)
        XCTAssertEqual(CreaseGeometry.crease(width: 300, leadingInset: 0, trailingInset: 400), 300, "never outside the view")
    }

    func testPageColumnUsesTheFullCreaseClearance() {
        XCTAssertEqual(PageColumn.inset(for: .trailing, creaseEdge: .trailing, creaseClearance: 16), 16)
        XCTAssertEqual(PageColumn.inset(for: .leading, creaseEdge: .trailing, creaseClearance: 16), 20)
        XCTAssertEqual(PageColumn.inset(for: .leading, creaseEdge: .leading, creaseClearance: 24), 24)
        let left = ReadingGeometry.frame(width: 475.5, density: .touch, creaseEdge: .trailing)
        XCTAssertEqual(left.trailing, 16)
        let right = ReadingGeometry.frame(width: 391.5, density: .touch, creaseEdge: .leading)
        XCTAssertEqual(right.leading, 16)
    }

    func testLaunchArgumentsAreReadInDebugBuilds() {
        let launch = ReadingLaunch(arguments: ["app", "--select", "Weekly", "--page", "transcript", "--play", "--sheet", "history"])
        XCTAssertEqual(launch.select, "Weekly")
        XCTAssertEqual(launch.page, .transcript)
        XCTAssertEqual(launch.play, 0)
        XCTAssertEqual(launch.sheet, "history")
        XCTAssertTrue(ReadingLaunch(arguments: ["app"]).isEmpty)
    }

    // MARK: The notes editor

    func testTheNotesEditorPutsEachTimeOnItsParagraph() {
        let view = MarginTextView()
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 400)
        view.times = [2, nil, 75]
        view.setText("First thought\n\nUntimed line\nA much longer third paragraph that wraps onto a second line at this width, surely")
        let times = view.laneTimes
        XCTAssertEqual(times.map(\.text), ["0:02", "1:15"], "the untimed paragraph shows no time; blank lines aren't paragraphs")
        XCTAssertLessThan(times[0].baseline, times[1].baseline)
        XCTAssertGreaterThan(view.height(forWidth: 320), view.height(forWidth: 2000), "it grows as the text wraps")

        view.baseLane = 0
        XCTAssertEqual(view.laneTimes.count, 0, "no lane, no times")
    }

    // MARK: Audio

    func testTheLocalProviderPlaysOnlyWhatIsOnThisIPhone() async throws {
        let root = try temporaryDirectory()
        let library = PhoneLibrary(rootURL: root, installation: "TEST")
        let rig = RecorderRig()
        let id = UUID()
        try await rig.recorder.start(in: library.stagingURL.appendingPathComponent(id.uuidString), id: id, title: "Played")
        rig.pump(2)
        let meeting = try await library.file(try await rig.stop())
        let track = try XCTUnwrap(meeting.tracks.first)

        let provider = LocalAudioProvider(library: library)
        let availability = await provider.availability(of: track, in: meeting.id)
        XCTAssertEqual(availability, .local)
        let url = try await provider.localAudio(for: track, in: meeting.id) { _ in }
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: url.path))

        // Evicted (or never downloaded): it says so, and doesn't pretend to fetch it.
        try FileManager.default.removeItem(at: url)
        let gone = await provider.availability(of: track, in: meeting.id)
        XCTAssertEqual(gone, .offline)
        do {
            _ = try await provider.localAudio(for: track, in: meeting.id) { _ in }
            XCTFail("an evicted file can't play")
        } catch {
            XCTAssertEqual(error as? AudioProvidingError, .offline)
            XCTAssertEqual(error.localizedDescription, "The audio isn’t on this iPhone yet. It downloads when you’re online.")
        }
        do {
            _ = try await LocalAudioProvider().localAudio(for: track, in: meeting.id) { _ in }
            XCTFail("the unbound default has no library")
        } catch {
            XCTAssertEqual(error as? AudioProvidingError, .notConfigured)
        }
    }

    func testTheTrashListsWhatWasMovedThere() async throws {
        let root = try temporaryDirectory()
        let library = PhoneLibrary(rootURL: root, installation: "TEST")
        try await library.reload()
        let kept = library.controller.newMeeting(title: "Kept")
        let trashed = library.controller.newMeeting(title: "Offsite ideas")
        await library.controller.flush()
        let moved = try await library.controller.moveToTrash(trashed)
        XCTAssertTrue(moved)
        let listed = await library.controller.trashedMeetings()
        XCTAssertEqual(listed.map(\.title), ["Offsite ideas"])
        try await library.controller.restoreFromTrash(trashed)
        XCTAssertEqual(Set(library.controller.meetings.map(\.id)), [kept, trashed])
        let after = await library.controller.trashedMeetings()
        XCTAssertTrue(after.isEmpty)
    }
}

/// Whether an observation was told of a change (its callback is `@Sendable`).
private final class Told: @unchecked Sendable {
    private let lock = NSLock()
    private var told = false
    var value: Bool { lock.withLock { told } }
    func set() { lock.withLock { told = true } }
}

/// Audio that never arrives: the player is asked for a recording the conversation doesn't have.
private struct NoAudio: AudioProviding {
    @MainActor func availability(of track: RecordingTrack, in meetingID: UUID) async -> AudioAvailability { .missing }
    @MainActor func localAudio(for track: RecordingTrack, in meetingID: UUID, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        throw CancellationError()
    }
}
