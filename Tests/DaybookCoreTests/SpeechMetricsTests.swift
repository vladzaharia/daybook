import XCTest
@testable import DaybookCore

/// The evaluation harness's math on synthetic references: known WER, cpWER, DER/JER, and word-timing
/// cases, plus the edge cases (empty references, overlapping speech, collars, permuted labels).
final class SpeechMetricsTests: XCTestCase {
    // MARK: Text

    func testNormalizationIgnoresCasePunctuationAndApostropheStyle() {
        XCTAssertEqual(TranscriptNormalizer.words("Hello, World! It’s U.S.-based — don't 'quote'."),
                       ["hello", "world", "it's", "us", "based", "don't", "quote"])
        XCTAssertEqual(TranscriptNormalizer.words("  Größe   ÉTÉ  "), ["größe", "été"])
        XCTAssertEqual(TranscriptNormalizer.words("…"), [])
        XCTAssertEqual(TranscriptNormalizer.characters("日本語 です。"), ["日", "本", "語", "で", "す"])
    }

    // MARK: WER

    func testWordErrorRateCountsEachKindOfError() {
        let deletion = WordErrorRate.counts(reference: "the cat sat on the mat", hypothesis: "The cat sat on mat.")
        XCTAssertEqual(deletion, ErrorCounts(substitutions: 0, deletions: 1, insertions: 0, referenceLength: 6, hypothesisLength: 5))
        XCTAssertEqual(try XCTUnwrap(deletion.rate), 1.0 / 6, accuracy: 1e-12)

        let mixed = WordErrorRate.counts(reference: "the cat sat on the mat", hypothesis: "the bat sat on the mat today")
        XCTAssertEqual(mixed.substitutions, 1)
        XCTAssertEqual(mixed.insertions, 1)
        XCTAssertEqual(mixed.deletions, 0)
        XCTAssertEqual(try XCTUnwrap(mixed.rate), 2.0 / 6, accuracy: 1e-12)

        XCTAssertEqual(WordErrorRate.counts(reference: "a b c", hypothesis: "a b c").errors, 0)
        // More hypothesis errors than reference words: WER above 1 is allowed.
        XCTAssertEqual(try XCTUnwrap(WordErrorRate.counts(reference: "yes", hypothesis: "no no no").rate), 3, accuracy: 1e-12)
    }

    func testEmptyReferencesHaveNoRateButStillCountInsertions() {
        let insertions = WordErrorRate.counts(reference: "", hypothesis: "um hello")
        XCTAssertEqual(insertions.insertions, 2)
        XCTAssertNil(insertions.rate)
        XCTAssertEqual(WordErrorRate.counts(reference: "", hypothesis: ""), ErrorCounts())
        XCTAssertNil(ErrorCounts().rate)
        let deletions = WordErrorRate.counts(reference: "a b c", hypothesis: " ")
        XCTAssertEqual(deletions.deletions, 3)
        XCTAssertEqual(deletions.rate, 1)
        // Pooled over recordings, an empty reference's insertions still count.
        let pooled = insertions + WordErrorRate.counts(reference: "a b c d", hypothesis: "a b c d")
        XCTAssertEqual(pooled.rate, 0.5)
    }

    func testCharacterErrorRateForLanguagesWithoutSpaces() {
        let counts = WordErrorRate.characterCounts(reference: "日本語です", hypothesis: "日本後です")
        XCTAssertEqual(counts.substitutions, 1)
        XCTAssertEqual(counts.rate, 0.2)
    }

    func testAlignmentPairsMatchingWords() {
        let steps = WordErrorRate.align(reference: ["a", "b", "c", "d"], hypothesis: ["a", "x", "c", "d", "e"])
        XCTAssertEqual(steps, [.match(0, 0), .substitution(1, 1), .match(2, 2), .match(3, 3), .insertion(4)])
        XCTAssertEqual(WordErrorRate.align(reference: [], hypothesis: ["a"]), [.insertion(0)])
        XCTAssertEqual(WordErrorRate.align(reference: ["a", "b"], hypothesis: []), [.deletion(0), .deletion(1)])
    }

    // MARK: cpWER

    func testConcatenatedPermutationWERFindsTheBestSpeakerMapping() {
        let reference = [SpeakerText(speaker: "A", text: "hello there"), SpeakerText(speaker: "B", text: "good morning"),
                         SpeakerText(speaker: "A", text: "how are you")]
        let swapped = ConcatenatedPermutationWER.score(reference: reference, hypothesis: [
            SpeakerText(speaker: "S2", text: "good morning"), SpeakerText(speaker: "S1", text: "hello there how are you")])
        XCTAssertEqual(swapped.counts.errors, 0)
        XCTAssertEqual(swapped.mapping, ["A": "S1", "B": "S2"])

        // The right words under the wrong speaker are errors, unlike plain WER.
        let misattributed = ConcatenatedPermutationWER.score(reference: [SpeakerText(speaker: "A", text: "hello there"),
                                                                         SpeakerText(speaker: "B", text: "good morning")],
                                                            hypothesis: [SpeakerText(speaker: "X", text: "hello"),
                                                                         SpeakerText(speaker: "Y", text: "there good morning")])
        XCTAssertEqual(misattributed.counts.deletions, 1)
        XCTAssertEqual(misattributed.counts.insertions, 1)
        XCTAssertEqual(misattributed.rate, 0.5)
        XCTAssertEqual(WordErrorRate.counts(reference: "hello there good morning", hypothesis: "hello there good morning").errors, 0)
    }

    func testCpWERCountsExtraAndMissingSpeakers() {
        let extra = ConcatenatedPermutationWER.score(reference: [SpeakerText(speaker: "A", text: "one two")],
                                                     hypothesis: [SpeakerText(speaker: "X", text: "one two"),
                                                                  SpeakerText(speaker: "Y", text: "three")])
        XCTAssertEqual(extra.counts.insertions, 1)
        XCTAssertEqual(extra.mapping, ["A": "X"])
        let missing = ConcatenatedPermutationWER.score(reference: [SpeakerText(speaker: "A", text: "one two"),
                                                                   SpeakerText(speaker: "B", text: "three four")],
                                                       hypothesis: [SpeakerText(speaker: "X", text: "three four")])
        XCTAssertEqual(missing.counts.deletions, 2)
        XCTAssertEqual(missing.rate, 0.5)
        XCTAssertNil(ConcatenatedPermutationWER.score(reference: [], hypothesis: []).rate)
    }

    // MARK: DER and JER

    private func spans(_ items: [(String, Double, Double)]) -> [SpeakerSpan] {
        items.map { SpeakerSpan(speaker: $0.0, start: $0.1, end: $0.2) }
    }

    func testPerfectDiarizationUnderAnyLabelsScoresZero() {
        let result = DiarizationErrorRate.score(reference: spans([("A", 0, 10), ("B", 10, 20)]),
                                                hypothesis: spans([("S7", 10, 20), ("S1", 0, 10)]))
        XCTAssertEqual(result.rate, 0)
        XCTAssertEqual(result.jaccardErrorRate, 0)
        XCTAssertEqual(result.mapping, ["A": "S1", "B": "S7"])
        XCTAssertEqual(result.referenceSeconds, 20)
    }

    func testDERSeparatesMissFalseAlarmAndConfusion() {
        let late = DiarizationErrorRate.score(reference: spans([("A", 0, 10), ("B", 10, 20)]),
                                              hypothesis: spans([("X", 0, 12), ("Y", 12, 20)]))
        XCTAssertEqual(late.confusionSeconds, 2, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(late.rate), 0.1, accuracy: 1e-9)

        let missed = DiarizationErrorRate.score(reference: spans([("A", 0, 10), ("B", 10, 20)]), hypothesis: spans([("X", 0, 10)]))
        XCTAssertEqual(missed.missedSeconds, 10, accuracy: 1e-9)
        XCTAssertEqual(missed.rate, 0.5)
        XCTAssertEqual(try XCTUnwrap(missed.jaccardErrorRate), 0.5, accuracy: 1e-9, "B is unmatched: (0 + 1) / 2")

        let falseAlarm = DiarizationErrorRate.score(reference: spans([("A", 0, 10), ("B", 10, 20)]),
                                                    hypothesis: spans([("X", 0, 10), ("Y", 10, 20), ("Z", 20, 25)]))
        XCTAssertEqual(falseAlarm.falseAlarmSeconds, 5, accuracy: 1e-9)
        XCTAssertEqual(falseAlarm.rate, 0.25)
        XCTAssertEqual(falseAlarm.hypothesisSpeakers, 3)
    }

    func testOverlappingSpeechCountsOncePerSpeakerAndCanBeExcluded() {
        // A speaks 0–10, B 5–15 (overlap 5–10); the system hears only A, 0–15.
        let reference = spans([("A", 0, 10), ("B", 5, 15)])
        let hypothesis = spans([("X", 0, 15)])
        let scored = DiarizationErrorRate.score(reference: reference, hypothesis: hypothesis)
        XCTAssertEqual(scored.referenceSeconds, 20, accuracy: 1e-9)
        XCTAssertEqual(scored.missedSeconds, 5, accuracy: 1e-9, "Overlap 5–10: two speakers, one heard")
        XCTAssertEqual(scored.confusionSeconds, 5, accuracy: 1e-9, "10–15: B labelled as A")
        XCTAssertEqual(try XCTUnwrap(scored.rate), 0.5, accuracy: 1e-9)

        let withoutOverlap = DiarizationErrorRate.score(reference: reference, hypothesis: hypothesis, ignoringOverlap: true)
        XCTAssertEqual(withoutOverlap.referenceSeconds, 10, accuracy: 1e-9)
        XCTAssertEqual(withoutOverlap.missedSeconds, 0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(withoutOverlap.rate), 0.5, accuracy: 1e-9)

        // A speaker's own overlapping or touching turns merge rather than counting twice.
        let duplicated = DiarizationErrorRate.score(reference: spans([("A", 0, 6), ("A", 4, 10)]), hypothesis: spans([("X", 0, 10)]))
        XCTAssertEqual(duplicated.referenceSeconds, 10, accuracy: 1e-9)
        XCTAssertEqual(duplicated.rate, 0)
    }

    func testCollarsExcludeTimeAroundReferenceBoundaries() {
        let reference = spans([("A", 0, 10), ("B", 10, 20)])
        let hypothesis = spans([("X", 0, 10.2), ("Y", 10.2, 20)])
        XCTAssertEqual(try XCTUnwrap(DiarizationErrorRate.score(reference: reference, hypothesis: hypothesis).rate), 0.01, accuracy: 1e-9)
        let collared = DiarizationErrorRate.score(reference: reference, hypothesis: hypothesis, collar: 0.25)
        XCTAssertEqual(collared.errorSeconds, 0, accuracy: 1e-9)
        XCTAssertEqual(collared.referenceSeconds, 19, accuracy: 1e-9, "0.25 s at each end and 0.5 s around the change")
    }

    func testEmptyReferenceHasNoDERButReportsFalseAlarm() {
        let result = DiarizationErrorRate.score(reference: [], hypothesis: spans([("X", 0, 5)]))
        XCTAssertNil(result.rate)
        XCTAssertNil(result.jaccardErrorRate)
        XCTAssertEqual(result.falseAlarmSeconds, 5)
        let nothing = DiarizationErrorRate.score(reference: [], hypothesis: [])
        XCTAssertNil(nothing.rate)
        XCTAssertEqual(nothing.errorSeconds, 0)
    }

    func testJaccardErrorRateAveragesOverReferenceSpeakers() {
        // One system speaker covering both: A pairs with it (10 of 20 s shared), B is unmatched.
        let merged = DiarizationErrorRate.score(reference: spans([("A", 0, 10), ("B", 10, 20)]), hypothesis: spans([("X", 0, 20)]))
        XCTAssertEqual(try XCTUnwrap(merged.jaccardErrorRate), 0.75, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(merged.rate), 0.5, accuracy: 1e-9)
    }

    // MARK: Word timing

    func testWordTimingErrorMeasuresOnlyMatchedWords() {
        let reference = [TimedWord(text: "Ship", start: 0, end: 0.4), TimedWord(text: "it", start: 0.5, end: 0.7),
                         TimedWord(text: "Friday.", start: 0.8, end: 1.2)]
        let hypothesis = [TimedWord(text: " ship", start: 0.1, end: 0.5), TimedWord(text: " um", start: 0.55, end: 0.6),
                          TimedWord(text: " it", start: 0.6, end: 0.75), TimedWord(text: " Friday", start: 1.3, end: 1.5)]
        let result = WordTimingError.measure(reference: reference, hypothesis: hypothesis)
        XCTAssertEqual(result.matchedWords, 3)
        XCTAssertEqual(result.referenceWords, 3)
        XCTAssertEqual(try XCTUnwrap(result.meanStartError), (0.1 + 0.1 + 0.5) / 3, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(result.medianStartError), 0.1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(result.withinTwoTenths), 2.0 / 3, accuracy: 1e-9)

        // Aligning in short windows gives the same answer on well-separated words.
        let windowed = WordTimingError.measure(reference: reference, hypothesis: hypothesis, window: 0.5)
        XCTAssertEqual(windowed.matchedWords, 3)
        XCTAssertEqual(try XCTUnwrap(windowed.meanStartError), try XCTUnwrap(result.meanStartError), accuracy: 1e-9)

        let none = WordTimingError.measure(reference: reference, hypothesis: [])
        XCTAssertEqual(none.matchedWords, 0)
        XCTAssertNil(none.meanStartError)
    }

    // MARK: Assignment and parsing

    func testHungarianFindsTheMinimumCostAssignment() {
        XCTAssertEqual(Hungarian.minimize([[4, 1, 3], [2, 0, 5], [3, 2, 2]]), [1, 0, 2])
        XCTAssertEqual(Hungarian.minimize([[-5, -1], [-4, -6]]), [0, 1])
        XCTAssertEqual(Hungarian.minimize([]), [])
    }

    func testReferenceFilesParse() {
        let stm = """
        ;; comment
        meeting 1 alex 0.00 2.50 <o,f0,male> Ship it Friday.
        meeting 1 sam 2.50 4.00 Sounds good
        meeting 1 inter_segment_gap 4.00 5.00
        """
        XCTAssertEqual(EvaluationReference.parseSTM(stm), [
            .init(speaker: "alex", start: 0, end: 2.5, text: "Ship it Friday."), .init(speaker: "sam", start: 2.5, end: 4, text: "Sounds good")])
        let rttm = """
        SPEAKER meeting 1 0.000 2.500 <NA> <NA> alex <NA> <NA>
        SPKR-INFO meeting 1 <NA> <NA> <NA> unknown alex <NA> <NA>
        SPEAKER meeting 1 2.500 1.500 <NA> <NA> sam <NA> <NA>
        """
        XCTAssertEqual(EvaluationReference.parseRTTM(rttm), spans([("alex", 0, 2.5), ("sam", 2.5, 4)]))
        XCTAssertEqual(EvaluationReference.parseRTTM(EvaluationReference.rttm(spans([("sam", 2.5, 4), ("alex", 0, 2.5)]), file: "m")),
                       spans([("alex", 0, 2.5), ("sam", 2.5, 4)]))
        XCTAssertEqual(EvaluationReference.parseCTM("meeting 1 0.10 0.30 Ship 0.9\nmeeting 1 0.50 0.20 it"),
                       [TimedWord(text: "Ship", start: 0.1, end: 0.4), TimedWord(text: "it", start: 0.5, end: 0.7)])
    }
}
