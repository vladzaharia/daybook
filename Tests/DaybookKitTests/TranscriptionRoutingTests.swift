import DaybookCore
import Foundation
import XCTest
@testable import DaybookKit

/// Language routing and speaker routing decisions, from capabilities in the built-in catalog.
final class TranscriptionRoutingTests: XCTestCase {
    private let catalog = ModelCatalog.builtIn
    private let parakeet = "parakeet/ultra", turbo = "whisper/large-v3-turbo"

    func testLanguageCodesNormalizeAndCoverage() {
        XCTAssertEqual(TranscriptionLanguages.normalize("en-US"), "en")
        XCTAssertEqual(TranscriptionLanguages.normalize("pt_BR"), "pt")
        XCTAssertEqual(TranscriptionLanguages.normalize("zh-Hant"), "zh")
        XCTAssertEqual(TranscriptionLanguages.normalize("jw"), "jv")
        XCTAssertNil(TranscriptionLanguages.normalize(" "))
        XCTAssertNil(TranscriptionLanguages.normalize(nil))
        XCTAssertTrue(TranscriptionLanguages.covers(nil, "ja"), "No declared languages means any")
        XCTAssertTrue(TranscriptionLanguages.covers(["*"], "ja"))
        XCTAssertTrue(TranscriptionLanguages.covers(["en", "de"], "de-AT"))
        XCTAssertFalse(TranscriptionLanguages.covers(["en", "de"], "ja"))
        XCTAssertFalse(TranscriptionLanguages.covers(["en"], nil))
        XCTAssertEqual(TranscriptionLanguages.whisper.count, 100)
    }

    func testAChosenLanguageRoutesToAModelThatCoversIt() {
        XCTAssertEqual(TranscriptionRouting.route(selected: parakeet, language: "de-DE", otherLanguages: turbo, catalog: catalog),
                       TranscriptionRoute(model: parakeet, language: "de"))
        XCTAssertEqual(TranscriptionRouting.route(selected: parakeet, language: "ja", otherLanguages: turbo, catalog: catalog),
                       TranscriptionRoute(model: turbo, language: "ja"), "Japanese goes to the model that covers it")
        XCTAssertEqual(TranscriptionRouting.route(selected: turbo, language: "ja", otherLanguages: nil, catalog: catalog),
                       TranscriptionRoute(model: turbo, language: "ja"))
        XCTAssertEqual(TranscriptionRouting.route(selected: parakeet, language: "ja", otherLanguages: nil, catalog: catalog),
                       TranscriptionRoute(model: parakeet, language: "ja"), "Nothing covers it: the selected model tries")
    }

    func testAutomaticChecksTheLanguageOnlyWhenTheModelCoversSome() {
        XCTAssertEqual(TranscriptionRouting.route(selected: parakeet, language: nil, otherLanguages: turbo, catalog: catalog),
                       TranscriptionRoute(model: parakeet, fallback: turbo))
        XCTAssertEqual(TranscriptionRouting.route(selected: turbo, language: nil, otherLanguages: parakeet, catalog: catalog),
                       TranscriptionRoute(model: turbo), "Whisper covers every language")
        XCTAssertEqual(TranscriptionRouting.route(selected: parakeet, language: nil, otherLanguages: "parakeet/redux", catalog: catalog),
                       TranscriptionRoute(model: parakeet), "Redux covers the same languages, so it can't help")
        XCTAssertEqual(TranscriptionRouting.route(selected: parakeet, language: nil, otherLanguages: nil, catalog: catalog),
                       TranscriptionRoute(model: parakeet))
    }

    func testTheOtherLanguagesModelIsTheChoiceThenAnInstalledOneThenThePresetsBest() {
        XCTAssertNil(TranscriptionRouting.otherLanguagesModel(selected: turbo, chosen: nil, catalog: catalog), "Not needed")
        XCTAssertEqual(TranscriptionRouting.otherLanguagesModel(selected: parakeet, chosen: nil, catalog: catalog), turbo,
                       "Detailed's best model that covers every language")
        XCTAssertEqual(TranscriptionRouting.otherLanguagesModel(selected: parakeet, chosen: nil, catalog: catalog, installed: ["whisper/small"]),
                       "whisper/small", "An installed one before a download")
        XCTAssertEqual(TranscriptionRouting.otherLanguagesModel(selected: parakeet, chosen: "whisper/base", catalog: catalog,
                                                                installed: ["whisper/small"]), "whisper/base")
        XCTAssertEqual(TranscriptionRouting.otherLanguagesModel(selected: parakeet, chosen: "parakeet/redux", catalog: catalog), turbo,
                       "A choice that covers nothing new is passed over")
        let noWhisper: [ModelEngineDescriptor] = [.init(id: .parakeet, name: "Parakeet", version: 1, runtime: "FluidAudio 0.17.7",
                                                          roles: [.transcription], platforms: [.macOS])]
        XCTAssertNil(TranscriptionRouting.otherLanguagesModel(selected: parakeet, chosen: nil, catalog: catalog, engines: noWhisper, appVersion: nil),
                     "A build that can't run Whisper has no model for other languages")
    }

    func testLanguageChoicesCoverEveryTranscriptionModel() {
        let all = TranscriptionLanguages.choices(in: catalog)
        XCTAssertTrue(all.contains("ja"))
        XCTAssertTrue(all.contains("mt"))
        XCTAssertEqual(Set(all).count, all.count)
        let parakeetOnly: [ModelEngineDescriptor] = [.init(id: .parakeet, name: "Parakeet", version: 1, runtime: "FluidAudio 0.17.7",
                                                           roles: [.transcription], platforms: [.macOS])]
        let european = TranscriptionLanguages.choices(in: catalog, engines: parakeetOnly, appVersion: nil)
        XCTAssertEqual(Set(european), Set(catalog.model(parakeet)?.capabilities.languages ?? []))
        XCTAssertEqual(TranscriptionLanguages.name("de", locale: Locale(identifier: "en_US")), "German")
    }

    // MARK: Checking Automatic transcripts

    private let english = "We agreed to ship the prototype on Friday and review the results next Monday."

    func testLanguageCheckKeepsCoveredConfidentTranscripts() {
        let supported = catalog.model(parakeet)?.capabilities.languages
        XCTAssertEqual(LanguageCheck.verdict(text: english, guesses: [.init(language: "en", probability: 0.97)], meanConfidence: 0.9,
                                             supported: supported), .keep(language: "en"))
        XCTAssertEqual(LanguageCheck.verdict(text: "Thank you.", guesses: [.init(language: "en", probability: 0.4)], meanConfidence: 0.2,
                                             supported: supported), .keep(language: nil), "Too little to tell")
        XCTAssertEqual(LanguageCheck.verdict(text: english, guesses: [], meanConfidence: 0.9, supported: ["*"]), .keep(language: nil))
    }

    func testLanguageCheckSendsOtherOrUnclearTranscriptsToTheOtherModel() {
        let supported = catalog.model(parakeet)?.capabilities.languages
        XCTAssertEqual(LanguageCheck.verdict(text: "Bu toplantıda prototipi cuma günü göndermeye karar verdik.",
                                             guesses: [.init(language: "tr", probability: 0.92)], meanConfidence: 0.8, supported: supported),
                       .outside(language: "tr"))
        XCTAssertEqual(LanguageCheck.verdict(text: english, guesses: [.init(language: "en", probability: 0.9)], meanConfidence: 0.3,
                                             supported: supported), .uncertain, "Words in a covered language but heard with little confidence")
        XCTAssertEqual(LanguageCheck.verdict(text: english, guesses: [.init(language: "en", probability: 0.45), .init(language: "nl", probability: 0.4)],
                                             meanConfidence: 0.9, supported: supported), .uncertain)
        XCTAssertEqual(LanguageCheck.verdict(text: "私たちは金曜日に試作品を出荷することに決めました", guesses: [.init(language: "ja", probability: 0.99)],
                                             meanConfidence: 0.9, supported: ["en", "de"]), .outside(language: "ja"),
                       "Text without spaces is judged by its length")
    }

    func testTheOtherModelsHearingDecidesWhichTranscriptIsKept() {
        let supported = catalog.model(parakeet)?.capabilities.languages
        XCTAssertTrue(LanguageCheck.usesFallback(after: .uncertain, fallbackLanguage: "ja", supported: supported))
        XCTAssertFalse(LanguageCheck.usesFallback(after: .uncertain, fallbackLanguage: "en", supported: supported),
                       "Noisy English: the first, more accurate model's transcript stays")
        XCTAssertFalse(LanguageCheck.usesFallback(after: .outside(language: "tr"), fallbackLanguage: "de", supported: supported))
        XCTAssertTrue(LanguageCheck.usesFallback(after: .outside(language: "tr"), fallbackLanguage: nil, supported: supported))
        XCTAssertFalse(LanguageCheck.usesFallback(after: .uncertain, fallbackLanguage: nil, supported: supported))
        XCTAssertTrue(LanguageCheck.likelyUnsupported(guesses: [.init(language: "id", probability: 0.26)], meanConfidence: 0.36))
        XCTAssertFalse(LanguageCheck.likelyUnsupported(guesses: [.init(language: "en", probability: 0.99)], meanConfidence: 0.36))
        XCTAssertFalse(LanguageCheck.likelyUnsupported(guesses: [.init(language: "id", probability: 0.26)], meanConfidence: 0.9))
    }

    func testTheDetectorNamesCommonLanguages() {
        XCTAssertEqual(TranscriptLanguageDetector.guesses(english).first?.language, "en")
        XCTAssertEqual(TranscriptLanguageDetector.guesses("Wir haben beschlossen, den Prototyp am Freitag auszuliefern und die Ergebnisse am Montag zu prüfen.").first?.language, "de")
        XCTAssertEqual(TranscriptLanguageDetector.guesses("私たちは金曜日に試作品を出荷することに決めました。").first?.language, "ja")
        XCTAssertTrue(TranscriptLanguageDetector.guesses("").isEmpty)
        let long = String(repeating: english + " ", count: 200)
        XCTAssertLessThanOrEqual(TranscriptLanguageDetector.sample(long).count, 6_100)
        XCTAssertEqual(TranscriptLanguageDetector.guesses(long).first?.language, "en")
    }

    // MARK: Speakers

    func testMoreSpeakersThanTheModelTellsApartGoToAnInstalledModelWithoutTheLimit() {
        let nemotron = "nemotron-3-diarization/offline", community = "community-1/offline"
        XCTAssertEqual(ModelRouting.diarizer(selected: nemotron, expectedSpeakers: 10, catalog: catalog, installed: [nemotron, community]), community)
        XCTAssertEqual(ModelRouting.diarizer(selected: nemotron, expectedSpeakers: 10, catalog: catalog, installed: [nemotron]), nemotron,
                       "Nothing installed can: the selected model runs")
        XCTAssertEqual(ModelRouting.diarizer(selected: nemotron, expectedSpeakers: 8, catalog: catalog, installed: [nemotron, community]), nemotron)
        XCTAssertEqual(ModelRouting.diarizer(selected: nemotron, expectedSpeakers: nil, catalog: catalog, installed: [community]), nemotron)
        XCTAssertEqual(ModelRouting.diarizer(selected: community, expectedSpeakers: 20, catalog: catalog, installed: [community]), community)
        XCTAssertEqual(ModelRouting.diarizer(selected: "sortformer-2.1/fp16", expectedSpeakers: 6, catalog: catalog,
                                             installed: ["sortformer-2.1/fp16", nemotron, community]), community,
                       "A model that takes the expected count is preferred")
    }

    func testVoiceProfilesForNemotronComeFromCommunity1EvenForOlderSelections() {
        let older = ModelSelections([.transcription: parakeet, .diarization: "nemotron-3-diarization/offline"])
        let filled = ModelRouting.withDefaultVoiceEmbedder(older, catalog: catalog)
        XCTAssertEqual(filled[.speakerEmbedding], "community-1/offline")
        XCTAssertEqual(ModelRouting.voiceEmbedder(diarizer: "nemotron-3-diarization/offline", selections: filled, catalog: catalog,
                                                  engines: [.init(id: .community1, name: "Community-1", version: 1, runtime: "FluidAudio 0.17.7",
                                                                  roles: [.diarization, .speakerEmbedding], platforms: [.macOS])],
                                                  appVersion: nil), "community-1/offline")
        XCTAssertNil(ModelRouting.voiceEmbedder(diarizer: "community-1/offline", selections: filled, catalog: catalog,
                                                engines: [], appVersion: nil), "Community-1 makes its own")
        let chosen = ModelSelections([.speakerEmbedding: "someone/else"])
        XCTAssertEqual(ModelRouting.withDefaultVoiceEmbedder(chosen, catalog: catalog), chosen, "A stored choice stays")
    }
}
