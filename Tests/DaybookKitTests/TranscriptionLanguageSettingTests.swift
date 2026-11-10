import DaybookCore
import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookKit

/// xdev-settings-08: the transcription language is the library's, a synced setting both apps show and route by; the
/// model for other languages and the speaker settings stay each device's.
@MainActor
final class TranscriptionLanguageSettingTests: XCTestCase {
    private var root: URL!
    private let catalog = ModelCatalog.builtIn
    private let parakeet = "parakeet/ultra", turbo = "whisper/large-v3-turbo"

    override func setUp() async throws {
        root = makeTemporaryFolder("DaybookLanguage")
    }

    /// A library with its own sync identity, connected to the shared folder when given.
    private func library(_ name: String, cloud: URL? = nil) async throws -> LibraryController {
        let local = root.appendingPathComponent(name, isDirectory: true)
        let sync = LibrarySyncController(localRoot: local, defaults: makeTestDefaults("daybook.language.\(name)"))
        if let cloud { try sync.connect(to: cloud, monitorChanges: false) }
        let library = LibraryController(rootURL: local, sync: sync)
        try await library.load()
        return library
    }

    /// One sync pass that must run and be acknowledged, so a check after it isn't vacuous.
    private func pass(_ library: LibraryController, file: StaticString = #filePath, line: UInt = #line) async {
        await library.flush()
        let applied = await library.synchronize()
        XCTAssertEqual(applied?.acknowledged, true, "the sync pass ran and was acknowledged", file: file, line: line)
    }

    func testTheLanguageSavesAsALibrarySettingAndReadsNormalized() async throws {
        let library = try await library("Mac")
        XCTAssertNil(library.transcriptionLanguage, "Automatic")
        XCTAssertNil(library.metadata.choice(.transcriptionLanguage), "no device has chosen one")

        library.setTranscriptionLanguage("pt-BR")
        XCTAssertEqual(library.transcriptionLanguage, "pt")
        let stamped = try XCTUnwrap(library.metadata.choice(.transcriptionLanguage))
        library.setTranscriptionLanguage("pt")
        XCTAssertEqual(library.metadata.choice(.transcriptionLanguage), stamped, "the same choice writes nothing new to sync")
        await library.flush()

        // It's in library.json, so it survives reopening.
        let reopened = LibraryController(rootURL: library.rootURL, sync: nil)
        try await reopened.load()
        XCTAssertEqual(reopened.transcriptionLanguage, "pt")

        library.setTranscriptionLanguage(nil)
        XCTAssertNil(library.transcriptionLanguage)
        XCTAssertNotNil(library.metadata.choice(.transcriptionLanguage), "Automatic is a choice too")
        XCTAssertGreaterThan(try XCTUnwrap(library.metadata.choice(.transcriptionLanguage)).modifiedAt, stamped.modifiedAt)
    }

    /// The carry-over a Mac makes at launch: its stored language is written only while the library has none.
    func testACarriedOverLanguageIsWrittenOnlyWhileTheLibraryHasNone() async throws {
        let library = try await library("Mac")
        XCTAssertFalse(library.adoptTranscriptionLanguage(nil), "Automatic carries nothing over")
        XCTAssertNil(library.metadata.choice(.transcriptionLanguage))
        XCTAssertTrue(library.adoptTranscriptionLanguage("de-DE"))
        XCTAssertEqual(library.transcriptionLanguage, "de")
        XCTAssertFalse(library.adoptTranscriptionLanguage("fr"), "the library has one")
        XCTAssertEqual(library.transcriptionLanguage, "de")
        library.setTranscriptionLanguage(nil)
        XCTAssertFalse(library.adoptTranscriptionLanguage("fr"), "Automatic, once chosen, is the library's too")
        XCTAssertNil(library.transcriptionLanguage)
    }

    func testAChangeOnOneDeviceReachesTheOtherAndTheLaterChangeWins() async throws {
        let cloud = root.appendingPathComponent("Cloud", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let mac = try await library("Mac", cloud: cloud), phone = try await library("Phone", cloud: cloud)
        await pass(mac); await pass(phone)

        phone.setTranscriptionLanguage("de")
        await pass(phone); await pass(mac)
        XCTAssertEqual(mac.transcriptionLanguage, "de", "chosen on the phone")

        mac.setTranscriptionLanguage(nil)
        await pass(mac); await pass(phone)
        XCTAssertNil(phone.transcriptionLanguage, "Automatic, chosen later on the Mac")
        XCTAssertNotNil(phone.metadata.choice(.transcriptionLanguage))
    }

    // MARK: Routing on either app

    /// Parakeet and the system's speech model on both; WhisperKit only on a Mac.
    private func engines(whisper: Bool) -> [ModelEngineDescriptor] {
        [.init(id: .parakeet, name: "Parakeet", version: 1, runtime: "FluidAudio 0.18.0", roles: [.transcription], platforms: [.macOS, .iOS])]
            + (whisper ? [.init(id: .whisperKit, name: "WhisperKit", version: 2, runtime: "argmax-oss-swift 1.1.1", roles: [.transcription],
                                platforms: [.macOS])] : [])
    }

    private func route(_ library: LibraryController, engines: [ModelEngineDescriptor], other: String? = nil) -> TranscriptionRoute {
        TranscriptionRouting.route(selected: parakeet, language: library.transcriptionLanguage, otherLanguagesChoice: other,
                                   catalog: catalog, engines: engines, installed: [], appVersion: nil)
    }

    func testRoutingOnEitherAppReadsTheLibrarysLanguage() async throws {
        let library = try await library("Mac")
        let mac = engines(whisper: true), phone = engines(whisper: false)

        // Automatic: a language check where a model for other languages runs; an iPhone has none.
        XCTAssertEqual(route(library, engines: mac), TranscriptionRoute(model: parakeet, fallback: turbo))
        XCTAssertEqual(route(library, engines: phone), TranscriptionRoute(model: parakeet))

        // German, which Parakeet covers: Parakeet with the language as a hint, on both.
        library.setTranscriptionLanguage("de")
        XCTAssertEqual(route(library, engines: mac), TranscriptionRoute(model: parakeet, language: "de"))
        XCTAssertEqual(route(library, engines: phone), TranscriptionRoute(model: parakeet, language: "de"))

        // Japanese, which it doesn't: a Mac's model for other languages (its own choice where that serves); an iPhone
        // has none, so Parakeet gets the hint.
        library.setTranscriptionLanguage("ja")
        XCTAssertEqual(route(library, engines: mac), TranscriptionRoute(model: turbo, language: "ja"))
        XCTAssertEqual(route(library, engines: mac, other: "whisper/small"), TranscriptionRoute(model: "whisper/small", language: "ja"))
        XCTAssertEqual(route(library, engines: phone), TranscriptionRoute(model: parakeet, language: "ja"))
    }

    /// What a job freezes: the language as it was routed, so a later change of the library's language changes the next
    /// job and never one already queued.
    func testAJobsPreferencesKeepTheLanguageItWasQueuedWith() async throws {
        let library = try await library("Mac")
        library.setTranscriptionLanguage("de")
        var frozen = ProcessingPreferences()
        frozen.transcriptionLanguage = route(library, engines: engines(whisper: true)).language
        library.setTranscriptionLanguage("fr")
        XCTAssertEqual(frozen.transcriptionLanguage, "de")
        XCTAssertEqual(route(library, engines: engines(whisper: true)).language, "fr", "the next job's")

        // The value type both apps share: Automatic encodes nothing, so earlier preferences and fingerprints stay as they were.
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(ProcessingPreferences()), as: UTF8.self).contains("transcriptionLanguage"))
        XCTAssertEqual(try JSONDecoder().decode(ProcessingPreferences.self, from: JSONEncoder().encode(frozen)), frozen)
        XCTAssertEqual(ProcessingPreferences(transcriptionLanguage: "pt-BR").transcriptionLanguage, "pt")
    }
}
