import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookCore

/// A recording's speech level and the one gain that raises quiet speech before the speech models hear it
/// (`SpeechLevel`, docs/architecture.md "Input levels"). Synthetic speech-like sound at known levels only.
final class SpeechLevelTests: XCTestCase {
    private func measured(_ samples: [Float], rate: Double = 16_000) -> SpeechLevel.Measurement {
        var meter = SpeechLevel.Meter(sampleRate: rate)
        meter.add(samples)
        return meter.measurement()
    }

    private func decibels(_ value: Float) -> Double { 20 * log10(Double(value)) }

    // MARK: Measuring

    func testBehaviorQuietNormalAndLoudSpeechMeasureAtTheirOwnLevel() throws {
        for level in [-55.0, -30, -12] {
            let speech = SyntheticAudio.syllables(level: level, seconds: 10, floor: -85)
            let result = measured(speech)
            XCTAssertEqual(try XCTUnwrap(result.speech), level, accuracy: 0.3, "speech at \(level) dBFS")
            XCTAssertEqual(try XCTUnwrap(result.peak), decibels(speech.map(abs).max()!), accuracy: 1e-9)
        }
        // At the recording's own rate, 48 kHz as the Mac captures.
        XCTAssertEqual(try XCTUnwrap(measured(SyntheticAudio.syllables(level: -40, seconds: 5, rate: 48_000), rate: 48_000).speech),
                       -40, accuracy: 0.3)
    }

    func testBehaviorPausesBetweenWordsDontLowerTheLevel() throws {
        // Speech a third of the time, the rest a room's noise loud enough to count as sound.
        let speech = SyntheticAudio.syllables(level: -45, seconds: 30, pause: 3, floor: -62)
        XCTAssertEqual(try XCTUnwrap(measured(speech).speech), -45, accuracy: 0.3)
        XCTAssertLessThan(decibels(SyntheticAudio.rms(speech)), -49, "a whole-file mean would read it 4 dB and more quieter")
    }

    func testBehaviorSilenceHasNoSpeechLevel() {
        let digital = measured([Float](repeating: 0, count: 160_000))
        XCTAssertNil(digital.speech)
        XCTAssertNil(digital.peak)
        XCTAssertNil(measured(SyntheticAudio.syllables(level: -90, seconds: 10, floor: -95)).speech, "dither and a muted line aren't speech")
        XCTAssertNil(measured(SyntheticAudio.syllables(level: -30, seconds: 0.3)).speech, "a third of a second isn't enough to measure")
        let none = SpeechLevel.adjustment(for: digital)
        XCTAssertEqual(none, LevelAdjustment(speechLevel: nil, peak: nil, gain: 0))
        XCTAssertNil(measured([]).speech)
    }

    func testBehaviorASingleLoudClickDoesNotRaiseTheLevelButBoundsTheGain() throws {
        var speech = SyntheticAudio.syllables(level: -50, seconds: 10, floor: -85)
        speech[18_400] = Float(pow(10, -4.05 / 20))   // 1.15 s: in the gap between the third and fourth syllables
        let result = measured(speech)
        XCTAssertEqual(try XCTUnwrap(result.speech), -50, accuracy: 0.3, "one click among the syllables isn't the speech")
        XCTAssertEqual(try XCTUnwrap(result.peak), -4.05, accuracy: 0.01)
        let adjustment = SpeechLevel.adjustment(for: result)
        XCTAssertEqual(adjustment.gain, 3.0, accuracy: 1e-9, "27 dB would bring the speech to the target, the click allows 3")
        XCTAssertLessThanOrEqual(try XCTUnwrap(result.peak) + adjustment.gain, -1)
    }

    func testBehaviorTheLevelIsTheSameHoweverTheRecordingIsSplitOrWhicheverChannelsHoldIt() {
        let speech = SyntheticAudio.syllables(level: -38, seconds: 8, floor: -60, seed: 4)
        let whole = measured(speech)
        for size in [1_000, 1_600, 7_919] {
            var meter = SpeechLevel.Meter(sampleRate: 16_000)
            for start in stride(from: 0, to: speech.count, by: size) { meter.add(Array(speech[start..<min(speech.count, start + size)])) }
            XCTAssertEqual(meter.measurement(), whole, "blocks of \(size)")
        }
        var stereo = SpeechLevel.Meter(sampleRate: 16_000)
        stereo.add([speech, speech])
        XCTAssertEqual(stereo.measurement(), whole, "the same speech in both channels")
        var louder = SpeechLevel.Meter(sampleRate: 16_000)
        louder.add([speech, speech.map { $0 * 3 }])
        XCTAssertEqual(try XCTUnwrap(louder.measurement().peak), try XCTUnwrap(whole.peak) + decibels(3), accuracy: 1e-6,
                       "the peak is the loudest channel's")
        XCTAssertEqual(measured(speech), whole, "measured again, the same")
    }

    // MARK: Reading a file

    func testBehaviorAFileMeasuresAsItsSamplesDoOffTheCallersActor() async throws {
        let speech = SyntheticAudio.syllables(level: -44, seconds: 6, floor: -80)
        let url = makeTemporaryFolder().appendingPathComponent("speech.caf")
        try SyntheticAudio.write(speech, to: url)
        let expected = measured(speech)
        XCTAssertEqual(try SpeechLevel.measure(contentsOf: url), expected)
        let fromMain = try await Task { @MainActor in try await SpeechLevel.measure(url: url) }.value
        XCTAssertEqual(fromMain, expected, "a view can ask without reading on the main actor")
    }

    func testBehaviorMeasuringAFileStopsWhenItsTaskIsCancelled() async throws {
        let url = makeTemporaryFolder().appendingPathComponent("speech.caf")
        try SyntheticAudio.write(SyntheticAudio.syllables(level: -44, seconds: 6), to: url)
        for waits in [false, true] {
            let task = Task.detached { () async throws -> SpeechLevel.Measurement in
                while !Task.isCancelled { await Task.yield() }
                return waits ? try await SpeechLevel.measure(url: url) : try SpeechLevel.measure(contentsOf: url)
            }
            task.cancel()
            do {
                _ = try await task.value
                XCTFail("measured after being cancelled (\(waits ? "async" : "sync"))")
            } catch is CancellationError {}
        }
    }

    // MARK: Choosing the gain

    private func gain(speech: Double?, peak: Double?) -> Double {
        SpeechLevel.adjustment(for: SpeechLevel.Measurement(speech: speech, peak: peak)).gain
    }

    func testBehaviorQuietSpeechIsRaisedToTheTargetCappedAndUnderTheCeiling() {
        XCTAssertEqual(gain(speech: -45, peak: -25), 22, accuracy: 1e-9, "to −23 dBFS")
        XCTAssertEqual(gain(speech: -65, peak: -40), 30, accuracy: 1e-9, "never more than 30 dB")
        XCTAssertEqual(gain(speech: -45, peak: -8), 7, accuracy: 1e-9, "the peak stays at −1 dBFS")
        XCTAssertEqual(gain(speech: -40.04, peak: -20), 17, accuracy: 1e-9, "in 0.1 dB steps, rounded down")
        XCTAssertEqual(gain(speech: -45, peak: -1.95), 0, "the peak allows 0.9 dB, under 1 dB: none")
        let adjustment = SpeechLevel.adjustment(for: SpeechLevel.Measurement(speech: -44.96, peak: -25.04))
        XCTAssertEqual(adjustment, LevelAdjustment(version: 1, speechLevel: -45, peak: -25, gain: 21.9))
        XCTAssertEqual(LevelAdjustment(speechLevel: -43, peak: -30, gain: 20).factor, 10, accuracy: 1e-5)
    }

    func testBehaviorSpeechNearOrAboveNormalIsLeftAloneAndNothingIsEverLowered() {
        XCTAssertEqual(gain(speech: -35, peak: -15), 0, "12 dB under the target is still normal")
        XCTAssertEqual(gain(speech: -34.9, peak: -15), 0)
        XCTAssertEqual(gain(speech: -20, peak: -3), 0)
        XCTAssertEqual(gain(speech: -5, peak: -0.1), 0, "loud speech isn't lowered")
        XCTAssertEqual(gain(speech: -45, peak: 0), 0, "a peak over the ceiling doesn't lower it either")
        XCTAssertEqual(gain(speech: nil, peak: -20), 0)
        XCTAssertEqual(gain(speech: -35.1, peak: -15), 12.1, accuracy: 1e-9, "just under the line, raised all the way")
    }

    // MARK: Provenance

    /// `ProcessingSettings` as the version before levels read and wrote it: its own keys, and every other key kept as it came.
    private struct SettingsBeforeLevels: Codable {
        var modelID: String
        var parameters: [String: String]
        var createdAt: Date
        var model: ModelProvenance?
        var unknownFields = UnknownFields()
        private enum CodingKeys: String, CodingKey, CaseIterable { case modelID, parameters, createdAt, model }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            modelID = try values.decode(String.self, forKey: .modelID)
            parameters = try values.decode([String: String].self, forKey: .parameters)
            createdAt = try values.decode(Date.self, forKey: .createdAt)
            model = (try? values.decodeIfPresent(ModelProvenance.self, forKey: .model)) ?? nil
            unknownFields = try UnknownFields(from: decoder, known: Set(CodingKeys.allCases.map(\.rawValue)))
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(modelID, forKey: .modelID)
            try values.encode(parameters, forKey: .parameters)
            try values.encode(createdAt, forKey: .createdAt)
            try values.encodeIfPresent(model, forKey: .model)
            try unknownFields.encode(to: encoder)
        }
    }

    func testBehaviorTheGainRoundTripsWithTheRunAndAnOlderReaderKeepsIt() throws {
        let adjustment = LevelAdjustment(speechLevel: -51.2, peak: -20.4, gain: 28.2)
        let settings = ProcessingSettings(modelID: "parakeet/ultra", parameters: ["mode": "newAudio"],
                                          createdAt: Date(timeIntervalSince1970: 1_800_000_000), levelAdjustment: adjustment)
        let data = try JSONEncoder().encode(settings)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let written = try XCTUnwrap(json["levelAdjustment"] as? [String: Any])
        XCTAssertEqual(written["gain"] as? Double, 28.2)
        XCTAssertEqual(written["version"] as? Int, 1)
        XCTAssertEqual(try JSONDecoder().decode(ProcessingSettings.self, from: data), settings)

        // The version before reads it as a key it doesn't know, writes it back after an edit, and this one reads it again.
        var older = try JSONDecoder().decode(SettingsBeforeLevels.self, from: data)
        XCTAssertNotNil(older.unknownFields["levelAdjustment"])
        older.parameters["mode"] = "speakerRefresh"
        let rewritten = try JSONDecoder().decode(ProcessingSettings.self, from: JSONEncoder().encode(older))
        XCTAssertEqual(rewritten.levelAdjustment, adjustment)
        XCTAssertEqual(rewritten.parameters["mode"], "speakerRefresh")
        XCTAssertTrue(rewritten.unknownFields.isEmpty)

        // A run without one writes nothing new; one a newer version wrote differently is dropped, never a reason to fail.
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ProcessingSettings(modelID: "whisper/base"))) as? [String: Any])
        XCTAssertNil(plain["levelAdjustment"])
        var damaged = json
        damaged["levelAdjustment"] = "loud"
        let tolerant = try JSONDecoder().decode(ProcessingSettings.self, from: JSONSerialization.data(withJSONObject: damaged))
        XCTAssertNil(tolerant.levelAdjustment)
        XCTAssertEqual(tolerant.modelID, "parakeet/ultra")
    }
}
