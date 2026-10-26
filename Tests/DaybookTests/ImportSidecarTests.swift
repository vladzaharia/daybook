import AVFoundation
import DaybookCore
import DaybookTestSupport
import Foundation
import XCTest
@testable import Daybook

/// A recording's highlights sidecar ("call.highlights.json") travels with it when it can be read, and never stops the
/// recording from importing when it can't: in the App Sandbox, only the files the person chose are readable.
@MainActor
final class ImportSidecarTests: XCTestCase {
    func testAnUnreadableSidecarBesideTheRecordingDoesNotStopTheImport() async throws {
        let (state, root) = try await makeState()
        let audio = try writeAudio(root.appendingPathComponent("Incoming/call.wav"))
        let sidecar = try writeSidecar(beside: audio)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sidecar.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sidecar.path) }

        try await state.importFiles([audio], source: .imported, attachTo: nil)
        await state.flush()

        let meeting = try XCTUnwrap(state.meetings.first)
        XCTAssertEqual(meeting.tracks.count, 1)
        XCTAssertTrue(meeting.highlights.isEmpty)
        XCTAssertTrue(state.notice?.contains("without its bookmarks") == true, state.notice ?? "no notice")
        XCTAssertTrue(state.notice?.contains("call.highlights.json") == true, state.notice ?? "no notice")
    }

    func testASidecarChosenWithItsRecordingBringsItsBookmarks() async throws {
        let (state, root) = try await makeState()
        let audio = try writeAudio(root.appendingPathComponent("Incoming/standup.wav"))
        let sidecar = try writeSidecar(beside: audio)

        // The open panel and drops hand over both files; the sidecar isn't a recording of its own.
        try await state.importFiles([sidecar, audio], source: .imported, attachTo: nil)
        await state.flush()

        XCTAssertEqual(state.meetings.count, 1)
        let meeting = try XCTUnwrap(state.meetings.first)
        XCTAssertEqual(meeting.tracks.count, 1)
        XCTAssertEqual(meeting.highlights.map(\.text), ["Decision"])
        XCTAssertNil(state.errorMessage)
    }

    func testSidecarsPairWithTheirRecordingsByName() {
        let folder = URL(fileURLWithPath: "/Users/dana/Exports", isDirectory: true)
        let call = folder.appendingPathComponent("call.m4a"), callSidecar = folder.appendingPathComponent("call.highlights.json")
        let other = folder.appendingPathComponent("notes.json"), memo = folder.appendingPathComponent("memo.wav")
        let (audio, sidecars) = AppState.separatingSidecars([callSidecar, call, other, memo])
        XCTAssertEqual(audio, [call, memo])
        XCTAssertEqual(sidecars, ["/Users/dana/Exports/call": callSidecar])
        XCTAssertNil(AppState.sidecarRecordingPath(folder.appendingPathComponent(".highlights.json")))
    }

    func testADropImportsRecordingsWithTheirSidecarsButNotASidecarAlone() {
        let folder = URL(fileURLWithPath: "/Users/dana/Exports", isDirectory: true)
        let call = folder.appendingPathComponent("call.m4a"), sidecar = folder.appendingPathComponent("call.highlights.json")
        let text = folder.appendingPathComponent("agenda.txt")
        XCTAssertEqual(AppState.droppedRecordings([call, sidecar, text]), [call, sidecar])
        XCTAssertEqual(AppState.droppedRecordings([sidecar, text]), [])
    }

    // MARK: Helpers

    private func makeState() async throws -> (AppState, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookSidecarTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let state = AppState(libraryURL: root.appendingPathComponent("Library", isDirectory: true), defaults: makeTestDefaults())
        await state.initialize()
        XCTAssertTrue(state.isReady)
        return (state, root)
    }

    private func writeAudio(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000)!
        buffer.frameLength = 8_000
        for index in 0..<8_000 { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 330 * 2 * .pi / 16_000) * 0.2) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    private func writeSidecar(beside audio: URL) throws -> URL {
        let url = audio.deletingPathExtension().appendingPathExtension("highlights.json")
        try Data(#"{"schemaVersion":1,"highlights":[{"time":0.2,"text":"Decision"}]}"#.utf8).write(to: url)
        return url
    }
}
