import DaybookCaptions
import DaybookIntelligence
import DaybookKit
import DaybookLive
import DaybookTestSupport
import XCTest
@testable import Daybook

/// Live transcription on the Mac from local models: the live roles a Mac starts with, and captions
/// read as turns by voice, named when live speakers recognized someone. No model runs here.
@MainActor
final class LiveTranscriptionTests: XCTestCase {
    func testANewMacChoosesTheCatalogsLiveModels() {
        let defaults = makeTestDefaults()
        let selections = AppState.loadModelSelections(defaults: defaults, speakerModel: nil)
        XCTAssertEqual(selections[.liveTranscription], "nemotron-3.5-asr-streaming/latin-1120ms")
        XCTAssertEqual(selections[.liveDiarization], "nemotron-3-diarization/live")
        XCTAssertEqual(selections[.speakerEmbedding], "community-1/offline")
        XCTAssertEqual(AppState.loadModelSelections(defaults: defaults, speakerModel: nil), selections, "stored as chosen")
    }

    func testAnExistingMacGainsLiveModelsOnceAndKeepsItsChoices() throws {
        let defaults = makeTestDefaults()
        var stored = ModelSelections([.transcription: "whisper/small", .speakerEmbedding: "community-1/offline"])
        stored[.smallTasks] = "apple-foundation-models/system"
        defaults.set(try JSONEncoder().encode(stored), forKey: "modelSelections")
        let loaded = AppState.loadModelSelections(defaults: defaults, speakerModel: nil)
        XCTAssertEqual(loaded[.transcription], "whisper/small")
        XCTAssertEqual(loaded[.liveTranscription], "nemotron-3.5-asr-streaming/latin-1120ms")
        // Someone who clears a live choice afterwards keeps it cleared.
        var cleared = loaded
        cleared[.liveDiarization] = nil
        defaults.set(try JSONEncoder().encode(cleared), forKey: "modelSelections")
        XCTAssertNil(AppState.loadModelSelections(defaults: defaults, speakerModel: nil)[.liveDiarization])
    }

    func testTheLiveRolesHaveTheirOwnSettingsAndStayOutOfCustom() {
        XCTAssertEqual(ModelRole.liveTranscription.title, "Live transcription")
        XCTAssertEqual(ModelRole.liveDiarization.title, "Live speakers")
        let choices = MacLiveModels.choices(selections: ModelSelections(), catalog: .builtIn,
                                            engines: ModelEngineRegistry.standard.descriptors)
        XCTAssertEqual(choices[.liveTranscription], "nemotron-3.5-asr-streaming/latin-1120ms")
        XCTAssertEqual(choices[.liveDiarization], "nemotron-3-diarization/live")
    }

    func testCaptionTurnsFollowVoicesAndUseNamesWhenKnown() {
        func line(_ text: String, _ source: LiveCaptionSource, _ slot: String?, _ name: String? = nil) -> LiveCaptionSegment {
            LiveCaptionSegment(start: 0, end: 1, text: text, isTentative: false, source: source,
                               speaker: slot.map { LiveCaptionSpeaker(slot: $0, name: name) })
        }
        let turns = LiveCaptionTurn.turns([
            line("Morning.", .microphone, nil),
            line("Can we start?", .microphone, nil),
            line("Sure.", .call, "S1", "Priya"),
            line("One thing first.", .call, "S1", "Priya"),
            line("Go ahead.", .call, "S2"),
        ])
        XCTAssertEqual(turns.map(\.label), ["You", "Priya", "Call"])
        XCTAssertEqual(turns.map(\.segments.count), [2, 2, 1])
    }
}
