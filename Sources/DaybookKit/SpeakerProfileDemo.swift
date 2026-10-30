#if DEBUG
import DaybookCore
import Foundation

/// Debug only: `--speaker-demo`, with either app's demo library, adds conversations whose speakers
/// show what speaker profiles do, for screenshots: names the person gave (Vlad, Priya, Sam), a voice
/// recognized as Vlad and one that may be Priya, in a conversation whose summary was written before
/// they were known, and the same person named "Vladimir" in a room recorder's conversation (a second
/// profile, to merge). The voices are synthetic vectors, and the recordings have no audio. Nothing
/// is added when the library already has these conversations.
@MainActor
public enum SpeakerProfileDemo {
    public static var isRequested: Bool { CommandLine.arguments.contains("--speaker-demo") }
    public static let recognized = "Vendor call"

    public static func seed(_ library: LibraryController, now: Date = Date()) async {
        guard library.isLoaded, !library.meetings.contains(where: { $0.title == recognized }) else { return }
        let vlad = voice(1), priya = voice(2), sam = voice(3)
        func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }
        conversation(library, "Design crit", at: ago(10), [(near(vlad, 0.95, 11), 120, "Vlad"), (near(priya, 0.95, 12), 90, "Priya")])
        conversation(library, "Hiring sync", at: ago(6), [(near(vlad, 0.95, 13), 200, nil), (near(sam, 0.95, 14), 80, "Sam")])
        conversation(library, recognized, at: ago(3), [(near(vlad, 0.95, 15), 150, nil), (near(priya, 0.74, 16), 60, nil)],
                     summary: MeetingSummary(kind: .general, title: recognized,
                                             overview: "Speaker 1 walked Speaker 2 through the renewal terms. They agreed to keep the current price for another year.",
                                             actionItems: [ActionItem(text: "Send the renewal draft", owner: "Speaker 1")]))
        conversation(library, "Planning walk", at: ago(2), [(near(vlad, 0.86, 17), 240, "Vladimir")], device: "soundcore.work")
        for _ in 0..<4 where await library.reconcileSpeakerProfiles(options: .init()) {}
        // A screenshot run quits soon after: what was seeded is on disk first.
        await library.flush()
    }

    /// One recording (no audio), its speakers talking in turn; each named "Speaker n", then renamed by
    /// the person when it has a name.
    private static func conversation(_ library: LibraryController, _ title: String, at date: Date,
                                      _ voices: [(vector: [Float], seconds: Double, name: String?)],
                                      summary: MeetingSummary? = nil, device: String? = nil) {
        let id = library.newMeeting(title: title, date: date)
        library.update(id) { meeting in
            var track = RecordingTrack(source: device == nil ? .microphone : .soundcore, relativePath: "Originals/Recording.m4a",
                                       fileName: "Recording.m4a", createdAt: date, duration: voices.reduce(0) { $0 + $1.seconds }, offset: 0)
            if let device { track.deviceKind = device }
            let run = UUID()
            var time = 0.0
            var segments: [TranscriptSegment] = []
            for (index, voice) in voices.enumerated() {
                let speaker = "\(run.uuidString):\(index)"
                segments.append(TranscriptSegment(trackID: track.id, start: time, end: time + voice.seconds, text: lines[index % lines.count], speakerID: speaker))
                time += voice.seconds
                meeting.speakers.append(Speaker(id: speaker, name: "Speaker \(index + 1)", sourceTrackID: track.id, embedding: voice.vector,
                                                embeddingModelID: space))
            }
            meeting.tracks = [track]
            meeting.transcripts = [TrackTranscript(id: run, trackID: track.id, segments: segments, modelID: "parakeet/ultra", createdAt: date)]
            meeting.unifiedTranscript = segments
            if let summary { meeting.summary = summary }
            meeting.status = .ready
            for (index, voice) in voices.enumerated() {
                if let name = voice.name { meeting.renameSpeaker(id: "\(run.uuidString):\(index)", name: name) }
            }
        }
    }

    private static let space = "fluid-community1-embedding-df2625ac79a7ac6b"
    private static let lines = ["Let's go through where things stand.", "That works for me, as long as the dates hold.",
                                "I'll write it up afterwards."]

    /// A person's voice: a pseudo-random unit vector, the same for a seed on every run.
    private static func voice(_ seed: UInt64, dimensions: Int = 64) -> [Float] { normalized(noise(seed &* 7919 &+ 17, dimensions)) }

    /// A recording of `voice`: exactly `similarity` alike to it, in a direction set by `seed`.
    private static func near(_ voice: [Float], _ similarity: Double, _ seed: UInt64) -> [Float] {
        let base = normalized(voice)
        var other = noise(seed &* 104_729 &+ 3, base.count)
        let along = zip(other, base).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
        other = normalized(zip(other, base).map { Float(Double($0.0) - along * Double($0.1)) })
        let rest = (1 - similarity * similarity).squareRoot()
        return zip(base, other).map { Float(similarity * Double($0.0) + rest * Double($0.1)) }
    }

    private static func noise(_ seed: UInt64, _ count: Int) -> [Float] {
        var state = seed | 1
        return (0..<count).map { _ in
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Float(Double(state % 2_000_001) / 1_000_000 - 1)
        }
    }

    private static func normalized(_ values: [Float]) -> [Float] {
        let norm = values.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
        return norm > 0 ? values.map { Float(Double($0) / norm) } : values
    }
}
#endif
