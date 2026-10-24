import DaybookCaptions
import DaybookKit
import Foundation

// The caption models (`LiveCaptionSegment`, `LiveCaptions`) and the engine live in the shared
// DaybookCaptions library; the store and the `Meeting` rule below are the phone's own.

extension Meeting {
    /// Live captions stand in only while there is no official transcript; the Mac's replaces them.
    var showsLiveCaptions: Bool { transcripts.isEmpty && unifiedTranscript.isEmpty }
}

/// Phone-local storage at `<library>/LiveCaptions/<meeting id>.json`. Outside `Meetings/`, so sync
/// and the Mac never see it.
@MainActor
final class LiveCaptionStore {
    let directory: URL

    init(libraryRoot: URL) {
        directory = libraryRoot.appendingPathComponent("LiveCaptions", isDirectory: true)
    }

    func url(for meetingID: UUID) -> URL { directory.appendingPathComponent("\(meetingID.uuidString).json") }

    func captions(for meetingID: UUID) -> LiveCaptions? {
        guard let data = try? Data(contentsOf: url(for: meetingID)) else { return nil }
        return try? JSONDecoder().decode(LiveCaptions.self, from: data)
    }

    func save(_ captions: LiveCaptions) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(captions)
        try data.write(to: url(for: captions.meetingID), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func remove(_ meetingID: UUID) {
        try? FileManager.default.removeItem(at: url(for: meetingID))
    }
}
