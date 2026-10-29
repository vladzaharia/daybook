#if DEBUG
import AVFoundation
import DaybookCaptions
import DaybookKit
import UIKit

/// Debug only: `--demo-library` fills an empty library (use it with `--library <scratch folder>`)
/// with conversations in every state the reading screens show, for screenshots: transcribed with a
/// summary, photos, notes, and bookmarks; recorded but not transcribed (with saved live captions);
/// waiting for a Mac; transcribing; waiting for a recorder's audio; couldn't finish; no speech; audio not on this iPhone; notes only;
/// a long title; Personal; a folder with one conversation and an empty one; and one in the Trash.
/// The audio is generated tone, never a recording. Nothing is written when the library already has
/// conversations.
@MainActor
enum DemoLibrary {
    static var isRequested: Bool { CommandLine.arguments.contains("--demo-library") }

    static func seed(_ library: LibraryController, rootURL: URL, now: Date = Date()) {
        guard isRequested, library.isLoaded, library.meetings.isEmpty, library.trashedMeetingIDs().isEmpty else { return }
        let studio = ProcessingRequest.Device(id: "demo-studio-mac", name: "Studio Mac")
        let clients = library.createFolder(named: "Northwind")
        _ = library.createFolder(named: "Archive")

        // Transcribed, summarized, with notes, bookmarks, tags, photos, and a change in Version History.
        let weekly = recorded("Weekly product sync", at: now.addingTimeInterval(-2 * 3600), seconds: 41.5, rootURL: rootURL)
        var full = weekly.meeting
        let trackID = weekly.trackID
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
        full.speakers = ["Maya", "Daniel", "Priya"].enumerated().map { Speaker(id: "S\($0.offset)", name: $0.element, sourceTrackID: trackID) }
        let segments = lines.map { speaker, text, start, end -> TranscriptSegment in
            let id = UUID()
            return TranscriptSegment(id: id, trackID: trackID, start: start, end: end, text: text, speakerID: "S\(speaker)",
                                     provenance: [SegmentProvenance(trackID: trackID, segmentID: id, start: start, end: end, text: text)])
        }
        full.transcripts = [TrackTranscript(trackID: trackID, segments: segments, modelID: "whisper-small", createdAt: now.addingTimeInterval(-6000))]
        full.unifiedTranscript = segments
        full.summary = MeetingSummary(
            overview: "The team agreed to keep the beta date of the 14th, gated on the sync conflict fix.",
            sections: [SummarySection(heading: "Decisions", body: "- Keep the **14th** as the beta date.\n- The sync conflict fix is the release gate."),
                       SummarySection(heading: "Open questions", body: "- Does Markdown export make the beta, or the release after it?")],
            actionItems: [ActionItem(text: "Post a status update on the conflict fix", owner: "Daniel"),
                          ActionItem(text: "Finish the release notes, including Markdown export", owner: "Priya"),
                          ActionItem(text: "Book the beta review", owner: "Maya", completed: true)],
            createdAt: now.addingTimeInterval(-5900))
        full.notes = "Beta date — hold the 14th?\nAsk about export for the release notes"
        full.timedNotes = [TimedNote(time: 2, text: "Beta date — hold the 14th?"), TimedNote(time: 24, text: "Ask about export for the release notes")]
        full.highlights = [Highlight(trackID: trackID, time: 14.5, text: "Gate on the conflict fix"), Highlight(trackID: trackID, time: 32)]
        full.tags = ["launch", "beta"]
        full.status = .ready
        full.revisions = [MeetingRevision(date: now.addingTimeInterval(-5000), field: "notes", oldValue: "Beta date?", newValue: full.notes)]
        library.add(full)
        Task {
            for (seconds, hue) in [(16.0, 0.48), (33.0, 0.62)] {
                try? await library.addCameraPhoto(CameraPhoto(data: photo(hue: hue), fileExtension: "jpg",
                                                              capturedAt: full.date.addingTimeInterval(seconds)), to: full.id)
            }
        }

        // Recorded, not transcribed yet, with this iPhone's saved live captions.
        let review = recorded("Onboarding design review", at: now.addingTimeInterval(-40 * 60), seconds: 24, rootURL: rootURL)
        library.add(review.meeting)
        try? LiveCaptionStore(libraryRoot: rootURL).save(LiveCaptions(
            meetingID: review.meeting.id, trackID: review.trackID, localeIdentifier: "en_US",
            segments: [LiveCaptionSegment(start: 0.5, end: 6, text: "So the first screen asks for the name of the team.", isTentative: false),
                       LiveCaptionSegment(start: 6.4, end: 12, text: "Then we skip straight to inviting people, which tested well.", isTentative: false),
                       LiveCaptionSegment(start: 12.5, end: 16, text: "Maybe the empty state needs another pass", isTentative: true)]))

        // Waiting for a Mac, with a long title.
        var waiting = recorded("Customer call with Northwind Traders about the renewal terms, pricing for the expansion, and the rollout plan for three new regions next quarter",
                               at: now.addingTimeInterval(-26 * 3600), seconds: 30, rootURL: rootURL).meeting
        waiting.folderID = clients
        waiting.upsertProcessingRequest(ProcessingRequest(meetingID: waiting.id, mode: .newAudio, requestedBy: library.thisDevice,
                                                          createdAt: now.addingTimeInterval(-25 * 3600)))
        library.add(waiting)

        // Transcribing on a Mac, 40% through.
        var hiring = recorded("Hiring sync", at: now.addingTimeInterval(-28 * 3600), seconds: 30, rootURL: rootURL).meeting
        let request = ProcessingRequest(meetingID: hiring.id, mode: .newAudio, requestedBy: library.thisDevice, createdAt: now.addingTimeInterval(-300))
        if let claimed = request.claimed(by: studio, at: now.addingTimeInterval(-60))?
            .renewed(by: studio, at: now, stage: .transcribing, fraction: 0.4) {
            hiring.upsertProcessingRequest(claimed)
        }
        library.add(hiring)

        // Summarized from a Mac's audio, waiting for a recorder's that recorded along (Mac first).
        var walkthrough = recorded("Design review", at: now.addingTimeInterval(-3 * 3600), seconds: 20, rootURL: rootURL)
        let heard = TranscriptSegment(trackID: walkthrough.trackID, start: 0.5, end: 6, text: "Let's walk through the new onboarding flow.",
                                      speakerID: "S0")
        walkthrough.meeting.speakers = [Speaker(id: "S0", name: "Maya", sourceTrackID: walkthrough.trackID)]
        walkthrough.meeting.transcripts = [TrackTranscript(trackID: walkthrough.trackID, segments: [heard],
                                                           createdAt: now.addingTimeInterval(-2.8 * 3600))]
        walkthrough.meeting.unifiedTranscript = [heard]
        walkthrough.meeting.summary = MeetingSummary(overview: "The team walked through the new onboarding flow.",
                                                     createdAt: now.addingTimeInterval(-2.8 * 3600))
        walkthrough.meeting.status = .ready
        var along = CompanionRecording(deviceID: "demo-soundcore", deviceKind: "soundcore.work", deviceName: "Soundcore Work",
                                       macStartedAt: now.addingTimeInterval(-3 * 3600), state: .stopped, startedByDaybook: true)
        along.macEndedAt = now.addingTimeInterval(-3 * 3600 + 20)
        along.recordingID = "\(Int(now.addingTimeInterval(-3 * 3600).timeIntervalSince1970))"
        walkthrough.meeting.companions = [along]
        library.add(walkthrough.meeting)

        // Couldn't finish, and no speech.
        for (title, hours, reason) in [("Interview with Sam", 74.0, "The speech model isn’t downloaded."),
                                       ("Pocket recording", 80.0, "No speech was recognized.")] {
            var failed = recorded(title, at: now.addingTimeInterval(-hours * 3600), seconds: 20, rootURL: rootURL).meeting
            let request = ProcessingRequest(meetingID: failed.id, mode: .newAudio, requestedBy: library.thisDevice,
                                            createdAt: now.addingTimeInterval(-hours * 3600 + 60))
            if let done = request.claimed(by: studio, at: now.addingTimeInterval(-hours * 3600 + 120))?
                .failed(by: studio, at: now.addingTimeInterval(-hours * 3600 + 300), reason: reason) {
                failed.upsertProcessingRequest(done)
            }
            library.add(failed)
        }

        // Notes only.
        library.add(Meeting(title: "Ideas for the offsite", date: now.addingTimeInterval(-4 * 86_400), updatedAt: now.addingTimeInterval(-4 * 86_400),
                            notes: "Walk instead of a room\nAsk Priya about the venue\nBudget by Friday", status: .draft))

        // Personal, transcribed without a summary yet.
        var dentist = recorded("Dentist follow-up", at: now.addingTimeInterval(-9 * 86_400), seconds: 12, rootURL: rootURL)
        let words = TranscriptSegment(trackID: dentist.trackID, start: 0.4, end: 6, text: "Everything looks good. Come back in six months for a cleaning.", speakerID: "S0")
        dentist.meeting.speakers = [Speaker(id: "S0", name: "Speaker 1", sourceTrackID: dentist.trackID)]
        dentist.meeting.transcripts = [TrackTranscript(trackID: dentist.trackID, segments: [words], createdAt: now.addingTimeInterval(-9 * 86_400 + 600))]
        dentist.meeting.unifiedTranscript = [words]
        dentist.meeting.placement = .personal
        dentist.meeting.status = .ready
        library.add(dentist.meeting)

        // Audio that isn't on this iPhone (its file never written), for the player's offline line.
        var offline = recorded("Offsite walk", at: now.addingTimeInterval(-30 * 3600), seconds: 18, rootURL: rootURL, writesAudio: false).meeting
        offline.status = .imported
        library.add(offline)

        // Older ones, for the date groups and a long selection.
        for (index, title) in ["Design critique", "Roadmap review", "Vendor intro", "Team retro", "Board prep"].enumerated() {
            var older = recorded(title, at: now.addingTimeInterval(-Double(20 + index * 9) * 86_400), seconds: 10, rootURL: rootURL).meeting
            older.status = .imported
            library.add(older)
        }

        // In the Trash.
        let trashed = library.newMeeting(title: "Old standup", date: now.addingTimeInterval(-12 * 86_400))
        Task { _ = try? await library.moveToTrash(trashed) }
    }

    /// A conversation with one generated recording of `seconds`, written where the library keeps originals.
    private static func recorded(_ title: String, at date: Date, seconds: Double, rootURL: URL,
                                 writesAudio: Bool = true) -> (meeting: Meeting, trackID: UUID) {
        let id = UUID(), trackID = UUID()
        let folder = rootURL.appendingPathComponent("Meetings/\(id.uuidString)/Originals", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if writesAudio { tone(seconds: seconds, to: folder.appendingPathComponent("Microphone.wav")) }
        let track = RecordingTrack(id: trackID, source: .microphone, relativePath: "Originals/Microphone.wav", fileName: "Microphone.wav",
                                   createdAt: date, duration: seconds, offset: 0, startedAt: date)
        return (Meeting(id: id, title: title, date: date, updatedAt: date, tracks: [track], status: .imported), trackID)
    }

    /// A quiet, wavering tone: something to scrub through, nothing anyone said.
    private static func tone(seconds: Double, to url: URL) {
        let rate = 16_000.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let file = try? AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                                                    AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16]),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * rate)),
              let samples = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<Int(buffer.frameLength) {
            let time = Double(index) / rate
            samples[index] = Float(0.08 * sin(2 * .pi * 220 * time) * (0.5 + 0.5 * sin(2 * .pi * 0.7 * time)))
        }
        try? file.write(from: buffer)
    }

    /// A plain picture: a gradient and a few shapes, standing in for a whiteboard photo.
    private static func photo(hue: Double) -> Data {
        let size = CGSize(width: 1200, height: 900)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor(hue: hue, saturation: 0.35, brightness: 0.95, alpha: 1).cgColor,
                          UIColor(hue: hue + 0.08, saturation: 0.55, brightness: 0.7, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            UIColor.white.withAlphaComponent(0.85).setFill()
            for row in 0..<4 {
                UIBezierPath(roundedRect: CGRect(x: 120, y: 180 + row * 150, width: 600 + (row % 2) * 240, height: 46), cornerRadius: 23).fill()
            }
        }
        return image.jpegData(compressionQuality: 0.8) ?? Data()
    }
}
#endif
