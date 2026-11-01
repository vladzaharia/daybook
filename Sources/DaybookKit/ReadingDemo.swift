#if DEBUG
import CoreGraphics
import DaybookCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Debug only: `--library-demo` (or `--demo-library`), with `--library <scratch folder>`, fills either app's library
/// with the same conversations in every state the list, the page, the inspector, and Info show, so a Mac snapshot
/// and an iPhone screenshot of one conversation show the same content and only the layout differs:
///
/// - ready with a summary, next steps, notes, bookmarks, tags, photos, a change in Version History, and a recorder's
///   recording lined up by sound ("Weekly product sync"); one with a very long title and a recording that couldn't
///   be lined up; one transcribed without a summary (Personal);
/// - recorded and not transcribed, with saved live captions; recorded, with a recording that may belong elsewhere;
///   recordings whose audio isn't on this device;
/// - asked for and waiting for a Mac (in a folder, with a long title); asked for on an iPhone; transcribing on
///   Studio Mac (55%);
/// - couldn't finish transcribing (the model stopped), its models missing on Studio Mac, couldn't finish summarizing
///   (memory), and no speech;
/// - summarized from a Mac's audio and waiting for a recorder's that recorded along;
/// - notes only (two); older ones for the date groups; one in the Trash; a folder with conversations and an empty one.
///
/// This device's own states (transcribing here, waiting in its queue, paused, waiting for models) aren't library
/// data: each app sets them on top (the Mac's `LibraryDemo`). The audio is generated tone, never a recording; the
/// photos are drawn shapes. Nothing is written when the library already has the demo.
@MainActor
public enum ReadingDemo {
    public static var isRequested: Bool {
        CommandLine.arguments.contains("--library-demo") || CommandLine.arguments.contains("--demo-library")
    }

    /// Which app seeds it: an iPhone's own requests are this device's; on a Mac they're Alex's iPhone's.
    public enum Seeder: Sendable { case mac, iPhone }

    /// The conversations' titles, for each app's own states and for `--select`.
    public enum Title {
        public static let ready = "Weekly product sync"
        public static let longTitle = "Quarterly planning with finance, design, and platform on the spring launch budget, hiring, and the packaging timeline"
        public static let transcribing = "Roadmap review"
        public static let queued = "Customer call with Northwind Traders about the renewal terms, pricing for the expansion, and the rollout plan for three new regions next quarter"
        public static let paused = "1:1 with Priya"
        public static let waitingForModels = "Research interview"
        public static let elsewhere = "Standup"
        public static let requested = "Dentist appointment"
        public static let failedTranscribing = "Board prep"
        public static let modelsMissing = "Interview with Sam"
        public static let failedSummarizing = "Interview debrief"
        public static let noSpeech = "Hallway chat"
        public static let recorded = "Vendor walkthrough"
        public static let captions = "Onboarding design review"
        public static let transcriptOnly = "Dentist follow-up"
        public static let awaiting = "Design review"
        public static let offline = "Offsite walk"
        public static let notesOnly = "Ideas for the offsite"
        public static let personalNotes = "Grocery list for the weekend"
        public static let older = "Offsite retro"
        public static let trashed = "Old standup"
    }

    /// A line of saved live captions, for each app to write through its own caption store.
    public struct CaptionLine: Equatable, Sendable {
        public var start: TimeInterval
        public var end: TimeInterval
        public var text: String
        public var isTentative: Bool
        /// The live speaker's slot, and its name when a voice profile recognized it.
        public var speakerSlot: String?
        public var speakerName: String?
    }

    /// The Mac that does the work in the demo, and the iPhone that asks for it.
    public static let studio = ProcessingRequest.Device(id: "demo-studio-mac", name: "Studio Mac")
    public static let phone = ProcessingRequest.Device(id: "demo-alex-iphone", name: "Alex’s iPhone")

    /// Fills `library` (loaded, a scratch one) with its conversations at once, so a launch's `--select` finds them
    /// right after. `saveCaptions` writes a conversation's saved live captions (meeting, recording, locale, lines)
    /// where the app keeps them. What takes the library's lock (photos, the Trash) and the save to disk follow in the
    /// task returned; nil when the library already has the demo.
    @discardableResult
    public static func seed(_ library: LibraryController, as seeder: Seeder, now: Date = Date(),
                            saveCaptions: (UUID, UUID, String, [CaptionLine]) -> Void) -> Task<Void, Never>? {
        guard library.isLoaded, !library.meetings.contains(where: { $0.title == Title.ready }) else { return nil }
        let root = library.rootURL
        let asker = seeder == .iPhone ? library.thisDevice : phone
        func ago(days: Double = 0, hours: Double = 0, minutes: Double = 0) -> Date {
            now.addingTimeInterval(-(days * 86_400 + hours * 3600 + minutes * 60))
        }
        let clients = library.createFolder(named: "Clients")
        _ = library.createFolder(named: "Archive")

        // Ready: everything the page shows, with audio that plays.
        var weekly = recorded(Title.ready, at: ago(hours: 2), seconds: 41.5, audio: 41.5, root: root)
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
        let track = weekly.trackID
        weekly.meeting.speakers = ["Maya", "Daniel", "Priya"].enumerated().map { Speaker(id: "S\($0.offset)", name: $0.element, sourceTrackID: track) }
        let segments = lines.map { speaker, text, start, end -> TranscriptSegment in
            let id = UUID()
            return TranscriptSegment(id: id, trackID: track, start: start, end: end, text: text, speakerID: "S\(speaker)",
                                     provenance: [SegmentProvenance(trackID: track, segmentID: id, start: start, end: end, text: text)])
        }
        weekly.meeting.transcripts = [TrackTranscript(trackID: track, segments: segments, modelID: "parakeet/ultra", createdAt: ago(minutes: 100))]
        weekly.meeting.unifiedTranscript = segments
        weekly.meeting.kind = .general
        weekly.meeting.summary = MeetingSummary(
            kind: .general, title: Title.ready,
            overview: "The team agreed to keep the beta date of the 14th, gated on the sync conflict fix.",
            sections: [SummarySection(heading: "Decisions", body: "- Keep the **14th** as the beta date.\n- The sync conflict fix is the release gate."),
                       SummarySection(heading: "Open questions", body: "- Does Markdown export make the beta, or the release after it?")],
            actionItems: [ActionItem(text: "Post a status update on the conflict fix", owner: "Daniel"),
                          ActionItem(text: "Finish the release notes, including Markdown export", owner: "Priya"),
                          ActionItem(text: "Book the beta review", owner: "Maya", completed: true)],
            modelID: "gemma-4/e2b-4bit", createdAt: ago(minutes: 98))
        weekly.meeting.notes = "Beta date: hold the 14th?\nAsk about export for the release notes"
        weekly.meeting.timedNotes = [TimedNote(time: 2, text: "Beta date: hold the 14th?"), TimedNote(time: 24, text: "Ask about export for the release notes")]
        weekly.meeting.highlights = [Highlight(trackID: track, time: 14.5, text: "Gate on the conflict fix"), Highlight(trackID: track, time: 32)]
        weekly.meeting.tags = ["launch", "beta"]
        weekly.meeting.placement = .work
        weekly.meeting.status = .ready
        let written = (try? JSONEncoder().encode(weekly.meeting.summary)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        weekly.meeting.revisions = [MeetingRevision(date: ago(minutes: 98), field: "summary", oldValue: "", newValue: written),
                                    MeetingRevision(date: ago(minutes: 83), field: "notes", oldValue: "Beta date?", newValue: weekly.meeting.notes)]
        // A Soundcore that recorded along, lined up with this recording by sound.
        let soundcore = UUID()
        tone(seconds: 38, to: root.appendingPathComponent("Meetings/\(weekly.meeting.id.uuidString)/Originals/REC0042.wav"))
        weekly.meeting.tracks.append(RecordingTrack(id: soundcore, source: .soundcore, relativePath: "Originals/REC0042.wav", fileName: "REC0042.wav",
                                                    createdAt: weekly.meeting.date, duration: 38, offset: 3.4,
                                                    device: DeviceRecordingIdentity(kind: "soundcore.work", serial: "demo-soundcore", recordingID: "42"),
                                                    startedAt: weekly.meeting.date.addingTimeInterval(3.4),
                                                    alignment: SourceAlignment(method: .audio, offset: 3.4, confidence: 0.92)))
        weekly.meeting.transcripts.append(TrackTranscript(trackID: soundcore, segments: [], modelID: "parakeet/ultra", createdAt: ago(minutes: 101)))
        weekly.meeting.alignmentReports = [TrackAlignment(trackID: track, method: .reference), TrackAlignment(trackID: soundcore, method: .audio, offset: 3.4)]
        library.add(weekly.meeting)

        // A very long title, and a second recording that couldn't be lined up.
        var planning = recorded(Title.longTitle, at: ago(days: 1, hours: 3), seconds: 52 * 60, root: root)
        let unaligned = UUID()
        tone(seconds: 4, to: root.appendingPathComponent("Meetings/\(planning.meeting.id.uuidString)/Originals/REC0043.wav"))
        planning.meeting.tracks.append(RecordingTrack(id: unaligned, source: .soundcore, relativePath: "Originals/REC0043.wav", fileName: "REC0043.wav",
                                                      createdAt: planning.meeting.date, duration: 49 * 60 + 11,
                                                      device: DeviceRecordingIdentity(kind: "soundcore.work", serial: "demo-soundcore", recordingID: "43")))
        planning.meeting.speakers = [Speaker(id: "0", name: "Dana"), Speaker(id: "1", name: "Speaker 2")]
        transcribe(&planning.meeting, track: planning.trackID, lines: [
            (8, "0", "We have three things today: the budget, hiring, and packaging."),
            (44, "1", "Marketing is about ten percent over. Events are under by about the same."),
            (1220, "0", "Then we move the difference over and keep the launch date."),
        ])
        planning.meeting.transcripts.append(TrackTranscript(trackID: unaligned, segments: [
            TranscriptSegment(trackID: unaligned, start: 30, end: 40, text: "Marketing is about ten percent over.", speakerID: "1"),
        ], modelID: "parakeet/ultra"))
        planning.meeting.alignmentReports.append(TrackAlignment(trackID: unaligned, method: .unaligned))
        planning.meeting.notes = "Budget: move events → marketing"
        planning.meeting.placement = .work
        planning.meeting.summary = MeetingSummary(kind: .general, title: Title.longTitle,
            overview: "The team moved the events underspend to marketing, kept the launch date, and agreed to revisit packaging next week.",
            actionItems: [ActionItem(text: "Revisit the packaging timeline next week", owner: "Dana")], modelID: "gemma-4/e2b-4bit")
        planning.meeting.status = .ready
        library.add(planning.meeting)

        // Recorded and not transcribed: on a Mac, transcribing here, paused, and waiting for models.
        var roadmap = recorded(Title.transcribing, at: ago(minutes: 40), seconds: 41 * 60, root: root).meeting
        roadmap.notes = "Agenda: the floating panel, then the shared design pieces."
        library.add(roadmap)
        var priya = recorded(Title.paused, at: ago(days: 1, hours: 6), seconds: 24 * 60, root: root).meeting
        priya.placement = .work
        library.add(priya)
        var research = recorded(Title.waitingForModels, at: ago(days: 20), seconds: 22 * 60, root: root).meeting
        research.folderID = clients
        library.add(research)

        // Asked for and waiting for a Mac, in a folder, with a long title (on a Mac: in its queue).
        var northwind = recorded(Title.queued, at: ago(hours: 26), seconds: 33 * 60, root: root).meeting
        northwind.folderID = clients
        northwind.placement = .work
        northwind.upsertProcessingRequest(ProcessingRequest(meetingID: northwind.id, mode: .newAudio, requestedBy: asker, createdAt: ago(hours: 25)))
        library.add(northwind)

        // Transcribing on Studio Mac, asked for on an iPhone.
        var standup = recorded(Title.elsewhere, at: ago(hours: 3), seconds: 12 * 60, root: root).meeting
        standup.upsertProcessingRequest(ProcessingRequest(meetingID: standup.id, mode: .newAudio, requestedBy: asker, createdAt: ago(hours: 3),
            claim: .init(device: studio, claimedAt: now, heartbeat: now, expiresAt: now.addingTimeInterval(3600), stage: .transcribing, fraction: 0.55)))
        library.add(standup)
        // Asked for on Alex's iPhone and waiting for a Mac.
        var dentist = recorded(Title.requested, at: ago(days: 2, hours: 1), seconds: 8 * 60, source: .imported, root: root).meeting
        dentist.upsertProcessingRequest(ProcessingRequest(meetingID: dentist.id, mode: .newAudio, requestedBy: phone, createdAt: ago(days: 2)))
        dentist.placement = .personal
        library.add(dentist)

        // Couldn't finish: the model stopped, its models missing on Studio Mac, the summary's memory, and no speech.
        for (title, days, minutes, reason, kind) in [
            (Title.failedTranscribing, 3.0, 18.0, "Transcription stopped: the model process exited unexpectedly (code 5).", ProcessingRequest.FailureKind.other),
            (Title.modelsMissing, 3.1, 31.0, "Download Parakeet Ultra in Models before processing.", .modelsMissing),
            (Title.noSpeech, 5.0, 2.0, "No speech was recognized.", .noSpeech),
        ] {
            var failed = recorded(title, at: ago(days: days), seconds: minutes * 60, root: root).meeting
            let request = ProcessingRequest(meetingID: failed.id, mode: .newAudio, requestedBy: asker, createdAt: ago(days: days, minutes: -1))
            if let done = request.claimed(by: studio, at: ago(days: days, minutes: -2))?
                .failed(by: studio, at: ago(days: days, minutes: -5), reason: reason, kind: kind) {
                failed.upsertProcessingRequest(done)
            }
            library.add(failed)
        }
        var debrief = recorded(Title.failedSummarizing, at: ago(days: 4), seconds: 45 * 60, root: root)
        debrief.meeting.speakers = [Speaker(id: "0", name: "Alex"), Speaker(id: "1", name: "Jordan")]
        transcribe(&debrief.meeting, track: debrief.trackID, lines: [
            (3, "0", "Strong on systems design. A little quiet in the product round."),
            (40, "1", "I'd hire, with a note about pairing in the first month."),
        ])
        debrief.meeting.status = .failed
        debrief.meeting.errorMessage = "The language model couldn’t allocate enough memory."
        debrief.meeting.placement = .work
        library.add(debrief.meeting)

        // Recorded, with a recording that may belong with the customer call.
        var vendor = recorded(Title.recorded, at: ago(days: 6), seconds: 15 * 60, root: root)
        vendor.meeting.folderID = clients
        vendor.meeting.sourceSuggestions = [SourceSuggestion(trackID: vendor.trackID, candidateMeetingIDs: [northwind.id], reason: .lowConfidence)]
        library.add(vendor.meeting)

        // Recorded, not transcribed yet, with this device's saved live captions.
        let review = recorded(Title.captions, at: ago(minutes: 40 + 5), seconds: 24, audio: 24, root: root)
        library.add(review.meeting)
        saveCaptions(review.meeting.id, review.trackID, "en_US", [
            CaptionLine(start: 0.5, end: 6, text: "So the first screen asks for the name of the team.", isTentative: false, speakerSlot: "S1", speakerName: "Maya"),
            CaptionLine(start: 6.4, end: 12, text: "Then we skip straight to inviting people, which tested well.", isTentative: false,
                        speakerSlot: "S1", speakerName: "Maya"),
            CaptionLine(start: 12.5, end: 16, text: "Maybe the empty state needs another pass", isTentative: true, speakerSlot: "S2", speakerName: nil),
        ])

        // Transcribed without a summary yet (Personal).
        var followUp = recorded(Title.transcriptOnly, at: ago(days: 9), seconds: 12, audio: 12, root: root)
        let words = TranscriptSegment(trackID: followUp.trackID, start: 0.4, end: 6, text: "Everything looks good. Come back in six months for a cleaning.",
                                      speakerID: "S0")
        followUp.meeting.speakers = [Speaker(id: "S0", name: "Speaker 1", sourceTrackID: followUp.trackID)]
        followUp.meeting.transcripts = [TrackTranscript(trackID: followUp.trackID, segments: [words], createdAt: ago(days: 9, minutes: -10))]
        followUp.meeting.unifiedTranscript = [words]
        followUp.meeting.placement = .personal
        followUp.meeting.status = .ready
        library.add(followUp.meeting)

        // Summarized from a Mac's audio, waiting for a recorder's that recorded along (Mac first).
        var walkthrough = recorded(Title.awaiting, at: ago(hours: 3, minutes: 30), seconds: 20, audio: 20, root: root)
        let heard = TranscriptSegment(trackID: walkthrough.trackID, start: 0.5, end: 6, text: "Let's walk through the new onboarding flow.", speakerID: "S0")
        walkthrough.meeting.speakers = [Speaker(id: "S0", name: "Maya", sourceTrackID: walkthrough.trackID)]
        walkthrough.meeting.transcripts = [TrackTranscript(trackID: walkthrough.trackID, segments: [heard], createdAt: ago(hours: 3, minutes: 20))]
        walkthrough.meeting.unifiedTranscript = [heard]
        walkthrough.meeting.summary = MeetingSummary(overview: "The team walked through the new onboarding flow.", createdAt: ago(hours: 3, minutes: 20))
        walkthrough.meeting.status = .ready
        var along = CompanionRecording(deviceID: "demo-soundcore", deviceKind: "soundcore.work", deviceName: "Soundcore Work",
                                       macStartedAt: walkthrough.meeting.date, state: .stopped, startedByDaybook: true)
        along.macEndedAt = walkthrough.meeting.date.addingTimeInterval(20)
        along.recordingID = "\(Int(walkthrough.meeting.date.timeIntervalSince1970))"
        walkthrough.meeting.companions = [along]
        library.add(walkthrough.meeting)

        // Audio that isn't on this device (its file never written), for the player's line.
        library.add(recorded(Title.offline, at: ago(hours: 30), seconds: 18, writesAudio: false, root: root).meeting)

        // Notes only.
        library.add(Meeting(title: Title.notesOnly, date: ago(days: 4), updatedAt: ago(days: 4),
                            notes: "Walk instead of a room\nAsk Priya about the venue\nBudget by Friday", status: .draft))
        var groceries = Meeting(title: Title.personalNotes, date: ago(days: 2, hours: 20), updatedAt: ago(days: 2, hours: 20),
                                notes: "Tomatoes, basil, mozzarella\nBread from the bakery on Saturday\nAsk about the farmers’ market hours", status: .draft)
        groceries.placement = .personal
        library.add(groceries)

        // Older: an upgrade's target ("Offsite retro"), and more for the date groups.
        var retro = recorded(Title.older, at: ago(days: 41), seconds: 61 * 60, root: root)
        retro.meeting.speakers = [Speaker(id: "0", name: "Alex")]
        transcribe(&retro.meeting, track: retro.trackID, lines: [(4, "0", "What went well this quarter, and what we'd change.")])
        retro.meeting.summary = MeetingSummary(kind: .general, title: Title.older, overview: "The team kept the weekly demo and dropped the Friday status email.",
                                               modelID: "gemma-4/e2b-4bit")
        retro.meeting.status = .ready
        library.add(retro.meeting)
        for (index, title) in ["Design critique", "Vendor intro", "Team retro"].enumerated() {
            library.add(recorded(title, at: ago(days: Double(20 + index * 9)), seconds: 10, audio: 10, root: root).meeting)
        }

        let trashed = library.newMeeting(title: Title.trashed, date: ago(days: 12))
        let ready = weekly.meeting
        return Task { @MainActor in
            // In the Trash.
            _ = try? await library.moveToTrash(trashed)
            // Photos on the ready conversation, by their shutter moments.
            await library.acquireLock()
            for (seconds, hue) in [(16.0, 0.48), (33.0, 0.62)] {
                guard let data = photo(hue: hue) else { continue }
                _ = try? await library.addPhoto(data: data, to: ready.id, fileName: "Photo.jpg",
                                                timing: PhotoTimingInput(capturedAt: ready.date.addingTimeInterval(seconds)))
            }
            library.releaseLock()
            // A snapshot run quits soon after: what was seeded is on disk first.
            await library.flush()
        }
    }

    // MARK: Pieces

    /// A conversation with one microphone recording of `seconds`, its audio (`audio` seconds of tone, 4 by default, or
    /// none) written where the library keeps originals.
    private static func recorded(_ title: String, at date: Date, seconds: Double, audio: Double = 4, source: AudioSource = .microphone,
                                 writesAudio: Bool = true, root: URL) -> (meeting: Meeting, trackID: UUID) {
        let id = UUID(), trackID = UUID()
        let file = source == .imported ? "Recording.wav" : "Microphone.wav"
        let folder = root.appendingPathComponent("Meetings/\(id.uuidString)/Originals", isDirectory: true)
        if writesAudio { tone(seconds: min(audio, seconds), to: folder.appendingPathComponent(file)) }
        let track = RecordingTrack(id: trackID, source: source, relativePath: "Originals/\(file)", fileName: file,
                                   createdAt: date, duration: seconds, offset: 0, startedAt: date)
        return (Meeting(id: id, title: title, date: date, updatedAt: date, tracks: [track], status: .imported), trackID)
    }

    /// The transcript a run would have made: one recording's passages, fused as they are.
    private static func transcribe(_ meeting: inout Meeting, track: UUID, lines: [(TimeInterval, String, String)]) {
        let segments = lines.enumerated().map { index, line in
            TranscriptSegment(trackID: track, start: line.0, end: index + 1 < lines.count ? lines[index + 1].0 - 1 : line.0 + 12,
                              text: line.2, speakerID: line.1)
        }
        meeting.transcripts = [TrackTranscript(trackID: track, segments: segments, modelID: "parakeet/ultra")]
        meeting.unifiedTranscript = segments
    }

    /// A quiet, wavering tone as 16 kHz, 16-bit mono WAV: something to scrub through, nothing anyone said.
    static func tone(seconds: Double, to url: URL) {
        let rate = 16_000
        let count = max(0, Int(seconds * Double(rate)))
        var data = Data(capacity: 44 + count * 2)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + count * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(count * 2))
        for index in 0..<count {
            let time = Double(index) / Double(rate)
            let sample = 0.08 * sin(2 * .pi * 220 * time) * (0.5 + 0.5 * sin(2 * .pi * 0.7 * time))
            append(Int16(sample * Double(Int16.max)))
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// A plain picture as JPEG: a gradient and a few bars, standing in for a whiteboard photo.
    static func photo(hue: Double) -> Data? {
        let width = 1200, height = 900
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors = [color(hue: hue, saturation: 0.35, brightness: 0.95), color(hue: hue + 0.08, saturation: 0.55, brightness: 0.7)] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: [])
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85))
        for row in 0..<4 {
            let rect = CGRect(x: 120, y: height - 226 - row * 150, width: 600 + (row % 2) * 240, height: 46)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 23, cornerHeight: 23, transform: nil))
            context.fillPath()
        }
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func color(hue: Double, saturation: Double, brightness: Double) -> CGColor {
        let h = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let c = brightness * saturation, x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)), m = brightness - c
        let (r, g, b): (Double, Double, Double)
        switch Int(h) {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return CGColor(red: r + m, green: g + m, blue: b + m, alpha: 1)
    }
}
#endif
