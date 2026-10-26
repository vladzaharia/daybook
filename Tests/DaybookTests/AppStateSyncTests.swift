import AVFoundation
import DaybookCore
import DaybookTestSupport
import Foundation
import XCTest
@testable import Daybook

@MainActor
final class AppStateSyncTests: XCTestCase {
    func testTwoMacLibrariesExchangeAudioOrganizationAndOfflineEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookSyncApp-\(UUID())")
        let aURL = root.appendingPathComponent("MacA"), bURL = root.appendingPathComponent("MacB"), cloud = root.appendingPathComponent("Cloud")
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let aDefaults = makeTestDefaults("daybook.sync.app.A"), bDefaults = makeTestDefaults("daybook.sync.app.B")
        let a = AppState(libraryURL: aURL, defaults: aDefaults), b = AppState(libraryURL: bURL, defaults: bDefaults)
        defer {
            a.sync.disconnect(); b.sync.disconnect()
            try? FileManager.default.removeItem(at: root)
        }
        await a.initialize(); await b.initialize()
        // The test runs every pass itself; an edit's automatic pass would race it.
        a.sync.syncDebounce = nil; b.sync.syncDebounce = nil
        let source = root.appendingPathComponent("source.wav")
        try writeAudio(source)
        try await a.importFiles([source], source: .soundcore, attachTo: nil)
        let id = try XCTUnwrap(a.meetings.first?.id)
        let folder = LibraryFolder(name: "Research")
        a.saveFolder(folder)
        let template = SummaryTemplate(name: "Research detail", kind: .interview, instructions: "Keep evidence, uncertainties, and open questions.")
        a.saveTemplate(template)
        let word = GlossaryTerm(term: "Daybook", definition: "Our local notes app", approved: true)
        a.saveGlossaryTerm(word)
        a.update(id) { $0.folderID = folder.id; $0.tags = ["research", "local"]; $0.templateID = template.id }
        a.editNotes(id, text: "Original notes")
        await a.flush()
        try a.sync.connect(to: cloud, monitorChanges: false)
        try b.sync.connect(to: cloud, monitorChanges: false)
        await a.synchronizeLibrary(); await b.synchronizeLibrary()
        XCTAssertFalse(a.sync.status.contains("paused"), a.sync.status)
        XCTAssertFalse(b.sync.status.contains("paused"), b.sync.status)
        let imported = try XCTUnwrap(b.meetings.first { $0.id == id })
        XCTAssertEqual(imported.notes, "Original notes")
        XCTAssertEqual(imported.folderID, folder.id)
        XCTAssertEqual(imported.tags, ["research", "local"])
        XCTAssertEqual(b.folders, [folder])
        XCTAssertEqual(b.templates.first { $0.id == template.id }?.instructions, template.instructions)
        XCTAssertEqual(b.glossary.first { $0.id == word.id }?.term, "Daybook")
        let track = try XCTUnwrap(imported.tracks.first)
        let received = await b.audioURL(for: track, meetingID: id)
        let receivedURL = try XCTUnwrap(received)
        XCTAssertEqual(try Data(contentsOf: receivedURL), try Data(contentsOf: source))

        // Both machines edit from the same shared ancestor while disconnected.
        a.editNotes(id, text: "Mac A independently edited the notes")
        b.editNotes(id, text: "Mac B independently edited the notes")
        b.setTags(id, text: "research, follow-up")
        await a.flush(); await b.flush()
        await a.synchronizeLibrary(); await b.synchronizeLibrary(); await a.synchronizeLibrary()
        let mergedA = try XCTUnwrap(a.meetings.first { $0.id == id })
        let mergedB = try XCTUnwrap(b.meetings.first { $0.id == id })
        XCTAssertEqual(mergedA.notes, mergedB.notes)
        XCTAssertTrue(mergedA.revisions.contains { $0.field == "sync:notes" })
        let history = mergedA.revisions.map { $0.oldValue + $0.newValue }.joined()
        XCTAssertTrue(history.contains("Mac A independently"))
        XCTAssertTrue(history.contains("Mac B independently"))
        XCTAssertEqual(mergedA.tags, mergedB.tags)

        let aStore = try MeetingStore(rootURL: aURL)
        _ = try await aStore.moveToTrash(id)
        a.meetings.removeAll { $0.id == id }
        await a.synchronizeLibrary(); await b.synchronizeLibrary()
        XCTAssertFalse(b.meetings.contains { $0.id == id })
        XCTAssertTrue(FileManager.default.fileExists(atPath: bURL.appendingPathComponent("Trash/\(id)/meeting.json").path))
        let restarted = AppState(libraryURL: bURL, defaults: bDefaults)
        await restarted.initialize()
        XCTAssertTrue(restarted.meetings.isEmpty)
        XCTAssertEqual(restarted.folders, [folder])
    }

    private func writeAudio(_ url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600)!
        buffer.frameLength = 1_600
        for i in 0..<1_600 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.2) * 0.1) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
