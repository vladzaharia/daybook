import XCTest
@testable import DaybookCore

/// Unsure words (docs/architecture.md, "Unsure words"): where a recording's latest transcript and its previous one
/// disagree, and words the recognizer was unsure of, flagged on the transcript, never over the person's own words, and
/// answered once for every device. Synthetic transcripts; no models.
final class TranscriptFlagsTests: XCTestCase {
    private let track = UUID()

    /// One run of the recording: `passages` of words, each word 0.4 s from `start` on, with the confidences given (else
    /// 0.98), its words kept as a recognizer keeps them.
    private func run(_ passages: [String], start: Double = 10, at time: Double, confidence: [String: Double] = [:],
                     model: String = "parakeet/ultra", words keepsWords: Bool = true) -> TrackTranscript {
        var clock = start
        var segments: [TranscriptSegment] = [], words: [TranscriptWord] = []
        for passage in passages {
            let pieces = passage.split(separator: " ").map(String.init)
            let first = clock
            for piece in pieces {
                words.append(TranscriptWord(text: " " + piece, start: clock, end: clock + 0.35, confidence: confidence[piece] ?? 0.98))
                clock += 0.4
            }
            segments.append(TranscriptSegment(trackID: track, start: first, end: clock - 0.05, text: passage))
            clock += 0.6
        }
        return TrackTranscript(trackID: track, segments: segments, modelID: model, createdAt: Date(timeIntervalSince1970: time),
                               processingSettings: ProcessingSettings(modelID: model), words: keepsWords ? words : nil)
    }

    private func meeting(_ runs: TrackTranscript...) -> Meeting {
        var meeting = Meeting(tracks: [RecordingTrack(id: track, source: .microphone, relativePath: "Originals/mic.caf",
                                                      fileName: "mic.caf", duration: 120, offset: 0)])
        meeting.transcripts = runs
        fuse(&meeting)
        return meeting
    }

    private func fuse(_ meeting: inout Meeting) {
        meeting.applyFusion(SourceFusion.fuse(meeting).fusion)
    }

    private func shown(_ meeting: Meeting) -> [TranscriptFlagMark] {
        meeting.transcriptFlagMarks.values.flatMap { $0 }.sorted { $0.flag.start < $1.flag.start }
    }

    private func words(_ mark: TranscriptFlagMark, in meeting: Meeting) -> String? {
        meeting.unifiedTranscript.first { $0.id == mark.segmentID }.flatMap { mark.words(in: $0.text) }
    }

    // MARK: Disagreement

    func testAWordReadDifferentlyIsFlaggedWithTheEarlierReadingAcrossDifferentPassages() throws {
        let meeting = meeting(run(["We ship the calendar on Thursday at noon."], at: 1),
                              run(["We ship the calendar", "on Friday at noon."], at: 2))
        let marks = shown(meeting)
        XCTAssertEqual(marks.count, 1)
        let mark = try XCTUnwrap(marks.first)
        XCTAssertEqual(mark.flag.reason, .disagreement)
        XCTAssertEqual(mark.flag.text, "Friday")
        XCTAssertEqual(mark.flag.alternative, "Thursday")
        XCTAssertEqual(words(mark, in: meeting), "Friday")
        XCTAssertEqual(mark.flag.trackID, track)
        XCTAssertEqual(mark.flag.start, 12.6, accuracy: 0.01, "In the recording's own time")
    }

    func testWordsTheLatestTranscriptAddedAreFlaggedWithNothingAsTheEarlierReading() throws {
        let meeting = meeting(run(["We should go there now"], at: 1), run(["We really should go there now"], at: 2))
        let mark = try XCTUnwrap(shown(meeting).first)
        XCTAssertEqual(shown(meeting).count, 1)
        XCTAssertEqual(mark.flag.text, "really")
        XCTAssertEqual(mark.flag.alternative, "")
        XCTAssertEqual(mark.replacing(in: "We really should go there now"), "We should go there now")
    }

    func testWordsTheLatestTranscriptLeftOutAreFlaggedOnTheWordBesideThem() throws {
        let earlier = run(["We should not ship it yet"], at: 1)
        // The same audio without "not": the other words stay where they were heard.
        var latest = earlier
        latest.id = UUID()
        latest.createdAt = Date(timeIntervalSince1970: 2)
        latest.words = earlier.words?.filter { $0.text != " not" }
        latest.segments = [TranscriptSegment(trackID: track, start: 10, end: earlier.segments[0].end, text: "We should ship it yet")]
        let meeting = meeting(earlier, latest)
        let mark = try XCTUnwrap(shown(meeting).first)
        XCTAssertEqual(shown(meeting).count, 1)
        XCTAssertEqual(mark.flag.text, "should")
        XCTAssertEqual(mark.flag.alternative, "should not")
        XCTAssertEqual(mark.replacing(in: "We should ship it yet"), "We should not ship it yet")
    }

    func testPunctuationCaseAndSpacingAreNotDisagreements() {
        let meeting = meeting(run(["okay so the ice cream budget is fine"], at: 1),
                              run(["Okay, so the icecream budget is fine."], at: 2))
        XCTAssertNil(meeting.transcriptFlags)
        XCTAssertTrue(shown(meeting).isEmpty)
    }

    func testTranscriptsOfDifferentSpeechAreNotCompared() {
        let meeting = meeting(run(["Bonjour à tous merci d'être venus aujourd'hui"], at: 1),
                              run(["Hello everyone thanks for coming in today"], at: 2))
        XCTAssertNil(meeting.transcriptFlags, "Nothing in common: every word would be flagged")
    }

    func testRunsWithoutSavedWordsAreComparedByTheirPassages() throws {
        let meeting = meeting(run(["Priya owns the pricing page copy"], at: 1, words: false),
                              run(["Maria owns the pricing page copy"], at: 2, words: false))
        let mark = try XCTUnwrap(shown(meeting).first)
        XCTAssertEqual(mark.flag.text, "Maria")
        XCTAssertEqual(mark.flag.alternative, "Priya")
    }

    func testASpeakerOnlyRunRepeatsItsWordsSoTheRunBeforeItIsTheEarlierReading() throws {
        let first = run(["Jordan will review the migration"], at: 1)
        let second = run(["Jordan will review the integration"], at: 2)
        var refresh = second
        refresh.id = UUID()
        refresh.createdAt = Date(timeIntervalSince1970: 3)
        let meeting = meeting(first, second, refresh)
        XCTAssertEqual(shown(meeting).map(\.flag.text), ["integration"])
        XCTAssertEqual(shown(meeting).first?.flag.alternative, "migration")
    }

    func testASharedWordAloneInItsPassageBetweenTwoDifferencesIsntFlagged() {
        let meeting = meeting(run(["we meet on Thursday okay late see you"], at: 1),
                              run(["we meet on Friday", "Okay.", "Great see you"], at: 2))
        XCTAssertEqual(shown(meeting).map(\.flag.text), ["Friday", "Great"])
        XCTAssertEqual(shown(meeting).map(\.flag.alternative), ["Thursday", "late"])
    }

    func testOneRunGivesNoDisagreement() {
        XCTAssertNil(meeting(run(["We ship on Friday"], at: 1)).transcriptFlags)
    }

    func testTheSameFlagsComeOutOnEveryDevice() {
        let a = meeting(run(["We ship on Thursday"], at: 1), run(["We ship on Friday"], at: 2))
        let b = meeting(run(["We ship on Thursday"], at: 1), run(["We ship on Friday"], at: 2))
        XCTAssertEqual(a.transcriptFlags, b.transcriptFlags, "IDs come from what they mark")
    }

    func testFlagsAreWorkedOutOffTheMainActorAsFusionIs() {
        var direct = meeting(run(["We ship on Thursday"], at: 1))
        direct.transcripts.append(run(["We ship on Friday"], at: 2))
        var prepared = direct
        let fusion = SourceFusion.fuse(direct).fusion
        direct.applyFusion(fusion)
        prepared.applyFusion(prepared.preparingFusion(fusion))
        XCTAssertNotNil(direct.transcriptFlags)
        XCTAssertEqual(prepared.transcriptFlags, direct.transcriptFlags)
    }

    // MARK: Low confidence

    func testWordsTheRecognizerWasUnsureOfAreFlaggedNeighboursTogether() throws {
        let floor = try XCTUnwrap(TranscriptFlags.confidenceFloors["parakeet"])
        let meeting = meeting(run(["We met Siobhan Ní Bhriain at the depot"], at: 1,
                                  confidence: ["Siobhan": floor * 0.8, "Ní": floor / 2, "Bhriain": floor * 0.95, "depot": min(1, floor + 0.01)]))
        let marks = shown(meeting)
        XCTAssertEqual(marks.map(\.flag.text), ["Siobhan Ní Bhriain"])
        XCTAssertEqual(marks.first?.flag.reason, .lowConfidence)
        XCTAssertEqual(try XCTUnwrap(marks.first?.flag.confidence), floor / 2, accuracy: 0.0001)
        XCTAssertNil(marks.first?.flag.alternative)
        XCTAssertEqual(words(try XCTUnwrap(marks.first), in: meeting), "Siobhan Ní Bhriain")
    }

    func testARecognizerWhoseConfidencesArentCalibratedFlagsNothingByThem() {
        let meeting = meeting(run(["We met Siobhan at the depot"], at: 1, confidence: ["Siobhan": 0.01], model: "someone/new-recognizer"))
        XCTAssertNil(meeting.transcriptFlags)
    }

    func testAWordBothSignalsMarkIsFlaggedOnceAsADisagreement() throws {
        let floor = try XCTUnwrap(TranscriptFlags.confidenceFloors["parakeet"])
        let meeting = meeting(run(["We ship on Thursday"], at: 1), run(["We ship on Friday"], at: 2, confidence: ["Friday": floor / 2]))
        XCTAssertEqual(shown(meeting).map(\.flag.reason), [.disagreement])
        XCTAssertEqual(try XCTUnwrap(shown(meeting).first?.flag.confidence), floor / 2, accuracy: 0.0001)
    }

    // MARK: The person's words

    func testCorrectingTheFlaggedWordsClearsThemAndNothingTheyWereMarkedOnIsFlaggedAgain() throws {
        var meeting = meeting(run(["We ship on Thursday"], at: 1), run(["We ship on Friday"], at: 2))
        let passage = try XCTUnwrap(meeting.unifiedTranscript.first)
        XCTAssertEqual(shown(meeting).count, 1)
        meeting.correctSegment(id: passage.id, text: "We ship on Monday")
        XCTAssertTrue(shown(meeting).isEmpty, "Changing the flagged words clears the flag at once")
        XCTAssertEqual(meeting.revisions.last?.kind, .segment(passage.id))
        fuse(&meeting)
        XCTAssertEqual(meeting.unifiedTranscript.first?.text, "We ship on Monday")
        XCTAssertNil(meeting.transcriptFlags, "Fused again, the person's words get no flags")
    }

    func testACorrectionClearsOnlyTheFlagsOnTheWordsItChanged() throws {
        var meeting = meeting(run(["We ship on Thursday and then Priya owns the pricing page"], at: 1),
                              run(["We ship on Friday and then Maria owns the pricing page"], at: 2))
        let passage = try XCTUnwrap(meeting.unifiedTranscript.first)
        XCTAssertEqual(shown(meeting).map(\.flag.text), ["Friday", "Maria"])
        // The person fixes the page's name: both flags are on words they left alone.
        meeting.correctSegment(id: passage.id, text: "We ship on Friday and then Maria owns the Pricing Page")
        XCTAssertEqual(shown(meeting).map(\.flag.text), ["Friday", "Maria"])
        XCTAssertEqual(try shown(meeting).map { try XCTUnwrap(words($0, in: meeting)) }, ["Friday", "Maria"], "Found in the corrected text")
        // Words are added before them: still found where they are.
        meeting.correctSegment(id: passage.id, text: "Well, we ship on Friday and then Maria owns the Pricing Page")
        XCTAssertEqual(try shown(meeting).map { try XCTUnwrap(words($0, in: meeting)) }, ["Friday", "Maria"])
        fuse(&meeting)
        XCTAssertEqual(shown(meeting).map(\.flag.text), ["Friday", "Maria"], "Fused again, the same")
        // One of them changed: that flag goes, the other stays.
        meeting.correctSegment(id: passage.id, text: "Well, we ship on Monday and then Maria owns the Pricing Page")
        XCTAssertEqual(shown(meeting).map(\.flag.text), ["Maria"])
        fuse(&meeting)
        XCTAssertEqual(shown(meeting).map(\.flag.text), ["Maria"])
        XCTAssertEqual(meeting.transcriptFlags?.map(\.text), ["Maria"])
    }

    func testTakingOneAlternativeLeavesTheOtherUnansweredFlagsInThePassage() throws {
        var meeting = meeting(run(["We ship on Thursday and then Priya owns the pricing page"], at: 1),
                              run(["We ship on Friday and then Maria owns the pricing page"], at: 2))
        let marks = shown(meeting)
        XCTAssertEqual(marks.map(\.flag.text), ["Friday", "Maria"])
        XCTAssertTrue(meeting.useFlagAlternative(marks[0].flag.id))
        XCTAssertEqual(meeting.unifiedTranscript.first?.text, "We ship on Thursday and then Maria owns the pricing page")
        XCTAssertEqual(shown(meeting).map(\.flag.text), ["Maria"], "One answer stored, one flag answered")
        XCTAssertEqual(meeting.transcriptFlagDismissals?.map(\.id), [marks[0].flag.id])
        XCTAssertEqual(try words(XCTUnwrap(shown(meeting).first), in: meeting), "Maria")
        XCTAssertTrue(meeting.useFlagAlternative(marks[1].flag.id))
        XCTAssertEqual(meeting.unifiedTranscript.first?.text, "We ship on Thursday and then Priya owns the pricing page")
        XCTAssertTrue(shown(meeting).isEmpty)
        fuse(&meeting)
        XCTAssertTrue(shown(meeting).isEmpty)
    }

    func testWordsAPersonTypedAreNeverFlaggedEvenWhereTheyMatchAFlag() throws {
        var meeting = meeting(run(["Maria owns it and Mario checks"], at: 1), run(["Maria owns it and Maria checks"], at: 2))
        let passage = try XCTUnwrap(meeting.unifiedTranscript.first)
        let flag = try XCTUnwrap(shown(meeting).first?.flag)
        XCTAssertEqual(flag.text, "Maria")
        XCTAssertGreaterThan(flag.start, 11, "The second Maria")
        // The person corrects the first Maria (not flagged) to another name, and the flagged one to "Mario".
        meeting.correctSegment(id: passage.id, text: "Marie owns it and Mario checks")
        XCTAssertTrue(shown(meeting).isEmpty)
        // They type "Maria" over the first, and the flagged second one to Mario: nothing marks what they typed.
        meeting.correctSegment(id: passage.id, text: "Maria owns it and Mario checks")
        XCTAssertTrue(shown(meeting).isEmpty, "The Maria that shows is the one they typed, not the one that was heard")
    }

    func testKeepingTheWordsClearsTheFlagWithoutChangingTheTranscript() throws {
        var meeting = meeting(run(["We ship on Thursday"], at: 1), run(["We ship on Friday"], at: 2))
        let flag = try XCTUnwrap(shown(meeting).first?.flag)
        let before = meeting.unifiedTranscript
        let revisions = meeting.revisions.count
        XCTAssertTrue(meeting.keepFlaggedWords(flag.id))
        XCTAssertTrue(shown(meeting).isEmpty)
        XCTAssertEqual(meeting.unifiedTranscript, before)
        XCTAssertEqual(meeting.revisions.count, revisions, "Nothing to put in Version History")
        XCTAssertEqual(meeting.transcriptFlagDismissals?.map(\.outcome), [.kept])
        XCTAssertFalse(meeting.keepFlaggedWords(flag.id), "Once")
    }

    func testTakingTheAlternativeCorrectsThePassageInVersionHistoryAndClearsTheFlag() throws {
        var meeting = meeting(run(["We ship the calendar on Thursday at noon."], at: 1),
                              run(["We ship the calendar", "on Friday at noon."], at: 2))
        let mark = try XCTUnwrap(shown(meeting).first)
        XCTAssertTrue(meeting.useFlagAlternative(mark.flag.id))
        let passage = try XCTUnwrap(meeting.unifiedTranscript.first { $0.id == mark.segmentID })
        XCTAssertEqual(passage.text, "on Thursday at noon.")
        let entry = try XCTUnwrap(meeting.revisions.last)
        XCTAssertEqual(entry.kind, .segment(mark.segmentID))
        XCTAssertEqual(entry.oldValue, "on Friday at noon.")
        XCTAssertEqual(entry.newValue, "on Thursday at noon.")
        XCTAssertTrue(shown(meeting).isEmpty)
        XCTAssertEqual(meeting.transcriptFlagDismissals?.map(\.outcome), [.alternative])
        fuse(&meeting)
        XCTAssertEqual(meeting.unifiedTranscript.first { $0.id == mark.segmentID }?.text, "on Thursday at noon.", "The correction carries over")
        XCTAssertTrue(shown(meeting).isEmpty)
    }

    func testAFlagWithoutAnAlternativeCantBeTakenAndNothingIsLeftEmpty() throws {
        let floor = try XCTUnwrap(TranscriptFlags.confidenceFloors["parakeet"])
        var unsure = meeting(run(["We met Siobhan"], at: 1, confidence: ["Siobhan": floor / 2]))
        let flag = try XCTUnwrap(shown(unsure).first?.flag)
        XCTAssertFalse(unsure.useFlagAlternative(flag.id))
        var added = meeting(run(["Fine"], at: 1), run(["Fine", "really"], at: 2))
        let mark = try XCTUnwrap(shown(added).first)
        XCTAssertEqual(mark.flag.text, "really")
        XCTAssertNil(mark.replacing(in: "really"), "A passage is never corrected to nothing")
        XCTAssertFalse(added.useFlagAlternative(mark.flag.id))
    }

    func testAnsweredFlagsStayAnsweredWhenFusedAgainAndAfterALaterRunThatReadsTheSame() throws {
        var meeting = meeting(run(["We ship on Thursday with Priya"], at: 1), run(["We ship on Friday with Maria"], at: 2))
        XCTAssertEqual(shown(meeting).count, 1, "One phrase: a shared word between two differences joins them")
        let flag = try XCTUnwrap(shown(meeting).first?.flag)
        XCTAssertEqual(flag.text, "Friday with Maria")
        meeting.keepFlaggedWords(flag.id)
        fuse(&meeting)
        XCTAssertTrue(shown(meeting).isEmpty)
        XCTAssertEqual(meeting.transcriptFlags?.map(\.id), [flag.id], "Stored with the transcript, answered or not")
        // A third run reads the words the same way, a little later: still answered.
        meeting.transcripts.append(run(["We ship on Friday with Maria"], start: 10.08, at: 3))
        fuse(&meeting)
        XCTAssertTrue(shown(meeting).isEmpty)
        // A fourth reads them differently: a new question.
        meeting.transcripts.append(run(["We ship on Monday with Maria"], at: 4))
        fuse(&meeting)
        XCTAssertEqual(shown(meeting).map(\.flag.text), ["Monday"])
        XCTAssertEqual(shown(meeting).first?.flag.alternative, "Friday")
    }

    // MARK: Several recordings

    func testWordsAnotherRecordingHeardTheSameWayArentFlagged() throws {
        var meeting = meeting(run(["We ship on Thursday"], at: 1), run(["We ship on Friday"], at: 2))
        XCTAssertEqual(shown(meeting).count, 1)
        // The passage as fusion makes it when a second recording heard every word the same way.
        let other = UUID()
        var passage = meeting.unifiedTranscript[0]
        passage.provenance.append(SegmentProvenance(trackID: other, segmentID: UUID(), start: 3, end: 5, text: passage.text,
                                                    wordIndices: [0, 1, 2, 3]))
        meeting.unifiedTranscript[0] = passage
        XCTAssertTrue(shown(meeting).isEmpty)
        meeting.unifiedTranscript[0].provenance[1].wordIndices = [0, 1, 2]
        XCTAssertEqual(shown(meeting).count, 1, "Unless it heard the flagged word differently")
    }

    func testAgreementCountsWordsAsFusionDoesWithPunctuationOnTheWordBefore() throws {
        var meeting = meeting(run(["I think — we ship on Thursday"], at: 1), run(["I think — we ship on Friday"], at: 2))
        let mark = try XCTUnwrap(shown(meeting).first)
        XCTAssertEqual(mark.flag.text, "Friday")
        // Fusion's words: I, think —, we, ship, on, Friday: "Friday" is its sixth.
        meeting.unifiedTranscript[0].provenance.append(SegmentProvenance(trackID: UUID(), segmentID: UUID(), start: 3, end: 6,
                                                                         text: meeting.unifiedTranscript[0].text, wordIndices: [5]))
        XCTAssertTrue(shown(meeting).isEmpty, "The other recording heard \"Friday\" too")
        meeting.unifiedTranscript[0].provenance[1].wordIndices = [4]
        XCTAssertEqual(shown(meeting).map(\.flag.text), ["Friday"], "It heard \"on\", not \"Friday\"")
    }

    func testTakingAnAlternativeChangesOnlyTheFlaggedWords() throws {
        let flag = TranscriptFlag(trackID: track, start: 0, end: 1, text: "Vraiment", reason: .disagreement, alternative: "Exactement")
        let text = "Vraiment\u{00A0}? Oui,  bien sûr ."
        XCTAssertEqual(TranscriptFlagMark(flag: flag, segmentID: UUID(), range: 0..<8).replacing(in: text),
                       "Exactement\u{00A0}? Oui,  bien sûr .", "The rest of the passage as it was")
    }

    /// The passage with the word at `range` taken out, or put as `alternative` (nil: taken out).
    private func replaced(_ text: String, _ words: String, with alternative: String = "") -> String? {
        let range = (text as NSString).range(of: words)
        let flag = TranscriptFlag(trackID: track, start: 0, end: 1, text: words, reason: .disagreement, alternative: alternative)
        return TranscriptFlagMark(flag: flag, segmentID: UUID(), range: range.location..<(range.location + range.length)).replacing(in: text)
    }

    func testTakingWordsOutLeavesWellFormedText() {
        XCTAssertEqual(replaced("We met, really, early", "really"), "We met, early", "No doubled comma")
        XCTAssertEqual(replaced("Okay — really — fine", "really"), "Okay — fine", "No doubled dash")
        XCTAssertEqual(replaced("It was fine (really) yes", "really"), "It was fine yes", "No empty brackets")
        XCTAssertEqual(replaced("He said “really” and left", "really"), "He said and left", "No empty quotes")
        XCTAssertEqual(replaced("I think so. Really. We go", "Really"), "I think so. We go", "No doubled full stop")
        XCTAssertEqual(replaced("Really, we should go.", "Really"), "We should go.", "A sentence starts with a capital")
        XCTAssertEqual(replaced("Vraiment, on y va", "Vraiment"), "On y va")
        XCTAssertEqual(replaced("We really, should go", "really"), "We should go", "The comma went with the word")
        XCTAssertEqual(replaced("We should go really.", "really"), "We should go.", "The sentence still ends")
        XCTAssertEqual(replaced("We should go, really", "really"), "We should go", "Nothing dangling at the end")
        XCTAssertEqual(replaced("We met. Really we should go", "Really"), "We met. We should go")
        XCTAssertEqual(replaced("(fine, really) yes", "really"), "(fine) yes")
        XCTAssertNil(replaced("Really", "Really"), "A passage is never corrected to nothing")
        XCTAssertNil(replaced("Really.", "Really"))
    }

    func testAnAlternativeSharingANeighbourKeepsThePassagesOwnSpelling() {
        XCTAssertEqual(replaced("We should go", "We", with: "so we"), "So we should go", "A shared word loses its sentence-start capital")
        XCTAssertEqual(replaced("Send it to Maria today", "to Maria", with: "to maria"), "Send it to Maria today", "Its own case and spelling")
        XCTAssertEqual(replaced("Ship it Friday with Maria", "Friday with Maria", with: "thursday with maria"), "Ship it thursday with Maria", "Only the words the passage lacks come from the earlier reading")
        XCTAssertEqual(replaced("Friday is fine", "Friday", with: "thursday"), "Thursday is fine", "A sentence starts with a capital")
        XCTAssertEqual(replaced("We ship on Friday.", "Friday", with: "Thursday."), "We ship on Thursday.")
    }

    func testAFlagShowsOnlyWhereThePassageStillReadsIt() throws {
        var meeting = meeting(run(["We ship on Thursday"], at: 1), run(["We ship on Friday"], at: 2))
        XCTAssertEqual(shown(meeting).count, 1)
        meeting.unifiedTranscript[0].text = "We ship on Monday"
        XCTAssertTrue(shown(meeting).isEmpty)
    }

    // MARK: Sync

    func testAnswersMergeOneAtATimeAndAnUndoneAnswerStaysUndone() throws {
        var base = meeting(run(["We ship on Thursday and then Priya owns pricing"], at: 1),
                           run(["We ship on Friday and then Maria owns pricing"], at: 2))
        let flags = try XCTUnwrap(base.transcriptFlags)
        XCTAssertEqual(flags.map(\.text), ["Friday", "Maria"])
        base.updatedAt = Date(timeIntervalSince1970: 10)
        var local = base, remote = base
        local.keepFlaggedWords(flags[0].id, at: Date(timeIntervalSince1970: 20))
        remote.useFlagAlternative(flags[1].id, at: Date(timeIntervalSince1970: 30))
        let merged = MeetingMerge.merge(base: base, local: local, remote: remote)
        XCTAssertEqual(merged.meeting.transcriptFlagDismissals?.count, 2)
        XCTAssertTrue(merged.warnings.isEmpty, "\(merged.warnings)")
        XCTAssertTrue(shown(merged.meeting).isEmpty)
        XCTAssertEqual(merged.meeting, MeetingMerge.merge(base: base, local: remote, remote: local).meeting, "Either order")
        XCTAssertEqual(MeetingMerge.merge(base: base, local: merged.meeting, remote: merged.meeting).meeting, merged.meeting)

        // Both devices answer the same flag at once: one answer, the earlier, and no conflict.
        var a = base, b = base
        a.keepFlaggedWords(flags[0].id, at: Date(timeIntervalSince1970: 40))
        b.keepFlaggedWords(flags[0].id, at: Date(timeIntervalSince1970: 35))
        let both = MeetingMerge.merge(base: base, local: a, remote: b)
        XCTAssertEqual(both.meeting.transcriptFlagDismissals?.map(\.dismissedAt), [Date(timeIntervalSince1970: 35)])
        XCTAssertFalse(both.meeting.revisions.contains { if case .sync = $0.kind { return true } else { return false } })

        // Undo on one device takes the answer back while the other didn't touch it.
        var answered = base
        answered.keepFlaggedWords(flags[0].id, at: Date(timeIntervalSince1970: 50))
        var undone = answered
        undone.transcriptFlagDismissals = nil
        let afterUndo = MeetingMerge.merge(base: answered, local: undone, remote: answered)
        XCTAssertNil(afterUndo.meeting.transcriptFlagDismissals)
        XCTAssertEqual(shown(afterUndo.meeting).count, 2)

        // Answered again on one device while the other took the answer back: the new answer stays.
        var again = answered
        again.transcriptFlagDismissals = nil
        again.useFlagAlternative(flags[0].id, at: Date(timeIntervalSince1970: 60))
        for merged in [MeetingMerge.merge(base: answered, local: again, remote: undone), MeetingMerge.merge(base: answered, local: undone, remote: again)] {
            XCTAssertEqual(merged.meeting.transcriptFlagDismissals?.map(\.outcome), [.alternative])
        }

        // Two devices that made the same conversation apart keep every answer.
        let apart = MeetingMerge.merge(base: nil, local: local, remote: remote)
        XCTAssertEqual(apart.meeting.transcriptFlagDismissals?.count, 2)
    }

    func testDevicesFusingTheSameTranscriptsStoreTheSameFlagsWhateverAnswersReachedThem() throws {
        var answered = meeting(run(["We ship on Thursday"], at: 1), run(["We ship on Friday"], at: 2))
        let unanswered = answered
        try answered.keepFlaggedWords(XCTUnwrap(answered.transcriptFlags?.first?.id))
        fuse(&answered)
        XCTAssertEqual(answered.transcriptFlags, unanswered.transcriptFlags, "No conflict in the transcript's view")
        XCTAssertTrue(shown(answered).isEmpty)
        XCTAssertEqual(shown(unanswered).count, 1)
    }

    func testFlagsTravelWithTheTranscriptTheyMark() throws {
        let base = meeting(run(["We ship on Thursday"], at: 1))
        var local = base
        local.transcripts.append(run(["We ship on Friday"], at: 2))
        fuse(&local)
        XCTAssertNotNil(local.transcriptFlags)
        let merged = MeetingMerge.merge(base: base, local: local, remote: base).meeting
        XCTAssertEqual(merged.transcriptFlags, local.transcriptFlags)
        XCTAssertEqual(merged.unifiedTranscript, local.unifiedTranscript)
        XCTAssertEqual(shown(merged).count, 1)
    }

    // MARK: Storage

    func testConversationsWithoutFlagsStillLoadAndNewerFieldsRoundTrip() throws {
        var meeting = meeting(run(["We ship on Thursday"], at: 1), run(["We ship on Friday"], at: 2))
        let flag = try XCTUnwrap(meeting.transcriptFlags?.first)
        meeting.keepFlaggedWords(flag.id)
        // As an earlier Daybook wrote it: neither key.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(meeting)) as? [String: Any])
        json["transcriptFlags"] = nil
        json["transcriptFlagDismissals"] = nil
        let old = try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.transcriptFlags)
        XCTAssertNil(old.transcriptFlagDismissals)
        XCTAssertEqual(old.schemaVersion, 1)

        // As a newer Daybook might write it: a reason and an outcome this version doesn't know, and keys of its own.
        json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(meeting)) as? [String: Any])
        var flags = try XCTUnwrap(json["transcriptFlags"] as? [[String: Any]])
        flags[0]["reason"] = "speakerOverlap"
        flags[0]["heardBy"] = ["watch"]
        json["transcriptFlags"] = flags
        var answers = try XCTUnwrap(json["transcriptFlagDismissals"] as? [[String: Any]])
        answers[0]["outcome"] = "laterReview"
        answers[0]["device"] = "Mac"
        json["transcriptFlagDismissals"] = answers
        let newer = try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(newer.transcriptFlags?.first?.reason, .lowConfidence, "Read as the most neutral reason")
        XCTAssertEqual(newer.transcriptFlags?.first?.unknownFields["heardBy"], .array([.string("watch")]))
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(newer)) as? [String: Any])
        let flag0 = try XCTUnwrap((written["transcriptFlags"] as? [[String: Any]])?.first)
        XCTAssertEqual(flag0["reason"] as? String, "speakerOverlap")
        XCTAssertNotNil(flag0["heardBy"])
        let answer0 = try XCTUnwrap((written["transcriptFlagDismissals"] as? [[String: Any]])?.first)
        XCTAssertEqual(answer0["outcome"] as? String, "laterReview")
        XCTAssertEqual(answer0["device"] as? String, "Mac")
    }

    // MARK: Alignment

    func testTheAlignmentKeepsWordsSideBySideAcrossALongRecording() throws {
        // An hour of words, with one word changed every minute or so: the comparison stays in its band.
        let vocabulary = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet"]
        var latest: [TranscriptFlags.Token] = [], earlier: [TranscriptFlags.Token] = []
        for index in 0..<9_000 {
            let start = Double(index) * 0.4
            let word = vocabulary[(index * 7) % vocabulary.count]
            latest.append(.init(key: word, text: word, start: start, end: start + 0.35, confidence: nil, segment: index / 20))
            let heard = index % 150 == 75 ? "kilo" : word
            earlier.append(.init(key: heard, text: heard, start: start + 0.05, end: start + 0.4, confidence: nil, segment: index / 25))
        }
        let flags = TranscriptFlags.disagreements(latest, earlier, trackID: track)
        XCTAssertEqual(flags.count, 60)
        XCTAssertTrue(flags.allSatisfy { $0.flag.alternative == "kilo" && $0.indices.count == 1 })
    }
}
