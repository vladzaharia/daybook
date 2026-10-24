import DaybookCore
import Foundation
import XCTest
@testable import DaybookKit

/// The processing seam without models: applying one recording's result to a conversation, and the
/// whole-pass helper a device without the Mac's queue would call.
final class ProcessingEngineTests: XCTestCase {
    /// Scripted transcripts by file name; speakers "A" and "B" with voice profiles.
    private struct ScriptedEngine: ProcessingEngine {
        var lines: [String: [(Double, String, String)]]
        var embeddings: [String: [Float]] = [:]
        let calls = Calls()

        final class Calls: @unchecked Sendable {
            private let lock = NSLock()
            private var _transcribed: [String] = [], _summarized: [String] = []
            var transcribed: [String] { lock.withLock { _transcribed } }
            var summarized: [String] { lock.withLock { _summarized } }
            func transcribe(_ name: String) { lock.withLock { _transcribed.append(name) } }
            func summarize(_ text: String) { lock.withLock { _summarized.append(text) } }
        }

        func transcribe(_ input: TrackProcessingInput, progress: @escaping ProcessingProgressHandler) async throws -> TrackProcessingOutput {
            calls.transcribe(input.track.fileName)
            progress(ProcessingProgress(fraction: 1, message: "Transcribed"))
            let run = UUID()
            let segments = (lines[input.track.fileName] ?? []).map { start, speaker, text in
                TranscriptSegment(trackID: input.track.id, start: start, end: start + 2, text: text, speakerID: "\(run.uuidString):\(speaker)")
            }
            let speakers = Set(segments.compactMap(\.speakerID)).sorted().map { label in
                Speaker(id: label, name: "", embedding: embeddings[String(label.suffix(1))], embeddingModelID: embeddings.isEmpty ? nil : "voices")
            }
            return TrackProcessingOutput(transcript: TrackTranscript(id: run, trackID: input.track.id, segments: segments, modelID: "fake"),
                                         speakers: speakers, speakerEmbeddingModelID: embeddings.isEmpty ? nil : "voices",
                                         duration: (segments.last?.end ?? 0) + 1, notices: segments.isEmpty ? ["Nothing was said."] : [])
        }

        func summarize(_ meeting: Meeting, template: SummaryTemplate?, vocabulary: [String],
                       progress: @escaping ProcessingProgressHandler) async throws -> SummaryProcessingOutput {
            let transcript = MeetingEvidence.transcript(meeting)
            calls.summarize(transcript)
            return SummaryProcessingOutput(summary: MeetingSummary(kind: template?.kind ?? .general, overview: "\(meeting.unifiedTranscript.count) passages",
                                                                   modelID: "fake"),
                                           suggestedTerms: ["Daybook"], warnings: [])
        }
    }

    private func track(_ name: String, source: AudioSource = .imported) -> RecordingTrack {
        RecordingTrack(source: source, relativePath: "Originals/\(name)", fileName: name, sha256: name)
    }

    func testApplyingAResultNumbersSpeakersAfterTheConversationsAndRecordsTheLength() {
        let recording = track("call.m4a")
        var meeting = Meeting(title: "Call", tracks: [recording], speakers: [Speaker(id: "old", name: "Priya")])
        let run = UUID()
        let output = TrackProcessingOutput(
            transcript: TrackTranscript(id: run, trackID: recording.id, segments: [
                TranscriptSegment(trackID: recording.id, start: 0, end: 2, text: "Hi", speakerID: "\(run):B"),
                TranscriptSegment(trackID: recording.id, start: 2, end: 4, text: "Hello", speakerID: "\(run):A")]),
            speakers: [Speaker(id: "\(run):A", name: ""), Speaker(id: "\(run):B", name: "")], duration: 42)
        meeting.apply(output, matching: nil, allowSameSource: false)
        XCTAssertEqual(meeting.speakers.map(\.name), ["Priya", "Speaker 2", "Speaker 3"])
        XCTAssertEqual(meeting.speakers.last?.sourceTrackID, recording.id)
        XCTAssertEqual(meeting.transcripts.map(\.id), [run])
        XCTAssertEqual(meeting.tracks.first?.duration, 42)
        XCTAssertNil(meeting.speakerMatches, "Matching is off unless asked for")
    }

    func testMatchingByVoiceGivesTheNewRunTheKnownSpeakersName() {
        let first = track("mac.caf", source: .microphone), second = track("recorder.wav")
        let known = Speaker(id: "known", name: "Priya", sourceTrackID: first.id, embedding: [1, 0, 0], embeddingModelID: "voices")
        var meeting = Meeting(title: "Call", tracks: [first, second], speakers: [known])
        let run = UUID()
        let output = TrackProcessingOutput(
            transcript: TrackTranscript(id: run, trackID: second.id, segments: [
                TranscriptSegment(trackID: second.id, start: 0, end: 2, text: "Ship Friday", speakerID: "\(run):A")]),
            speakers: [Speaker(id: "\(run):A", name: "", embedding: [0.99, 0.05, 0], embeddingModelID: "voices")],
            speakerEmbeddingModelID: "voices", duration: 3)
        meeting.apply(output, matching: SpeakerMatchingConfiguration(), allowSameSource: false)
        XCTAssertEqual(meeting.speakerMatches?.count, 1)
        XCTAssertEqual(meeting.transcripts.last?.segments.first?.speakerID, "known", "The passage now belongs to Priya")
    }

    func testAWholePassTranscribesFusesAndSummarizes() async throws {
        let mic = track("mic.caf", source: .microphone), file = track("recorder.wav")
        let meeting = Meeting(title: "Standup", tracks: [mic, file])
        let engine = ScriptedEngine(lines: ["mic.caf": [(0, "A", "Morning"), (2, "B", "Ship it")], "recorder.wav": []])
        let urls = [mic, file].map { (track: $0, url: URL(fileURLWithPath: "/tmp/\($0.fileName)")) }
        let output = try await engine.process(meeting, tracks: urls, mode: .newAudio, template: nil, vocabulary: ["Daybook"])

        XCTAssertEqual(engine.calls.transcribed, ["mic.caf", "recorder.wav"])
        XCTAssertEqual(output.transcripts.count, 2)
        XCTAssertEqual(output.speakers.map(\.name), ["Speaker 1", "Speaker 2"])
        XCTAssertFalse(output.meeting.unifiedTranscript.isEmpty, "Fused into one transcript")
        XCTAssertEqual(output.summary?.overview, "\(output.meeting.unifiedTranscript.count) passages")
        XCTAssertEqual(output.meeting.summary, output.summary)
        XCTAssertEqual(output.suggestedTerms, ["Daybook"])
        XCTAssertEqual(output.notices, ["Nothing was said."])
        XCTAssertEqual(output.meeting.revisions.filter { $0.field == "summary" }.count, 1, "The new summary is in Version History")
    }

    func testNewAudioSkipsTranscribedRecordingsAndSummaryOnlyTranscribesNothing() async throws {
        let mic = track("mic.caf", source: .microphone)
        var meeting = Meeting(title: "Standup", tracks: [mic])
        meeting.transcripts = [TrackTranscript(trackID: mic.id, segments: [TranscriptSegment(trackID: mic.id, start: 0, end: 1, text: "Hi")])]
        meeting.applyFusion(SourceFusion.fuse(meeting).fusion)
        let engine = ScriptedEngine(lines: ["mic.caf": [(0, "A", "Again")]])
        let pair = [(track: mic, url: URL(fileURLWithPath: "/tmp/mic.caf"))]

        let newAudio = try await engine.process(meeting, tracks: pair, mode: .newAudio, template: nil)
        XCTAssertTrue(engine.calls.transcribed.isEmpty)
        XCTAssertNotNil(newAudio.summary)

        let summaryOnly = try await engine.process(meeting, tracks: pair, mode: .summaryOnly,
                                                   template: SummaryTemplate.builtIns.first { $0.id == "scrum" })
        XCTAssertTrue(engine.calls.transcribed.isEmpty)
        XCTAssertEqual(summaryOnly.summary?.kind, .scrum)

        _ = try await engine.process(meeting, tracks: pair, mode: .fullRetranscription, template: nil)
        XCTAssertEqual(engine.calls.transcribed, ["mic.caf"])
    }

    func testNothingSaidMeansNoSummary() async throws {
        let mic = track("mic.caf", source: .microphone)
        let engine = ScriptedEngine(lines: [:])
        let output = try await engine.process(Meeting(title: "Silence", tracks: [mic]), tracks: [(track: mic, url: URL(fileURLWithPath: "/tmp/mic.caf"))],
                                              mode: .newAudio, template: nil)
        XCTAssertNil(output.summary)
        XCTAssertTrue(engine.calls.summarized.isEmpty)
        XCTAssertEqual(output.transcripts.count, 1, "The empty run is still recorded")
    }
}
