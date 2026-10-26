import Foundation
import OldCore

// Writes what Daybook v0.1.0-preview wrote, through its own MeetingStore and GlossaryStore and the
// encoders its AppState and RecordingController used. Every value is synthetic and fixed.
// generate.sh builds this against v0.1.0-preview's DaybookCore ("OldCore") and the app types it
// copies out of that tag (OldApp.swift); see README.md.
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let library = out.appendingPathComponent("Library", isDirectory: true)
try? FileManager.default.removeItem(at: out)
try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)

func id(_ text: String) -> UUID { UUID(uuidString: text)! }
func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

let meetingID = id("0A1B2C3D-0000-4000-8000-000000000001")
let folderID = id("0A1B2C3D-0000-4000-8000-0000000000F1")
let microphone = id("0A1B2C3D-0000-4000-8000-0000000000A1")
let systemAudio = id("0A1B2C3D-0000-4000-8000-0000000000A2")
let recorder = id("0A1B2C3D-0000-4000-8000-0000000000A3")
let started = at(1_792_500_000)

let settings = ProcessingSettings(modelID: "whisper-base", parameters: ["language": "en", "temperature": "0"], createdAt: at(1_792_500_100))
let words = [TranscriptWord(text: "Let's", start: 0.5, end: 0.75, confidence: 0.91),
             TranscriptWord(text: "review", start: 0.75, end: 1.25, confidence: 0.875),
             TranscriptWord(text: "the", start: 1.25, end: 1.5),
             TranscriptWord(text: "agenda.", start: 1.5, end: 2.25, confidence: 0.96875)]
let micSegment = TranscriptSegment(id: id("0A1B2C3D-0000-4000-8000-0000000005A1"), trackID: microphone, start: 0.5, end: 2.25,
                                   text: "Let's review the agenda.", speakerID: "S1", confidence: 0.9375)
let callSegment = TranscriptSegment(id: id("0A1B2C3D-0000-4000-8000-0000000005A2"), trackID: systemAudio, start: 3, end: 6.5,
                                    text: "We ship the prototype on Friday.", speakerID: "S2", confidence: 0.875)
let recorderSegment = TranscriptSegment(id: id("0A1B2C3D-0000-4000-8000-0000000005A3"), trackID: recorder, start: 0.25, end: 3.75,
                                        text: "We ship the prototype on Friday.", confidence: 0.8125)
let transcripts = [
    TrackTranscript(id: id("0A1B2C3D-0000-4000-8000-0000000007A1"), trackID: microphone, segments: [micSegment], language: "en",
                    modelID: "whisper-base", createdAt: at(1_792_500_100), knownOffset: 0, processingSettings: settings, words: words),
    TrackTranscript(id: id("0A1B2C3D-0000-4000-8000-0000000007A2"), trackID: systemAudio, segments: [callSegment], language: "en",
                    modelID: "whisper-base", createdAt: at(1_792_500_100), knownOffset: 0.125, processingSettings: settings),
    TrackTranscript(id: id("0A1B2C3D-0000-4000-8000-0000000007A3"), trackID: recorder, segments: [recorderSegment], language: "en",
                    modelID: "whisper-base", createdAt: at(1_792_500_160))
]
let unified = [
    TranscriptSegment(id: id("0A1B2C3D-0000-4000-8000-0000000009A1"), trackID: microphone, start: 0.5, end: 2.25,
                      text: "Let's review the agenda.", speakerID: "S1", confidence: 0.9375,
                      provenance: [SegmentProvenance(trackID: microphone, segmentID: micSegment.id, start: 0.5, end: 2.25,
                                                     text: micSegment.text, confidence: 0.9375)]),
    TranscriptSegment(id: id("0A1B2C3D-0000-4000-8000-0000000009A2"), trackID: systemAudio, start: 3.125, end: 6.625,
                      text: "We ship the prototype on Friday.", speakerID: "S2", confidence: 0.875,
                      provenance: [SegmentProvenance(trackID: systemAudio, segmentID: callSegment.id, start: 3, end: 6.5,
                                                     text: callSegment.text, confidence: 0.875),
                                   SegmentProvenance(trackID: recorder, segmentID: recorderSegment.id, start: 0.25, end: 3.75,
                                                     text: recorderSegment.text, confidence: 0.8125)])
]
let summarySettings = ProcessingSettings(modelID: "qwen-7b", parameters: ["template": "general"], createdAt: at(1_792_500_200))
let summary = MeetingSummary(kind: .general, title: "Prototype planning", overview: "The team agreed to ship the prototype on Friday.",
                             sections: [SummarySection(id: id("0A1B2C3D-0000-4000-8000-00000000000C"), heading: "Decisions",
                                                       body: "- Ship the prototype on Friday.")],
                             actionItems: [ActionItem(id: id("0A1B2C3D-0000-4000-8000-00000000000D"), text: "Ship the prototype",
                                                      owner: "Alex", completed: true)],
                             modelID: "qwen-7b", createdAt: at(1_792_500_200), processingSettings: summarySettings)
let meeting = Meeting(
    id: meetingID, title: "Prototype planning", date: started, updatedAt: at(1_792_500_300), kind: .general,
    notes: "Agenda\nShip the prototype",
    tracks: [
        RecordingTrack(id: microphone, source: .microphone, relativePath: "Originals/microphone.caf", fileName: "microphone.caf",
                       createdAt: started, duration: 61.25, offset: 0, sha256: String(repeating: "a1", count: 32)),
        RecordingTrack(id: systemAudio, source: .systemAudio, relativePath: "Originals/systemAudio.caf", fileName: "systemAudio.caf",
                       createdAt: started, duration: 60.5, offset: 0.125, sha256: String(repeating: "a2", count: 32)),
        RecordingTrack(id: recorder, source: .soundcore, relativePath: "Originals/2026-10-20 Planning.m4a", fileName: "2026-10-20 Planning.m4a",
                       createdAt: at(1_792_500_150), duration: 58.5, sha256: String(repeating: "a3", count: 32))
    ],
    transcripts: transcripts, unifiedTranscript: unified,
    alignmentReports: [TrackAlignment(trackID: microphone, method: .reference, explanation: "Reference recording."),
                       TrackAlignment(trackID: systemAudio, method: .provided, offset: 0.125, explanation: "Captured together."),
                       TrackAlignment(trackID: recorder, method: .anchors, offset: 2.875, rate: 1.0001220703125, matchedAnchors: 4,
                                      residual: 0.0625, explanation: "Matched 4 phrases.")],
    summary: summary,
    revisions: [MeetingRevision(id: id("0A1B2C3D-0000-4000-8000-00000000000E"), date: at(1_792_500_250), field: "notes",
                                oldValue: "Agenda", newValue: "Agenda\nShip the prototype")],
    highlights: [Highlight(id: id("0A1B2C3D-0000-4000-8000-0000000000B1"), time: 4.5, text: "Decision"),
                 Highlight(id: id("0A1B2C3D-0000-4000-8000-0000000000B2"), trackID: recorder, time: 1.5, text: "", duration: 5)],
    speakers: [Speaker(id: "S1", name: "Alex", sourceTrackID: microphone, embedding: [0.125, -0.5, 0.25],
                       embeddingModelID: "fluid-community1-embedding-df2625ac79a7ac6b",
                       analysisSettings: ProcessingSettings(modelID: "speaker-community-1", createdAt: at(1_792_500_120))),
               Speaker(id: "S2", name: "Speaker 2", sourceTrackID: systemAudio)],
    status: .ready,
    speakerMatches: [SpeakerMatch(sourceSpeakerID: "S2", candidateSpeakerID: "S1", similarity: 0.5, runnerUpSimilarity: 0.25,
                                  status: .belowThreshold, reason: "Below the similarity threshold.", createdAt: at(1_792_500_130))],
    timedNotes: [TimedNote(id: id("0A1B2C3D-0000-4000-8000-0000000000C1"), text: "Agenda"),
                 TimedNote(id: id("0A1B2C3D-0000-4000-8000-0000000000C2"), time: 12.5, text: "Ship the prototype")],
    folderID: folderID, tags: ["planning", "synthetic"], templateID: "general")

let store = try MeetingStore(rootURL: library)
try await store.save(meeting)

let term = GlossaryTerm(id: id("0A1B2C3D-0000-4000-8000-0000000000D1"), term: "Daybook", aliases: ["day book"],
                        definition: "The app.", approved: true, sourceMeetingIDs: [meetingID], occurrences: 3, updatedAt: at(1_792_500_050))
try await GlossaryStore(rootURL: library).save([term])

var metadata = LibraryMetadata()
metadata.folders = [LibraryValue(id: folderID.uuidString, value: LibraryFolder(id: folderID, name: "Projects"), modifiedAt: at(1_792_400_000)),
                    LibraryValue(id: "0A1B2C3D-0000-4000-8000-0000000000F2", value: nil, modifiedAt: at(1_792_410_000))]
metadata.templates = [LibraryValue(id: "custom-design-review", value: SummaryTemplate(id: "custom-design-review", name: "Design review",
                                                                                     kind: .general, instructions: "List the options and the choice.",
                                                                                     updatedAt: at(1_792_420_000)),
                                   modifiedAt: at(1_792_420_000))]
metadata.vocabulary = [LibraryValue(id: term.id.uuidString, value: term, modifiedAt: at(1_792_500_050))]
// AppState.persistLibraryMetadata.
let libraryEncoder = JSONEncoder(); libraryEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try libraryEncoder.encode(metadata).write(to: library.appendingPathComponent("library.json"))

// RecordingController.persist and PCMTrackWriter.persistTrack, for a recording in
// <library>/Staging/<conversation>/. URLs are absolute, as the app wrote them.
let captureEncoder = JSONEncoder()
captureEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
captureEncoder.dateEncodingStrategy = .millisecondsSince1970
let stagingPath = "/Users/example/Library/Application Support/Daybook/Staging/\(meetingID.uuidString)"
let manifest = CaptureSessionManifest(id: id("0A1B2C3D-0000-4000-8000-0000000000E1"), startedAt: started, hostTimeSeconds: 81_234.5,
                                      includeSystemAudio: true)
let micTrack = CapturedAudioTrack(role: .microphone, url: URL(fileURLWithPath: stagingPath + "/microphone.caf"),
                                  startedAt: at(1_792_500_000.25), firstSampleHostTimeSeconds: 81_234.75, offsetSeconds: 0.25,
                                  sampleRate: 48_000, channelCount: 1, frameCount: 2_940_000)
let callTrack = CapturedAudioTrack(role: .systemAudio, url: URL(fileURLWithPath: stagingPath + "/systemAudio.caf"),
                                   startedAt: at(1_792_500_000.5), firstSampleHostTimeSeconds: 81_235, offsetSeconds: 0.5,
                                   sampleRate: 48_000, channelCount: 2, frameCount: 2_904_000)
let result = CaptureResult(id: manifest.id, startedAt: started, endedAt: at(1_792_500_061.5), tracks: [micTrack, callTrack],
                           warnings: ["No system audio was received for the first second."], directory: URL(fileURLWithPath: stagingPath, isDirectory: true))
let capture = out.appendingPathComponent("Capture", isDirectory: true)
try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
try captureEncoder.encode(manifest).write(to: capture.appendingPathComponent("capture-session.json"))
try captureEncoder.encode(micTrack).write(to: capture.appendingPathComponent("microphone.json"))
try captureEncoder.encode(callTrack).write(to: capture.appendingPathComponent("systemAudio.json"))
try captureEncoder.encode(result).write(to: capture.appendingPathComponent("capture-result.json"))

// UserDefaults: AppState's model choices and processing preferences, and ImportFolderWatcher's
// completed files ("path|size|mtime"). The folder's security-scoped bookmark is machine-specific
// and left out; tests make their own.
let preferences = ProcessingPreferences(speakerModelID: "speaker-sortformer-v2.1",
                                        speakerOptions: SpeakerAnalysisOptions(quality: .accurate, expectedSpeakerCount: 3),
                                        matchSpeakersAcrossSources: false, speakerMatchThreshold: 0.875, speakerMatchMargin: 0.0625)
let fingerprint = "/Users/example/Recordings/Soundcore/2026-10-20 Planning.m4a|482113|\(TimeInterval(1_792_500_150))"
let defaults: [String: Any] = [
    "transcriptionModel": "whisper-small",
    "summaryModel": "qwen-3b",
    "processingPreferences": try JSONEncoder().encode(preferences.normalized),
    "automaticRecording": true,
    "includeComputerAudio": false,
    "processSyncedAudio": false,
    "detectSpeakers": true,
    "importedFileFingerprints": [fingerprint]
]
try PropertyListSerialization.data(fromPropertyList: defaults, format: .xml, options: 0)
    .write(to: out.appendingPathComponent("defaults.plist"))
print("Wrote \(out.path)")
