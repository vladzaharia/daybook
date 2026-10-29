import DaybookTestSupport
import XCTest
@testable import DaybookCore

/// Speaker profiles across conversations: names teach profiles, profiles label other conversations
/// (including ones processed before the profile existed), confident labels teach profiles within
/// limits, and the person's names always win. Synthetic embeddings only; no models.
final class SpeakerProfileTests: XCTestCase {
    static let space = "fluid-community1-embedding-df2625ac79a7ac6b"
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let day: TimeInterval = 86_400

    // MARK: Fixtures

    struct Voice {
        var id: String
        var vector: [Float]?
        var seconds: Double
        var space = SpeakerProfileTests.space
    }

    func voice(_ id: String, _ vector: [Float]?, _ seconds: Double = 120) -> Voice { Voice(id: id, vector: vector, seconds: seconds) }

    /// One recording, its speakers talking in turn ("<title>:<voice>"), each named "Speaker n".
    func meeting(_ title: String, daysAgo: Double, _ voices: [Voice], source: AudioSource = .microphone,
                 device: DeviceRecordingIdentity? = nil) -> Meeting {
        let track = RecordingTrack(source: source, relativePath: "\(title).m4a", fileName: "\(title).m4a", device: device)
        var segments: [TranscriptSegment] = [], speakers: [Speaker] = []
        var time = 0.0
        for (index, voice) in voices.enumerated() {
            let id = "\(title):\(voice.id)"
            segments.append(TranscriptSegment(trackID: track.id, start: time, end: time + voice.seconds, text: "Words", speakerID: id))
            time += voice.seconds
            speakers.append(Speaker(id: id, name: "Speaker \(index + 1)", sourceTrackID: track.id, embedding: voice.vector,
                                    embeddingModelID: voice.vector == nil ? nil : voice.space))
        }
        return Meeting(title: title, date: now.addingTimeInterval(-daysAgo * day), tracks: [track],
                       transcripts: [TrackTranscript(trackID: track.id, segments: segments)], speakers: speakers)
    }

    @discardableResult
    func reconcile(_ meetings: inout [Meeting], _ metadata: inout LibraryMetadata, options: SpeakerProfileOptions = .init(),
                   at time: Date? = nil, file: StaticString = #filePath, line: UInt = #line) -> SpeakerProfileReconciliation {
        let base = SpeakerProfileState(metadata)
        let result = SpeakerProfileReconciler.reconcile(meetings: meetings, state: base, options: options, now: time ?? now)
        XCTAssertTrue(metadata.apply(result, base: base), file: file, line: line)
        for index in meetings.indices { XCTAssertTrue(meetings[index].apply(result.speakers), file: file, line: line) }
        return result
    }

    /// Reconciles until nothing changes, as the Mac does after each change.
    func settle(_ meetings: inout [Meeting], _ metadata: inout LibraryMetadata, options: SpeakerProfileOptions = .init(),
                file: StaticString = #filePath, line: UInt = #line) {
        for round in 0..<6 {
            if reconcile(&meetings, &metadata, options: options, at: now.addingTimeInterval(Double(round)), file: file, line: line).isEmpty { return }
        }
        XCTFail("Reconciling didn't settle", file: file, line: line)
    }

    func name(_ meeting: Meeting, _ speakerID: String) -> String? { meeting.speakers.first { $0.id == speakerID }?.name }

    func activePrints(_ metadata: LibraryMetadata) -> [Voiceprint] { (metadata.voiceprints ?? []).compactMap(\.value) }

    func profile(_ name: String, _ metadata: LibraryMetadata) throws -> SpeakerProfile {
        try XCTUnwrap(metadata.activeSpeakerProfiles.first { $0.name == name }, "No profile named \(name)")
    }

    let me = SyntheticVoice.person(1), guest = SyntheticVoice.person(2), other = SyntheticVoice.person(3)
    func mine(_ seed: UInt64, _ similarity: Double = 0.95) -> [Float] { SyntheticVoice.near(me, similarity: similarity, seed: seed) }

    // MARK: Across conversations (the reported problem)

    /// Regression: naming yourself in one conversation labelled only that one. Matching compared
    /// voices within a conversation; nothing carried a name to others, before or after.
    func testANameTeachesAProfileThatLabelsTheSameVoiceInEveryOtherConversation() throws {
        var meetings = [
            meeting("one", daysAgo: 30, [voice("me", mine(1)), voice("guest", SyntheticVoice.near(guest, similarity: 0.95, seed: 2), 90)]),
            meeting("two", daysAgo: 20, [voice("me", mine(3), 200), voice("other", SyntheticVoice.near(other, similarity: 0.95, seed: 4), 60)]),
            meeting("three", daysAgo: 10, [voice("other", SyntheticVoice.near(other, similarity: 0.95, seed: 5), 80), voice("me", mine(6), 150)])
        ]
        var metadata = LibraryMetadata()
        XCTAssertTrue(reconcile(&meetings, &metadata).isEmpty, "No names, no profiles: nothing changes")

        // All three were processed before the profile existed.
        meetings[0].renameSpeaker(id: "one:me", name: "Vlad")
        settle(&meetings, &metadata)

        let vlad = try profile("Vlad", metadata)
        XCTAssertEqual(metadata.activeSpeakerProfiles.count, 1)
        XCTAssertEqual(meetings[0].speakerIdentity("one:me")?.source, .named)
        XCTAssertEqual(meetings[0].speakerIdentity("one:me")?.profileID, vlad.id)
        for (index, id) in [(1, "two:me"), (2, "three:me")] {
            XCTAssertEqual(name(meetings[index], id), "Vlad")
            XCTAssertEqual(meetings[index].speakerIdentity(id)?.source, .recognized)
            XCTAssertEqual(meetings[index].speakerIdentity(id)?.profileID, vlad.id)
            XCTAssertEqual(meetings[index].speakerIdentity(id)?.previousName.map(SpeakerProfile.isPlaceholder), true)
        }
        XCTAssertEqual(name(meetings[1], "two:other"), "Speaker 2")
        XCTAssertNil(meetings[1].speakerIdentity("two:other"))
        XCTAssertNil(meetings[0].speakerIdentity("one:guest"))
        let named = activePrints(metadata).filter { $0.origin == .named }
        XCTAssertEqual(named.count, 1)
        XCTAssertEqual(named.first?.meetingID, meetings[0].id)
        XCTAssertEqual(named.first?.vector.space, Self.space)
    }

    /// The default presets: Nemotron 3's speakers get Community-1 voice profiles in the same space as
    /// Community-1's own, so either kind of run matches the other; another space never does.
    func testSpeakersFromNemotronAndCommunityOneRunsMatchAndOtherSpacesNever() throws {
        var community = meeting("community", daysAgo: 3, [voice("me", mine(11))])
        community.speakers[0].analysisSettings = ProcessingSettings(modelID: "community-1/offline")
        var nemotron = meeting("nemotron", daysAgo: 2, [voice("me", mine(12))])
        nemotron.speakers[0].analysisSettings = ProcessingSettings(modelID: "nemotron-3-diarization/offline",
                                                                   parameters: ["voiceEmbeddingModel": "community-1/offline"])
        var foreign = meeting("foreign", daysAgo: 1, [Voice(id: "me", vector: mine(13), seconds: 120, space: "another-model-space")])
        community.renameSpeaker(id: "community:me", name: "Vlad")
        var meetings = [community, nemotron, foreign], metadata = LibraryMetadata()
        settle(&meetings, &metadata)
        XCTAssertEqual(name(meetings[1], "nemotron:me"), "Vlad")
        XCTAssertEqual(meetings[1].speakerIdentity("nemotron:me")?.source, .recognized)
        XCTAssertEqual(name(meetings[2], "foreign:me"), "Speaker 1")
        XCTAssertNil(meetings[2].speakerIdentity("foreign:me"))

        // And the other way round: named in a Nemotron run, recognized in a Community-1 one.
        nemotron = meeting("nemotron", daysAgo: 2, [voice("me", mine(12))])
        nemotron.renameSpeaker(id: "nemotron:me", name: "Vlad")
        meetings = [meeting("community", daysAgo: 3, [voice("me", mine(11))]), nemotron]
        metadata = LibraryMetadata()
        settle(&meetings, &metadata)
        XCTAssertEqual(name(meetings[0], "community:me"), "Vlad")
    }

    /// The microphone's owner in a fused conversation ("Me") has no embedding of its own; it's
    /// recognized and named through the microphone's speaker it stands for.
    func testTheFusedOwnerIsLabelledAndTaughtThroughItsMicrophoneSpeaker() throws {
        func fused(_ title: String, daysAgo: Double, seed: UInt64) -> Meeting {
            var value = meeting(title, daysAgo: daysAgo, [voice("mic", mine(seed), 300)])
            value.speakers.append(Speaker(id: "owner", name: "Me", sourceTrackID: value.tracks[0].id))
            value.fusionSummary = FusionSummary(sources: [], words: 100, corroboratedWords: 0, disputedWords: 0, ownerSpeakerID: "owner",
                                                speakerMappings: [FusionSpeakerMapping(sourceSpeakerID: "\(title):mic", trackID: value.tracks[0].id,
                                                                                       speakerID: "owner", reason: .owner, share: 0.9)])
            return value
        }
        var first = fused("first", daysAgo: 5, seed: 21)
        first.renameSpeaker(id: "owner", name: "Vlad")
        var meetings = [first, fused("second", daysAgo: 1, seed: 22)], metadata = LibraryMetadata()
        settle(&meetings, &metadata)
        let named = try XCTUnwrap(activePrints(metadata).first { $0.origin == .named })
        XCTAssertEqual(named.speakerID, "first:mic", "The owner's voiceprint is its microphone speaker's")
        XCTAssertEqual(name(meetings[1], "owner"), "Vlad", "Fusion's default \"Me\" gives way to the profile")
        XCTAssertEqual(meetings[1].speakerIdentity("owner")?.previousName, "Me")
        XCTAssertEqual(meetings[1].speakerIdentity("owner")?.source, .recognized)
        // One voice twice (the owner and its microphone speaker) is no conflict.
        XCTAssertEqual(meetings[1].speakerIdentity("second:mic")?.source, .recognized)
    }

    // MARK: The person's names win

    func testRecognitionNeverReplacesANameThePersonGaveOrOneItDidntGive() throws {
        var one = meeting("one", daysAgo: 9, [voice("me", mine(31))])
        one.renameSpeaker(id: "one:me", name: "Vlad")
        var two = meeting("two", daysAgo: 5, [voice("me", mine(32))])
        two.renameSpeaker(id: "two:me", name: "Vladimir")
        // A name that came with the recording (moved from another conversation), with no rename here.
        var three = meeting("three", daysAgo: 1, [voice("me", mine(33))])
        three.speakers[0].name = "Alice"
        var meetings = [one, two, three], metadata = LibraryMetadata()
        settle(&meetings, &metadata)
        XCTAssertEqual(name(meetings[0], "one:me"), "Vlad")
        XCTAssertEqual(name(meetings[1], "two:me"), "Vladimir")
        XCTAssertEqual(meetings[1].speakerIdentity("two:me")?.source, .named)
        XCTAssertEqual(name(meetings[2], "three:me"), "Alice")
        XCTAssertEqual(meetings[2].speakerIdentity("three:me")?.source, .suggested, "Two profiles of one voice: too close to call")
    }

    func testLooseShortOrAmbiguousMatchesAreOnlySuggested() throws {
        var named = meeting("named", daysAgo: 10, [voice("me", mine(41))])
        named.renameSpeaker(id: "named:me", name: "Vlad")
        let print = try XCTUnwrap(named.speakers[0].embedding)
        var meetings = [
            named,
            meeting("loose", daysAgo: 3, [voice("a", SyntheticVoice.near(print, similarity: 0.75, seed: 42))]),
            meeting("short", daysAgo: 2, [voice("a", SyntheticVoice.near(print, similarity: 0.95, seed: 43), 3)]),
            meeting("far", daysAgo: 1, [voice("a", SyntheticVoice.near(print, similarity: 0.6, seed: 44))])
        ]
        var metadata = LibraryMetadata()
        settle(&meetings, &metadata)
        XCTAssertEqual(meetings[1].speakerIdentity("loose:a")?.source, .suggested)
        XCTAssertEqual(name(meetings[1], "loose:a"), "Speaker 1")
        XCTAssertEqual(meetings[2].speakerIdentity("short:a")?.source, .suggested, "Three seconds is too little to label")
        XCTAssertEqual(name(meetings[2], "short:a"), "Speaker 1")
        XCTAssertNil(meetings[3].speakerIdentity("far:a"))

        // Two profiles whose voices are close: the better is suggested, never labelled.
        var alex = meeting("alex", daysAgo: 9, [voice("x", SyntheticVoice.near(print, similarity: 0.9, seed: 45))])
        alex.renameSpeaker(id: "alex:x", name: "Alex")
        let between = SyntheticVoice.near(SyntheticVoice.between(print, try XCTUnwrap(alex.speakers[0].embedding)), similarity: 0.995, seed: 46)
        meetings = [named, alex, meeting("between", daysAgo: 1, [voice("a", between)])]
        metadata = LibraryMetadata()
        settle(&meetings, &metadata)
        XCTAssertEqual(meetings[2].speakerIdentity("between:a")?.source, .suggested)
        XCTAssertEqual(name(meetings[2], "between:a"), "Speaker 1")
    }

    func testTwoVoicesInOneRecordingAreNeverBothLabelledThePerson() throws {
        var named = meeting("named", daysAgo: 10, [voice("me", mine(51))])
        named.renameSpeaker(id: "named:me", name: "Vlad")
        let print = try XCTUnwrap(named.speakers[0].embedding)
        func split(_ a: Double, _ b: Double) -> Meeting {
            meeting("split", daysAgo: 1, [voice("a", SyntheticVoice.near(print, similarity: a, seed: 52), 10),
                                          voice("b", SyntheticVoice.near(print, similarity: b, seed: 53), 10)])
        }
        var meetings = [named, split(0.95, 0.84)], metadata = LibraryMetadata()
        settle(&meetings, &metadata)
        XCTAssertEqual(meetings[1].speakerIdentity("split:a")?.source, .recognized, "Clearly closer: keeps the label")
        XCTAssertEqual(meetings[1].speakerIdentity("split:b")?.source, .suggested)
        XCTAssertEqual(name(meetings[1], "split:b"), "Speaker 2")

        meetings = [named, split(0.9, 0.88)]
        metadata = LibraryMetadata()
        settle(&meetings, &metadata)
        XCTAssertEqual(meetings[1].speakerIdentity("split:a")?.source, .suggested)
        XCTAssertEqual(meetings[1].speakerIdentity("split:b")?.source, .suggested)
    }

    // MARK: Taking a label back

    func testRenamingALabelledSpeakerRejectsTheProfileAndItForgetsThatVoice() throws {
        var one = meeting("one", daysAgo: 9, [voice("me", mine(61))])
        one.renameSpeaker(id: "one:me", name: "Vlad")
        var meetings = [one, meeting("two", daysAgo: 1, [voice("me", mine(62), 300)])], metadata = LibraryMetadata()
        settle(&meetings, &metadata)
        let vlad = try profile("Vlad", metadata)
        XCTAssertEqual(name(meetings[1], "two:me"), "Vlad")
        XCTAssertTrue(activePrints(metadata).contains { $0.origin == .recognized && $0.meetingID == meetings[1].id }, "Learned from a confident label")

        // The person says it's someone else.
        meetings[1].renameSpeaker(id: "two:me", name: "Bob")
        settle(&meetings, &metadata)
        let identity = try XCTUnwrap(meetings[1].speakerIdentity("two:me"))
        XCTAssertEqual(identity.source, .named)
        XCTAssertEqual(identity.rejectedProfileIDs, [vlad.id])
        XCTAssertEqual(name(meetings[1], "two:me"), "Bob")
        XCTAssertFalse(activePrints(metadata).contains { $0.profileID == vlad.id && $0.meetingID == meetings[1].id },
                       "Vlad forgets the voice it learned there")

        // Back to a placeholder: no profile, and Vlad isn't offered again.
        meetings[1].renameSpeaker(id: "two:me", name: "Speaker 1")
        settle(&meetings, &metadata)
        XCTAssertEqual(name(meetings[1], "two:me"), "Speaker 1")
        XCTAssertEqual(meetings[1].speakerIdentity("two:me")?.source, .dismissed)
        XCTAssertTrue(meetings[1].speakerIdentity("two:me")?.rejectedProfileIDs?.contains(vlad.id) == true)
        let bob = try profile("Bob", metadata)
        XCTAssertFalse(activePrints(metadata).contains { $0.profileID == bob.id && $0.meetingID == meetings[1].id && $0.origin == .named })
    }

    func testDeletedProfilesTakeTheirLabelsOffAndPutTheEarlierNamesBack() throws {
        var one = meeting("one", daysAgo: 9, [voice("me", mine(71))])
        one.renameSpeaker(id: "one:me", name: "Vlad")
        var meetings = [one, meeting("two", daysAgo: 1, [voice("me", mine(72))])], metadata = LibraryMetadata()
        settle(&meetings, &metadata)
        XCTAssertEqual(name(meetings[1], "two:me"), "Vlad")
        let vlad = try profile("Vlad", metadata)
        metadata.speakerProfiles = (metadata.speakerProfiles ?? []).map { $0.id == vlad.id.uuidString ? LibraryValue(id: $0.id, value: nil, modifiedAt: now) : $0 }
        settle(&meetings, &metadata)
        XCTAssertEqual(name(meetings[1], "two:me"), "Speaker 1")
        XCTAssertNil(meetings[1].speakerIdentity("two:me"))
        XCTAssertEqual(name(meetings[0], "one:me"), "Vlad", "The person's name stays")
        XCTAssertTrue(metadata.activeSpeakerProfiles.isEmpty, "A deleted profile isn't made again from the name that started it")
    }

    // MARK: Learning

    /// A confident label in a room recorder teaches the profile that kind of recording, so a voice
    /// heard that way is recognized even when it's further from the microphone voiceprint.
    func testConfidentLabelsTeachANewKindOfRecording() throws {
        var named = meeting("named", daysAgo: 30, [voice("me", mine(81), 300)])
        named.renameSpeaker(id: "named:me", name: "Vlad")
        let print = try XCTUnwrap(named.speakers[0].embedding)
        let room = DeviceRecordingIdentity(kind: "soundcore.work", serial: "S1", recordingID: "r1")
        let roomVoice = SyntheticVoice.near(print, similarity: 0.9, seed: 82)
        var meetings = [named, meeting("room", daysAgo: 10, [voice("me", roomVoice, 400)], source: .soundcore, device: room)]
        var metadata = LibraryMetadata()
        settle(&meetings, &metadata)
        let learned = try XCTUnwrap(activePrints(metadata).first { $0.origin == .recognized })
        XCTAssertEqual(learned.condition, "soundcore.work")
        XCTAssertEqual(learned.meetingID, meetings[1].id)
        XCTAssertEqual(try XCTUnwrap(learned.similarity), 0.9, accuracy: 0.01)

        // Close to the room voice, only 0.79 to the microphone one: recognized through what was learned.
        let later = SyntheticVoice.turned(roomVoice, awayFrom: print, degrees: 12)
        XCTAssertGreaterThan(SyntheticVoice.cosine(later, roomVoice), 0.97)
        XCTAssertLessThan(SyntheticVoice.cosine(later, print), 0.82)
        meetings.append(meeting("room2", daysAgo: 1, [voice("me", later, 60)], source: .soundcore, device: room))
        settle(&meetings, &metadata)
        XCTAssertEqual(meetings[2].speakerIdentity("room2:me")?.source, .recognized)

        // Without the learned voiceprint it would only be suggested.
        let book = SpeakerProfileBook(profiles: metadata.activeSpeakerProfiles, voiceprints: activePrints(metadata).filter { $0.origin == .named })
        XCTAssertEqual(book.identify(VoiceVector(space: Self.space, values: later)).decision, .suggested)
    }

    func testLearningNeedsCleanSpeechThatIsntOverlappedOrInTheBackground() throws {
        var named = meeting("named", daysAgo: 30, [voice("me", mine(91), 300)])
        named.renameSpeaker(id: "named:me", name: "Vlad")
        // Ten seconds: labelled, too little to learn from.
        let brief = meeting("brief", daysAgo: 3, [voice("me", mine(92), 10)])
        // A minute, but someone talks over almost all of it.
        var crowded = meeting("crowded", daysAgo: 2, [voice("me", mine(93), 60), voice("x", SyntheticVoice.near(other, similarity: 0.95, seed: 94), 60)])
        crowded.transcripts[0].segments[1].start = 2; crowded.transcripts[0].segments[1].end = 62
        // Twenty seconds in a ten-minute recording: a voice in the background.
        let distant = meeting("distant", daysAgo: 1, [voice("x", SyntheticVoice.near(other, similarity: 0.95, seed: 95), 600), voice("me", mine(96), 20)])
        var meetings = [named, brief, crowded, distant], metadata = LibraryMetadata()
        settle(&meetings, &metadata)
        XCTAssertEqual(meetings[1].speakerIdentity("brief:me")?.source, .recognized)
        XCTAssertEqual(meetings[3].speakerIdentity("distant:me")?.source, .recognized)
        XCTAssertFalse(activePrints(metadata).contains { $0.origin == .recognized }, "Nothing confident enough to learn from")
    }

    func testANamedVoiceUnlikeTheProfileKeepsItsNameButIsntLearned() throws {
        var one = meeting("one", daysAgo: 9, [voice("me", mine(101))])
        one.renameSpeaker(id: "one:me", name: "Vlad")
        var slip = meeting("slip", daysAgo: 1, [voice("x", SyntheticVoice.near(other, similarity: 0.95, seed: 102))])
        slip.renameSpeaker(id: "slip:x", name: "vlad")
        var meetings = [one, slip], metadata = LibraryMetadata()
        settle(&meetings, &metadata)
        XCTAssertEqual(metadata.activeSpeakerProfiles.count, 1, "Names match without case")
        XCTAssertEqual(meetings[1].speakerIdentity("slip:x")?.source, .named)
        XCTAssertEqual(name(meetings[1], "slip:x"), "vlad")
        XCTAssertEqual(activePrints(metadata).count, 1, "The unlike voice isn't a voiceprint")
    }

    /// Learned voiceprints can't carry a profile onto someone else: a voice close to a learned
    /// voiceprint but far from the person's own is at most suggested.
    func testLearningCanNotDriftAProfileOntoAnotherPerson() throws {
        let anchor = SyntheticVoice.person(200)
        let learnedVoice = SyntheticVoice.near(anchor, similarity: 0.88, seed: 201)
        let stranger = SyntheticVoice.turned(learnedVoice, awayFrom: anchor, degrees: 16)
        XCTAssertGreaterThan(SyntheticVoice.cosine(stranger, learnedVoice), 0.96)
        let id = UUID()
        let profile = SpeakerProfile(id: id, name: "Vlad", createdAt: now)
        func print(_ name: String, _ values: [Float], _ origin: Voiceprint.Origin) -> Voiceprint {
            Voiceprint(id: name, profileID: id, origin: origin, vector: VoiceVector(space: Self.space, values: values), meetingID: UUID(),
                       speakerID: name, condition: "microphone", speechSeconds: 300, recordedAt: now)
        }
        let book = SpeakerProfileBook(profiles: [profile], voiceprints: [print("a", anchor, .named), print("b", learnedVoice, .recognized),
                                                                          print("c", learnedVoice, .recognized), print("d", learnedVoice, .recognized)])
        let candidate = try XCTUnwrap(book.candidates(for: VoiceVector(space: Self.space, values: stranger)).first)
        XCTAssertLessThan(candidate.anchorSimilarity, 0.82)
        XCTAssertLessThanOrEqual(candidate.similarity, candidate.anchorSimilarity + SpeakerProfileLearning().automaticLift + 1e-9)
        XCTAssertNotEqual(book.identify(VoiceVector(space: Self.space, values: stranger)).decision, .recognized)
        // Without any voiceprint the person chose, a profile matches nothing.
        let learnedOnly = SpeakerProfileBook(profiles: [profile], voiceprints: [print("b", learnedVoice, .recognized)])
        XCTAssertTrue(learnedOnly.candidates(for: VoiceVector(space: Self.space, values: learnedVoice)).isEmpty)
    }

    func testLearnedVoiceprintsAreBoundedAndRetiredOnesNeverComeBack() throws {
        var options = SpeakerProfileOptions()
        options.learning.maximumRecognized = 2
        var named = meeting("named", daysAgo: 60, [voice("me", mine(111), 300)])
        named.renameSpeaker(id: "named:me", name: "Vlad")
        var meetings = [named] + (1...4).map { meeting("m\($0)", daysAgo: Double(50 - $0 * 10), [voice("me", mine(111 + UInt64($0)), 300)]) }
        var metadata = LibraryMetadata()
        settle(&meetings, &metadata, options: options)
        var learned = activePrints(metadata).filter { $0.origin == .recognized }
        XCTAssertEqual(Set(learned.map(\.meetingID)), [meetings[4].id, meetings[3].id], "The newest, without churning older ones")
        XCTAssertFalse((metadata.voiceprints ?? []).contains { $0.value == nil }, "Nothing learned only to be retired")
        XCTAssertTrue(meetings[1...4].allSatisfy { name($0, "\($0.title):me") == "Vlad" })

        // A newer conversation: learned, and the least useful retired for good.
        meetings.append(meeting("m5", daysAgo: 1, [voice("me", mine(120), 300)]))
        settle(&meetings, &metadata, options: options)
        learned = activePrints(metadata).filter { $0.origin == .recognized }
        XCTAssertEqual(Set(learned.map(\.meetingID)), [meetings[5].id, meetings[4].id])
        let retired = try XCTUnwrap((metadata.voiceprints ?? []).first { $0.value == nil })
        XCTAssertTrue(reconcile(&meetings, &metadata, options: options, at: now.addingTimeInterval(100)).isEmpty)
        XCTAssertNil(metadata.voiceprints?.first { $0.id == retired.id }?.value, "A retired voiceprint isn't learned again")
    }

    func testAVoiceIsNeverRecognizedByWhatWasLearnedFromIt() throws {
        var named = meeting("named", daysAgo: 30, [voice("me", mine(131), 300)])
        named.renameSpeaker(id: "named:me", name: "Vlad")
        var meetings = [named, meeting("two", daysAgo: 1, [voice("me", mine(132), 300)])], metadata = LibraryMetadata()
        _ = reconcile(&meetings, &metadata)
        _ = reconcile(&meetings, &metadata)
        let before = try XCTUnwrap(meetings[1].speakerIdentity("two:me")?.similarity)
        settle(&meetings, &metadata)
        XCTAssertTrue(activePrints(metadata).contains { $0.origin == .recognized && $0.meetingID == meetings[1].id })
        XCTAssertEqual(meetings[1].speakerIdentity("two:me")?.similarity, before, "Its own voiceprint doesn't raise its similarity")
    }

    func testRecognitionOffStillLearnsNamesAndKeepsLabels() throws {
        var one = meeting("one", daysAgo: 9, [voice("me", mine(141))])
        one.renameSpeaker(id: "one:me", name: "Vlad")
        var meetings = [one, meeting("two", daysAgo: 1, [voice("me", mine(142))])], metadata = LibraryMetadata()
        settle(&meetings, &metadata, options: SpeakerProfileOptions(recognizes: false))
        XCTAssertNotNil(try? profile("Vlad", metadata))
        XCTAssertEqual(name(meetings[1], "two:me"), "Speaker 1")
        settle(&meetings, &metadata)
        XCTAssertEqual(name(meetings[1], "two:me"), "Vlad")
        settle(&meetings, &metadata, options: SpeakerProfileOptions(recognizes: false))
        XCTAssertEqual(name(meetings[1], "two:me"), "Vlad", "Labels already given stay")
    }

    // MARK: Concurrent changes

    func testAChangeMadeMeanwhileWins() throws {
        var one = meeting("one", daysAgo: 9, [voice("me", mine(151))])
        one.renameSpeaker(id: "one:me", name: "Vlad")
        var meetings = [one, meeting("two", daysAgo: 1, [voice("me", mine(152))])]
        let base = SpeakerProfileState()
        let result = SpeakerProfileReconciler.reconcile(meetings: meetings, state: base, now: now)
        XCTAssertTrue(result.speakers.contains { $0.speakerID == "two:me" && $0.name == "Vlad" })
        // Renamed by hand while that was worked out.
        meetings[1].renameSpeaker(id: "two:me", name: "Sam")
        XCTAssertFalse(meetings[1].apply(result.speakers))
        XCTAssertEqual(name(meetings[1], "two:me"), "Sam")
    }

    // MARK: Matching for live identification (the iPhone)

    func testABookFromLibrarySettingsIdentifiesALiveVoice() throws {
        var one = meeting("one", daysAgo: 9, [voice("me", mine(161))])
        one.renameSpeaker(id: "one:me", name: "Vlad")
        var meetings = [one], metadata = LibraryMetadata()
        settle(&meetings, &metadata)
        let decoded = try JSONDecoder().decode(LibraryMetadata.self, from: JSONEncoder().encode(metadata))
        let book = SpeakerProfileBook(metadata: decoded)
        let identification = book.identify(VoiceVector(space: Self.space, values: mine(162)))
        XCTAssertEqual(identification.decision, .recognized)
        XCTAssertEqual(identification.profileID, try profile("Vlad", decoded).id)
        XCTAssertEqual(book.identify(VoiceVector(space: Self.space, values: other)).decision, .unknown)
        XCTAssertEqual(book.identify(VoiceVector(space: "another", values: mine(163))).decision, .unknown)
    }

    // MARK: Storage

    func testHalfFloatsRoundTripWithinTheirPrecision() {
        XCTAssertEqual(HalfFloat.bits(1), 0x3c00)
        XCTAssertEqual(HalfFloat.bits(-2), 0xc000)
        XCTAssertEqual(HalfFloat.bits(65504), 0x7bff)
        XCTAssertEqual(HalfFloat.bits(1e9), 0x7c00)
        XCTAssertEqual(HalfFloat.bits(0), 0)
        XCTAssertEqual(HalfFloat.float(0x0001), Float(bitPattern: 0x3380_0000), "Smallest subnormal")
        XCTAssertTrue(HalfFloat.float(HalfFloat.bits(.nan)).isNaN)
        XCTAssertEqual(HalfFloat.float(HalfFloat.bits(.infinity)), .infinity)
        for value in SyntheticVoice.person(9, dimensions: 512) {
            XCTAssertEqual(HalfFloat.float(HalfFloat.bits(value)), value, accuracy: abs(value) / 1000 + 1e-7)
        }
        let vector = VoiceVector(space: Self.space, values: SyntheticVoice.person(10, dimensions: 256))
        XCTAssertEqual(try JSONDecoder().decode(VoiceVector.self, from: JSONEncoder().encode(vector)), vector, "Exact once rounded")
        XCTAssertGreaterThan(SyntheticVoice.cosine(vector.values, SyntheticVoice.person(10, dimensions: 256)), 0.9999)
    }

    func testProfilesAndVoiceprintsKeepWhatANewerDaybookAdded() throws {
        let profile = #"{"id":"5A6B4D2C-1111-4222-8333-944445555666","name":"Vlad","createdAt":0,"pronouns":"he"}"#
        let print = #"{"id":"vp-1","profileID":"5A6B4D2C-1111-4222-8333-944445555666","origin":"enrolled","vector":{"space":"s","dimensions":2,"half":"ADwAwA=="},"#
            + #""meetingID":"6A6B4D2C-1111-4222-8333-944445555666","speakerID":"a","speechSeconds":30,"recordedAt":0,"addedAt":0,"device":"Studio Mac"}"#
        let future = #"{"id":"vp-2","profileID":"5A6B4D2C-1111-4222-8333-944445555666","origin":"named","vector":{"space":"s","dimensions":2,"single":"AACAPwAAAMA="},"#
            + #""meetingID":"6A6B4D2C-1111-4222-8333-944445555666","speakerID":"b","speechSeconds":30,"recordedAt":0,"addedAt":0}"#
        let json = #"{"schemaVersion":1,"folders":[],"templates":[],"vocabulary":[],"speakerProfiles":[{"id":"5A6B4D2C-1111-4222-8333-944445555666","value":"#
            + profile + #","modifiedAt":5}],"voiceprints":[{"id":"vp-1","value":"# + print + #","modifiedAt":5},{"id":"vp-2","value":"# + future + #","modifiedAt":5}]}"#
        let metadata = try JSONDecoder().decode(LibraryMetadata.self, from: Data(json.utf8))
        let decodedProfile = try XCTUnwrap(metadata.activeSpeakerProfiles.first)
        XCTAssertEqual(decodedProfile.unknownFields["pronouns"], .string("he"))
        let decodedPrint = try XCTUnwrap(metadata.voiceprints?.first { $0.id == "vp-1" }?.value)
        XCTAssertEqual(decodedPrint.vector.values, [1, -2])
        XCTAssertEqual(decodedPrint.origin, .recognized, "An origin this version doesn't know counts least")
        XCTAssertEqual(decodedPrint.$origin.rawValue, "enrolled")
        XCTAssertEqual(decodedPrint.unknownFields["device"], .string("Studio Mac"))
        let unreadable = try XCTUnwrap(metadata.voiceprints?.first { $0.id == "vp-2" })
        XCTAssertNil(unreadable.value)
        XCTAssertFalse(unreadable.isDeletion, "A newer encoding isn't a deletion")
        XCTAssertTrue(metadata.hasUnreadableValues)
        // Written back as it came.
        let again = try JSONDecoder().decode(LibraryMetadata.self, from: JSONEncoder().encode(metadata))
        XCTAssertEqual(again, metadata)
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(metadata), encoding: .utf8))
        XCTAssertTrue(encoded.contains("\"enrolled\"") && encoded.contains("\"pronouns\"") && encoded.contains("\"single\""))
    }

    func testAnIdentityFromANewerDaybookIsLeftAlone() throws {
        var one = meeting("one", daysAgo: 9, [voice("me", mine(171))])
        one.renameSpeaker(id: "one:me", name: "Vlad")
        let two = meeting("two", daysAgo: 1, [voice("me", mine(172))])
        let json = #"{"speakerID":"two:me","source":"verified","profileID":"5A6B4D2C-1111-4222-8333-944445555666"}"#
        var stored = two
        stored.speakerIdentities = [try JSONDecoder().decode(SpeakerIdentity.self, from: Data(json.utf8))]
        let decoded = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(stored))
        XCTAssertEqual(decoded.speakerIdentities?.first?.$source.rawValue, "verified")
        var meetings = [one, decoded], metadata = LibraryMetadata()
        settle(&meetings, &metadata)
        XCTAssertEqual(meetings[1].speakerIdentities, decoded.speakerIdentities)
        XCTAssertEqual(name(meetings[1], "two:me"), "Speaker 1")
    }

    // MARK: Sync

    /// Two devices that name the same person before they sync teach one profile, and keep both voiceprints.
    func testTwoDevicesTeachingOneProfileKeepEveryVoiceprintInEitherOrder() throws {
        var one = meeting("one", daysAgo: 9, [voice("me", mine(181))])
        one.renameSpeaker(id: "one:me", name: "Vlad")
        var two = meeting("two", daysAgo: 1, [voice("me", mine(182))])
        two.renameSpeaker(id: "two:me", name: "vlad ")
        var onMac = [one], onOther = [two]
        var mac = LibraryMetadata(), otherMac = LibraryMetadata()
        reconcile(&onMac, &mac, at: now)
        reconcile(&onOther, &otherMac, at: now.addingTimeInterval(5))
        let merged = mac.merging(otherMac)
        XCTAssertEqual(merged, otherMac.merging(mac))
        XCTAssertEqual(merged.activeSpeakerProfiles.count, 1)
        XCTAssertEqual(Set(activePrints(merged).map(\.meetingID)), [one.id, two.id])
        XCTAssertEqual(merged.merging(mac), merged, "Idempotent")

        // A voiceprint retired on one device and kept on the other stays retired; at equal clocks the retirement wins.
        let id = try XCTUnwrap(activePrints(merged).first?.id)
        var retired = merged
        retired.voiceprints = retired.voiceprints?.map { $0.id == id ? LibraryValue(id: id, value: nil, modifiedAt: $0.modifiedAt) : $0 }
        XCTAssertNil(merged.merging(retired).voiceprints?.first { $0.id == id }?.value)
        XCTAssertNil(retired.merging(merged).voiceprints?.first { $0.id == id }?.value)
    }

    /// A Daybook from before profiles keeps them under keys it doesn't know and merges them item by
    /// item as this version does, so it never drops one another device taught.
    func testAnEarlierDaybookMergesProfilesItemByItem() throws {
        var one = meeting("one", daysAgo: 9, [voice("me", mine(191))])
        one.renameSpeaker(id: "one:me", name: "Vlad")
        var two = meeting("two", daysAgo: 1, [voice("me", mine(192))])
        two.renameSpeaker(id: "two:me", name: "Vlad")
        var a = [one], b = [two]
        var left = LibraryMetadata(), right = LibraryMetadata()
        reconcile(&a, &left, at: now)
        reconcile(&b, &right, at: now.addingTimeInterval(1))
        func setting(_ metadata: LibraryMetadata, _ key: String) throws -> SyncJSONValue {
            let object = try JSONDecoder().decode([String: SyncJSONValue].self, from: JSONEncoder().encode(metadata))
            return try XCTUnwrap(object[key])
        }
        for key in ["speakerProfiles", "voiceprints"] {
            let old = SyncJSONValue.mergedLibrarySetting(try setting(left, key), try setting(right, key))
            XCTAssertEqual(old, try setting(left.merging(right), key))
        }
    }

    func testSpeakerIdentitiesMergeAcrossDevices() throws {
        let profileA = UUID(), profileB = UUID()
        var base = meeting("one", daysAgo: 1, [voice("a", mine(201)), voice("b", SyntheticVoice.near(other, similarity: 0.95, seed: 202))])
        base.updatedAt = now
        var local = base, remote = base
        local.setSpeakerIdentity(SpeakerIdentity(speakerID: "one:a", profileID: profileA, source: .recognized, similarity: 0.9,
                                                 appliedName: "Vlad", previousName: "Speaker 1"), for: "one:a")
        local.speakers[0].name = "Vlad"
        remote.setSpeakerIdentity(SpeakerIdentity(speakerID: "one:b", profileID: profileB, source: .suggested, similarity: 0.75), for: "one:b")
        let merged = MeetingMerge.merge(base: base, local: local, remote: remote).meeting
        XCTAssertEqual(merged, MeetingMerge.merge(base: base, local: remote, remote: local).meeting)
        XCTAssertEqual(merged.speakerIdentities?.map(\.speakerID), ["one:a", "one:b"])
        XCTAssertEqual(merged.speakers.first?.name, "Vlad")
        // One side takes an identity off: it stays off.
        var withdrawn = merged
        withdrawn.setSpeakerIdentity(nil, for: "one:b")
        XCTAssertEqual(MeetingMerge.merge(base: merged, local: withdrawn, remote: merged).meeting.speakerIdentities?.map(\.speakerID), ["one:a"])
        // Without a common ancestor, nothing was removed.
        XCTAssertEqual(MeetingMerge.merge(base: nil, local: local, remote: remote).meeting.speakerIdentities?.count, 2)
    }
}
