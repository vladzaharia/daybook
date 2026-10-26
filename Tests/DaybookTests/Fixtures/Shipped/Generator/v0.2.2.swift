import DaybookCore
import DaybookDevices
import DaybookKit
import Foundation

// Writes what Daybook v0.2.2 wrote, through v0.2.2's own MeetingStore, GlossaryStore, devices, and
// model selections, and the encoders its LibraryController, AppState, and capture code used.
// Every value is synthetic and fixed. generate.sh builds this against v0.2.2's library targets and the
// capture types it copies out of that tag (OldApp.swift); see README.md.

/// v0.2.2's `ProcessingPreferences` (Sources/Daybook/App/ProcessingPreferences.swift) lives in the app
/// target, which needs MLX to build: its stored properties and coding keys, copied, so it encodes the same.
struct ProcessingPreferences: Codable {
    var speakerModelID: String
    var speakerOptions: SpeakerAnalysisOptions
    var matchSpeakersAcrossSources: Bool
    var speakerMatchThreshold: Double
    var speakerMatchMargin: Double
    var transcriptionLanguage: String?
    var otherLanguagesModelID: String?
    private enum CodingKeys: String, CodingKey {
        case speakerModelID, speakerOptions, matchSpeakersAcrossSources, speakerMatchThreshold, speakerMatchMargin
        case transcriptionLanguage, otherLanguagesModelID
    }
}

/// v0.2.2's `SpeakerAnalysisOptions` (Sources/DaybookIntelligence/SpeakerAnalysisOptions.swift, which needs FluidAudio):
/// its stored properties, copied.
struct SpeakerAnalysisOptions: Codable {
    var quality: SpeakerQuality = .balanced
    var expectedSpeakerCount: Int? = nil
}
enum SpeakerQuality: String, Codable { case fast, balanced, accurate }

func id(_ text: String) -> UUID { UUID(uuidString: text)! }
func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

@MainActor
func generate(into out: URL) async throws {
    let library = out.appendingPathComponent("Library", isDirectory: true)
    try? FileManager.default.removeItem(at: out)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)

    let meetingID = id("0B2C3D4E-0000-4000-8000-000000000001")
    let otherMeetingID = id("0B2C3D4E-0000-4000-8000-000000000002")
    let folderID = id("0B2C3D4E-0000-4000-8000-0000000000F1")
    let microphone = id("0B2C3D4E-0000-4000-8000-0000000000A1")
    let systemAudio = id("0B2C3D4E-0000-4000-8000-0000000000A2")
    let echoCancelled = id("0B2C3D4E-0000-4000-8000-0000000000A4")
    let recorder = id("0B2C3D4E-0000-4000-8000-0000000000A3")
    let phoneTrack = id("0B2C3D4E-0000-4000-8000-0000000000A5")
    let started = at(1_792_600_000)
    let mac = ProcessingRequest.Device(id: "5D6E7F80-0000-4000-8000-00000000000A", name: "Studio Mac")
    let phone = ProcessingRequest.Device(id: "5D6E7F80-0000-4000-8000-00000000000B", name: "Alex’s iPhone")

    let whisper = ModelProvenance(family: "whisper", variant: "base", revision: "0f63a7800b00dd0226abd051b906c246e1907482",
                                  engine: "whisperkit", engineVersion: "1.1.1", name: "Whisper Base", repository: "argmaxinc/whisperkit-coreml")
    let gemma = ModelProvenance(family: "gemma-4", variant: "e4b-4bit", revision: "4b1d2c3e4f5061728394a5b6c7d8e9f001122334",
                                engine: "mlx", engineVersion: "3.32.3", name: "Gemma 4 E4B · 4-bit")
    let settings = ProcessingSettings(modelID: "whisper/base", parameters: ["language": "en", "temperature": "0"],
                                      createdAt: at(1_792_600_100), model: whisper)
    let words = [TranscriptWord(text: "Let's", start: 0.5, end: 0.75, confidence: 0.91),
                 TranscriptWord(text: "review", start: 0.75, end: 1.25, confidence: 0.875),
                 TranscriptWord(text: "the", start: 1.25, end: 1.5),
                 TranscriptWord(text: "agenda.", start: 1.5, end: 2.25, confidence: 0.96875)]
    let micSegment = TranscriptSegment(id: id("0B2C3D4E-0000-4000-8000-0000000005A1"), trackID: echoCancelled, start: 0.5, end: 2.25,
                                       text: "Let's review the agenda.", speakerID: "owner", confidence: 0.9375)
    let callSegment = TranscriptSegment(id: id("0B2C3D4E-0000-4000-8000-0000000005A2"), trackID: systemAudio, start: 3, end: 6.5,
                                        text: "We ship the prototype on Friday.", speakerID: "S2", confidence: 0.875)
    let recorderSegment = TranscriptSegment(id: id("0B2C3D4E-0000-4000-8000-0000000005A3"), trackID: recorder, start: 0.25, end: 3.75,
                                            text: "We ship the prototype on Friday.", confidence: 0.8125)
    let transcripts = [
        TrackTranscript(id: id("0B2C3D4E-0000-4000-8000-0000000007A1"), trackID: echoCancelled, segments: [micSegment], language: "en",
                        modelID: "whisper/base", createdAt: at(1_792_600_100), knownOffset: 0.25, processingSettings: settings, words: words),
        TrackTranscript(id: id("0B2C3D4E-0000-4000-8000-0000000007A2"), trackID: systemAudio, segments: [callSegment], language: "en",
                        modelID: "whisper/base", createdAt: at(1_792_600_100), knownOffset: 0.5, processingSettings: settings),
        TrackTranscript(id: id("0B2C3D4E-0000-4000-8000-0000000007A3"), trackID: recorder, segments: [recorderSegment], language: "en",
                        modelID: "whisper/base", createdAt: at(1_792_600_160), processingSettings: settings)
    ]
    let unified = [
        TranscriptSegment(id: id("0B2C3D4E-0000-4000-8000-0000000009A1"), trackID: echoCancelled, start: 0.75, end: 2.5,
                          text: "Let's review the agenda.", speakerID: "owner", confidence: 0.9375,
                          provenance: [SegmentProvenance(trackID: echoCancelled, segmentID: micSegment.id, start: 0.5, end: 2.25,
                                                         text: micSegment.text, confidence: 0.9375, wordIndices: [0, 1, 2, 3])]),
        TranscriptSegment(id: id("0B2C3D4E-0000-4000-8000-0000000009A2"), trackID: systemAudio, start: 3.5, end: 7,
                          text: "We ship the prototype on Friday.", speakerID: "S2", confidence: 0.875,
                          provenance: [SegmentProvenance(trackID: systemAudio, segmentID: callSegment.id, start: 3, end: 6.5,
                                                         text: callSegment.text, confidence: 0.875),
                                       SegmentProvenance(trackID: recorder, segmentID: recorderSegment.id, start: 0.25, end: 3.75,
                                                         text: recorderSegment.text, confidence: 0.8125)])
    ]
    let summary = MeetingSummary(kind: .general, title: "Prototype planning", overview: "The team agreed to ship the prototype on Friday.",
                                 sections: [SummarySection(id: id("0B2C3D4E-0000-4000-8000-00000000000C"), heading: "Decisions",
                                                           body: "- Ship the prototype on Friday.")],
                                 actionItems: [ActionItem(id: id("0B2C3D4E-0000-4000-8000-00000000000D"), text: "Ship the prototype",
                                                          owner: "Alex", completed: true)],
                                 modelID: "gemma-4/e4b-4bit", createdAt: at(1_792_600_200),
                                 processingSettings: ProcessingSettings(modelID: "gemma-4/e4b-4bit", parameters: ["template": "general"],
                                                                        createdAt: at(1_792_600_200), model: gemma))
    var micTrack = RecordingTrack(id: microphone, source: .microphone, relativePath: "Originals/microphone.caf", fileName: "microphone.caf",
                                  createdAt: started, duration: 61.25, offset: 0.25, sha256: String(repeating: "b1", count: 32),
                                  startedAt: at(1_792_600_000.25))
    micTrack.capture = TrackCaptureDetails(method: "microphone", clockRate: 48_000.5, outputRoute: "speakers",
                                           notes: ["Switched to MacBook Pro Microphone at 12.5 s."],
                                           peerClocks: [CapturePeerClock(deviceID: phone.id, name: phone.name, deviceClass: "phone", offset: 0.375,
                                                                         uncertainty: 0.0125, sampleCount: 5, measuredAt: at(1_792_600_001),
                                                                         peerRecordingStartedAt: at(1_792_600_002))])
    var callTrack = RecordingTrack(id: systemAudio, source: .systemAudio, relativePath: "Originals/systemAudio.caf", fileName: "systemAudio.caf",
                                   createdAt: started, duration: 60.5, offset: 0.5, sha256: String(repeating: "b2", count: 32),
                                   startedAt: at(1_792_600_000.5))
    callTrack.capture = TrackCaptureDetails(method: "process-tap", capturedApps: ["us.zoom.xos"], clockRate: 48_000)
    var derivedTrack = RecordingTrack(id: echoCancelled, source: .microphone, relativePath: "Originals/microphone.echo-cancelled.caf",
                                      fileName: "microphone.echo-cancelled.caf", createdAt: at(1_792_600_062), duration: 61.25, offset: 0.25,
                                      sha256: String(repeating: "b4", count: 32), derivedFrom: microphone, processing: "echo-cancelled",
                                      startedAt: at(1_792_600_000.25))
    var echo = EchoRemovalReport(outcome: .applied)
    echo.processingSampleRate = 16_000
    echo.echoReturnLossEnhancementDB = 18.5
    echo.doubleTalkFraction = 0.125
    echo.durationSeconds = 61.25
    derivedTrack.capture = TrackCaptureDetails(method: "microphone", echoRemoval: echo)
    let recorderTrack = RecordingTrack(id: recorder, source: .soundcore, relativePath: "Originals/Soundcore-1792600000.wav",
                                       fileName: "Soundcore-1792600000.wav", createdAt: at(1_792_600_150), duration: 58.5,
                                       sha256: String(repeating: "b3", count: 32),
                                       device: DeviceRecordingIdentity(kind: "soundcore.work", serial: "D3200SIM0000001", recordingID: "1792600000"),
                                       startedAt: at(1_792_600_000),
                                       alignment: SourceAlignment(method: .audio, offset: 2.875, rate: 1.0001220703125, confidence: 0.875,
                                                                  referenceTrackID: microphone, clockOffset: 3, audioChecked: true,
                                                                  date: at(1_792_600_170)))
    let phoneRecording = RecordingTrack(id: phoneTrack, source: .imported, relativePath: "Originals/iPhone.m4a", fileName: "iPhone.m4a",
                                        createdAt: at(1_792_600_180), duration: 59, sha256: String(repeating: "b5", count: 32),
                                        device: DeviceRecordingIdentity(kind: "daybook.iphone", recordingID: "0B2C3D4E-0000-4000-8000-0000000000A6"),
                                        startedAt: at(1_792_600_001),
                                        alignment: SourceAlignment(method: .pending, clockOffset: 0.375, heldNoteIDs: [id("0B2C3D4E-0000-4000-8000-0000000000C2")],
                                                                   date: at(1_792_600_181)))
    var meeting = Meeting(
        id: meetingID, title: "Prototype planning", date: started, updatedAt: at(1_792_600_300), kind: .general,
        notes: "Agenda\nShip the prototype",
        tracks: [micTrack, callTrack, derivedTrack, recorderTrack, phoneRecording],
        transcripts: transcripts, unifiedTranscript: unified,
        alignmentReports: [TrackAlignment(trackID: echoCancelled, method: .reference, explanation: "Reference recording."),
                           TrackAlignment(trackID: systemAudio, method: .provided, offset: 0.25, explanation: "Captured together."),
                           TrackAlignment(trackID: recorder, method: .anchors, offset: 2.875, rate: 1.0001220703125, matchedAnchors: 4,
                                          residual: 0.0625, explanation: "Matched 4 phrases.")],
        summary: summary,
        revisions: [MeetingRevision(id: id("0B2C3D4E-0000-4000-8000-00000000000E"), date: at(1_792_600_250), field: "notes",
                                    oldValue: "Agenda", newValue: "Agenda\nShip the prototype")],
        highlights: [Highlight(id: id("0B2C3D4E-0000-4000-8000-0000000000B1"), time: 4.5, text: "Decision"),
                     Highlight(id: id("0B2C3D4E-0000-4000-8000-0000000000B2"), trackID: recorder, time: 1.5, text: "", duration: 5)],
        speakers: [Speaker(id: "owner", name: "Me", sourceTrackID: echoCancelled),
                   Speaker(id: "S2", name: "Alex", sourceTrackID: systemAudio, embedding: [0.125, -0.5, 0.25],
                           embeddingModelID: "community-1/offline",
                           analysisSettings: ProcessingSettings(modelID: "community-1/offline", createdAt: at(1_792_600_120)))],
        status: .ready,
        timedNotes: [TimedNote(id: id("0B2C3D4E-0000-4000-8000-0000000000C1"), text: "Agenda"),
                     TimedNote(id: id("0B2C3D4E-0000-4000-8000-0000000000C2"), time: 12.5, text: "Ship the prototype")],
        folderID: folderID, tags: ["planning", "synthetic"], templateID: "general", placement: .work)
    var companion = CompanionRecording(id: id("0B2C3D4E-0000-4000-8000-0000000000E2"), deviceID: "0B2C3D4E-0000-4000-8000-0000000000D9",
                                       deviceKind: "soundcore.work", deviceSerial: "D3200SIM0000001", deviceName: "soundcore Work",
                                       macStartedAt: started, state: .attached, startedByDaybook: true)
    companion.macEndedAt = at(1_792_600_061)
    companion.recorderStartedAt = at(1_792_600_003)
    companion.recordingID = "1792600000"
    companion.trackID = recorder
    companion.clock = CompanionClock(offset: 3, uncertainty: 0.5, samples: 2, measuredAt: at(1_792_600_000))
    meeting.companions = [companion]
    meeting.sourceSuggestions = [SourceSuggestion(id: id("0B2C3D4E-0000-4000-8000-0000000000E3"), trackID: phoneTrack,
                                                  candidateMeetingIDs: [meetingID, otherMeetingID], reason: .severalConversations,
                                                  confidence: 0.5, clockOffsets: [otherMeetingID: -1_800], createdAt: at(1_792_600_182))]
    meeting.audioAlignments = [TrackAudioAlignment(trackID: recorder, referenceTrackID: microphone, alignment: nil,
                                                   trackDigest: String(repeating: "b3", count: 32), referenceDigest: String(repeating: "b1", count: 32),
                                                   algorithmVersion: 1, measuredAt: at(1_792_600_170), explanation: "Too little shared speech.")]
    meeting.fusionSummary = FusionSummary(sources: [
        FusionSourceReport(trackID: echoCancelled, role: .microphone, transcriptID: transcripts[0].id, included: true, method: .reference,
                           offset: 0.25, rate: 1, confidence: 1, words: 4, wordsUsed: 4, wordsCorroborated: 0, wordsMerged: 0, wordsOverruled: 0),
        FusionSourceReport(trackID: recorder, role: .room, transcriptID: transcripts[2].id, included: true, method: .anchors,
                           referenceTrackID: echoCancelled, offset: 2.875, rate: 1.0001220703125, confidence: 0.875, words: 6, wordsUsed: 0,
                           wordsCorroborated: 6, wordsMerged: 6, wordsOverruled: 0, note: "Merged with the call.")
    ], words: 10, corroboratedWords: 6, disputedWords: 0, ownerSpeakerID: "owner",
       speakerMappings: [FusionSpeakerMapping(sourceSpeakerID: nil, trackID: recorder, speakerID: "S2", reason: .sharedSpeech, share: 0.875)])
    meeting.processingRequests = [ProcessingRequest(id: id("0B2C3D4E-0000-4000-8000-0000000000E4"), meetingID: meetingID, mode: .summaryOnly,
                                                    templateID: "general", requestedBy: phone, createdAt: at(1_792_600_400),
                                                    claim: ProcessingRequest.Claim(device: mac, claimedAt: at(1_792_600_410), heartbeat: at(1_792_600_420),
                                                                                   expiresAt: at(1_792_601_010), stage: .summarizing, fraction: 0.5),
                                                    outcome: ProcessingRequest.Outcome(result: .completed, device: mac, finishedAt: at(1_792_600_430)))]

    let store = try MeetingStore(rootURL: library)
    try await store.save(meeting)

    let term = GlossaryTerm(id: id("0B2C3D4E-0000-4000-8000-0000000000D1"), term: "Daybook", aliases: ["day book"],
                            definition: "The app.", approved: true, sourceMeetingIDs: [meetingID], occurrences: 3, updatedAt: at(1_792_600_050))
    try await GlossaryStore(rootURL: library).save([term])

    var metadata = LibraryMetadata()
    metadata.folders = [LibraryValue(id: folderID.uuidString, value: LibraryFolder(id: folderID, name: "Projects"), modifiedAt: at(1_792_500_000)),
                        LibraryValue(id: "0B2C3D4E-0000-4000-8000-0000000000F2", value: nil, modifiedAt: at(1_792_510_000))]
    metadata.templates = [LibraryValue(id: "custom-design-review", value: SummaryTemplate(id: "custom-design-review", name: "Design review",
                                                                                         kind: .general, instructions: "List the options and the choice.",
                                                                                         updatedAt: at(1_792_520_000)),
                                       modifiedAt: at(1_792_520_000))]
    metadata.vocabulary = [LibraryValue(id: term.id.uuidString, value: term, modifiedAt: at(1_792_600_050))]
    let owner = RecorderOwnership(kind: "soundcore.work", serial: "D3200SIM0000001", ownerID: mac.id, ownerName: mac.name, ownerClass: .mac,
                                  claimedAt: at(1_792_590_000))
    metadata.recorders = [LibraryValue(id: owner.id, value: owner, modifiedAt: at(1_792_590_000))]
    let handoff = RecorderHandoffRecord(id: id("0B2C3D4E-0000-4000-8000-0000000000E5"), kind: "soundcore.work", serial: "D3200SIM0000001",
                                        ownerID: mac.id, ownerName: mac.name, requesterID: phone.id, requesterName: phone.name,
                                        requesterClass: .phone, phase: .released,
                                        pendingImports: [.init(recordingID: "1792603600", attachTo: meetingID, isAutomatic: true)],
                                        importedRecordingIDs: ["1792600000"], recorderIsRecording: false,
                                        requestedAt: at(1_792_600_500), updatedAt: at(1_792_600_510))
    metadata.handoffs = [LibraryValue(id: handoff.id.uuidString, value: handoff, modifiedAt: at(1_792_600_510))]
    // LibraryController.persistMetadata.
    let libraryEncoder = JSONEncoder(); libraryEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try libraryEncoder.encode(metadata).write(to: library.appendingPathComponent("library.json"))

    // Capture sidecars, as RecordingController, PCMTrackWriter, and CaptureFinalizer persisted them (CaptureJSON).
    let stagingPath = "/Users/example/Library/Application Support/Daybook/Staging/\(meetingID.uuidString)"
    let manifest = CaptureSessionManifest(id: id("0B2C3D4E-0000-4000-8000-0000000000E1"), startedAt: started, hostTimeSeconds: 91_234.5,
                                          includeSystemAudio: true,
                                          callApp: CallAppTarget(bundleID: "us.zoom.xos", displayName: "zoom.us", isBrowser: false))
    let micCapture = CapturedAudioTrack(role: .microphone, url: URL(fileURLWithPath: stagingPath + "/microphone.caf"),
                                        startedAt: at(1_792_600_000.25), firstSampleHostTimeSeconds: 91_234.75, offsetSeconds: 0.25,
                                        sampleRate: 48_000, channelCount: 1, frameCount: 2_940_000,
                                        clockAnchors: [ClockAnchor(frame: 0, hostTime: 91_234.75), ClockAnchor(frame: 48_000, hostTime: 91_235.75),
                                                       ClockAnchor(frame: 96_000, hostTime: 91_236.875, resync: true)],
                                        method: "microphone", notes: ["Switched to MacBook Pro Microphone at 12.5 s."])
    let callCapture = CapturedAudioTrack(role: .systemAudio, url: URL(fileURLWithPath: stagingPath + "/systemAudio.caf"),
                                         startedAt: at(1_792_600_000.5), firstSampleHostTimeSeconds: 91_235, offsetSeconds: 0.5,
                                         sampleRate: 48_000, channelCount: 2, frameCount: 2_904_000,
                                         clockAnchors: [ClockAnchor(frame: 0, hostTime: 91_235)], method: "process-tap")
    let result = CaptureResult(id: manifest.id, startedAt: started, endedAt: at(1_792_600_061.5), tracks: [micCapture, callCapture],
                               warnings: ["No system audio was received for the first second."],
                               directory: URL(fileURLWithPath: stagingPath, isDirectory: true),
                               systemAudio: SystemAudioCaptureInfo(method: .processTap, capturedApps: ["us.zoom.xos"]),
                               outputRoutes: [AudioRouteEvent(time: 0, route: AudioOutputRoute(kind: .speakers, deviceName: "MacBook Pro Speakers",
                                                                                               transport: "built-in")),
                                              AudioRouteEvent(time: 30.5, route: AudioOutputRoute(kind: .headphones, deviceName: "AirPods Pro",
                                                                                                  transport: "bluetooth"))],
                               echoRemoval: echo,
                               derivedTracks: [DerivedCaptureTrack(url: URL(fileURLWithPath: stagingPath + "/microphone.echo-cancelled.caf"),
                                                                   derivedFrom: .microphone, processing: "echo-cancelled", offsetSeconds: 0.25,
                                                                   startedAt: at(1_792_600_000.25), sampleRate: 16_000, frameCount: 980_000)])
    let capture = out.appendingPathComponent("Capture", isDirectory: true)
    try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
    let captureEncoder = CaptureJSON.encoder()
    try captureEncoder.encode(manifest).write(to: capture.appendingPathComponent("capture-session.json"))
    try captureEncoder.encode(micCapture).write(to: capture.appendingPathComponent("microphone.json"))
    try captureEncoder.encode(callCapture).write(to: capture.appendingPathComponent("systemAudio.json"))
    try captureEncoder.encode(result).write(to: capture.appendingPathComponent("capture-result.json"))

    // UserDefaults, through v0.2.2's own code where it is in the package: model selections (AppState),
    // processing preferences, and configured devices with each method's storage (DeviceHub, DeviceStorage).
    let suite = "local.daybook.fixtures.v0.2.2.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let selections = ModelSelections([.transcription: "parakeet/ultra", .diarization: "community-1/offline",
                                      .speakerEmbedding: "community-1/offline", .summarization: "gemma-4/e4b-4bit",
                                      .smallTasks: "apple-foundation-models/system"])
    defaults.set(try JSONEncoder().encode(selections), forKey: "modelSelections")
    defaults.set(true, forKey: "modelSelections.smallTasksAdded")
    let preferences = ProcessingPreferences(speakerModelID: "community-1/offline",
                                            speakerOptions: SpeakerAnalysisOptions(quality: .accurate, expectedSpeakerCount: 3),
                                            matchSpeakersAcrossSources: false, speakerMatchThreshold: 0.875, speakerMatchMargin: 0.0625,
                                            transcriptionLanguage: "de", otherLanguagesModelID: "whisper/small")
    defaults.set(try JSONEncoder().encode(preferences), forKey: "processingPreferences")
    defaults.set(false, forKey: "includeComputerAudio")
    defaults.set(1.25, forKey: "readingScale")

    let environment = DeviceEnvironment(defaults: defaults, stagingDirectory: out.appendingPathComponent("DeviceImports"))
    var soundcore = ConfiguredDevice(id: "0B2C3D4E-0000-4000-8000-0000000000D9", kind: SoundcoreWorkIntegration().kind,
                                     name: "Desk recorder", addedAt: at(1_792_400_000))
    soundcore.importsAutomatically = false
    soundcore.alsoRecordsWithMac = false
    soundcore.disabledMethods = [.files]
    var snapshot = SoundcoreSnapshot(deviceID: id("0B2C3D4E-0000-4000-8000-0000000000DA"), name: "soundcore Work", serial: "D3200SIM0000001",
                                     info: SoundcoreDeviceInfo(microphoneBattery: 80, caseBattery: 60, caseCharging: true, firmware: "2.1.4",
                                                               caseFirmware: "1.0.9", serial: "D3200SIM0000001", totalBytes: 7_200_000_000,
                                                               freeBytes: 6_100_000_000),
                                     statusUpdatedAt: at(1_792_600_600), lastConnectedAt: at(1_792_600_600),
                                     recordings: [SoundcoreRecording(id: 1_792_600_000, size: 468_000, endTimestamp: 1_792_600_058),
                                                  SoundcoreRecording(id: 1_792_603_600, size: 160_000)],
                                     recordingsUpdatedAt: at(1_792_600_600))
    snapshot.lastConnectedAt = at(1_792_600_600)
    environment.storage(for: soundcore, method: .direct).encode(snapshot, "recorder")
    var folder = ConfiguredDevice(id: "0B2C3D4E-0000-4000-8000-0000000000DB", kind: OtherRecorderIntegration().kind, addedAt: at(1_792_410_000))
    folder.automaticImportsSince = at(1_792_420_000)
    let files = environment.storage(for: folder, method: .files)
    // The folder's security-scoped bookmark is machine-specific and left out; tests make their own.
    files.set(["file:2026-10-20 Planning.m4a|482113", "file:notes.m4a|20480"], "completed")
    files.set(at(1_792_500_150), "lastImport")
    let iPhone = ConfiguredDevice(id: "5D6E7F80-0000-4000-8000-00000000000B", kind: DaybookPhoneIntegration().kind, name: "Alex’s iPhone",
                                  addedAt: at(1_792_430_000))
    defaults.set(try JSONEncoder().encode([soundcore, folder, iPhone]), forKey: DeviceHub.storageKey)

    let domain = defaults.persistentDomain(forName: suite) ?? [:]
    try PropertyListSerialization.data(fromPropertyList: domain, format: .xml, options: 0)
        .write(to: out.appendingPathComponent("defaults.plist"))
}

try await generate(into: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
print("Wrote \(CommandLine.arguments[1])")
