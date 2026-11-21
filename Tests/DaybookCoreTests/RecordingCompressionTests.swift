import DaybookCore
import XCTest

/// Compress Older Recordings in DaybookCore: who may compress what, the merge of a compressed track's file, the setting,
/// and recognising a recording by its original's bytes.
final class RecordingCompressionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400
    private let original = String(repeating: "a", count: 64)

    // MARK: Fixtures

    /// A conversation 60 days old, fully processed, with one microphone recording and one iPhone recording.
    private func eligible() -> (Meeting, RecordingCompressionEligibility.ConversationFacts) {
        let then = now.addingTimeInterval(-60 * day)
        let mic = RecordingTrack(source: .microphone, relativePath: "Originals/mic.caf", fileName: "microphone.caf", createdAt: then, sha256: original)
        let phone = RecordingTrack(source: .imported, relativePath: "Originals/phone.m4a", fileName: "phone.m4a", createdAt: then,
                                   sha256: String(repeating: "b", count: 64))
        let segment = TranscriptSegment(trackID: mic.id, start: 0, end: 1, text: "Hello", speakerID: "s1")
        var meeting = Meeting(date: then, updatedAt: then, tracks: [mic, phone],
                              transcripts: [TrackTranscript(trackID: mic.id, segments: [segment], createdAt: then),
                                            TrackTranscript(trackID: phone.id, segments: [segment], createdAt: then)],
                              unifiedTranscript: [segment], summary: MeetingSummary(overview: "Hi", createdAt: then),
                              speakers: [Speaker(id: "s1", name: "A")], status: .ready)
        meeting.updatedAt = then
        let facts = RecordingCompressionEligibility.ConversationFacts(isDone: true, tracks: [
            mic.id: .init(isVerified: true, isUploaded: true, storage: .lossless),
            phone.id: .init(isVerified: true, isUploaded: true, storage: .lossy),
        ])
        return (meeting, facts)
    }

    private func context(age: RecordingCompressionAge = .after30Days, startsAt: TimeInterval? = -1,
                         everyDevice: Bool = true) -> RecordingCompressionEligibility.Context {
        .init(now: now, age: age, startsAt: startsAt.map { now.addingTimeInterval($0 * day) }, everyDeviceCompresses: everyDevice)
    }

    private func decide(_ meeting: Meeting, _ facts: RecordingCompressionEligibility.ConversationFacts,
                        _ context: RecordingCompressionEligibility.Context? = nil) -> RecordingCompressionEligibility.Decision {
        RecordingCompressionEligibility.decide(meeting, facts: facts, context: context ?? self.context())
    }

    // MARK: Eligibility

    func testBehaviorEligibleConversationCompressesOnlyItsLosslessRecordings() {
        let (meeting, facts) = eligible()
        XCTAssertEqual(decide(meeting, facts), .compress([meeting.tracks[0].id]))
    }

    func testBehaviorEachConditionAloneRefuses() {
        let (base, facts) = eligible()
        let mic = base.tracks[0].id
        func refusal(_ change: (inout Meeting, inout RecordingCompressionEligibility.ConversationFacts) -> Void,
                     context: RecordingCompressionEligibility.Context? = nil) -> RecordingCompressionEligibility.Decision {
            var meeting = base, changed = facts
            change(&meeting, &changed)
            return decide(meeting, changed, context)
        }
        XCTAssertEqual(refusal({ _, _ in }, context: context(age: .never)), .skip(.off))
        XCTAssertEqual(refusal({ _, _ in }, context: context(startsAt: nil)), .skip(.notStarted))
        XCTAssertEqual(refusal({ _, _ in }, context: context(startsAt: 1)), .skip(.notStarted))
        XCTAssertEqual(refusal({ _, _ in }, context: context(everyDevice: false)), .skip(.notEveryDevice))
        XCTAssertEqual(refusal { $1.isTrashed = true }, .skip(.trashed))
        XCTAssertEqual(refusal { $1.isBusy = true }, .skip(.busy))
        XCTAssertEqual(refusal { meeting, _ in meeting.unknownFields = Self.unknown() }, .skip(.newerFields))
        XCTAssertEqual(refusal { meeting, _ in meeting.tracks[0].unknownFields = Self.unknown() }, .skip(.newerFields))
        XCTAssertEqual(refusal { meeting, _ in meeting.status = .failed }, .skip(.failed))
        XCTAssertEqual(refusal { meeting, _ in meeting.errorMessage = "Processing was interrupted." }, .skip(.failed))
        XCTAssertEqual(refusal { meeting, _ in meeting.status = .imported }, .skip(.notDone))
        XCTAssertEqual(refusal { $1.isDone = false }, .skip(.notDone))
        XCTAssertEqual(refusal { meeting, _ in meeting.transcripts.removeFirst() }, .skip(.notTranscribed))
        XCTAssertEqual(refusal { meeting, _ in meeting.unifiedTranscript = [] }, .skip(.notTranscribed))
        XCTAssertEqual(refusal { meeting, _ in meeting.summary = nil }, .skip(.noSummary))
        XCTAssertEqual(refusal { meeting, _ in meeting.speakers = [] }, .skip(.noSpeakers))
        XCTAssertEqual(refusal { meeting, _ in
            meeting.processingRequests = [ProcessingRequest(meetingID: meeting.id, mode: .summaryOnly, requestedBy: .init(id: "phone", name: "iPhone"),
                                                            createdAt: self.now.addingTimeInterval(-50 * self.day))]
        }, .skip(.openRequest))
        XCTAssertEqual(refusal { $1.offersUpgrade = true }, .skip(.upgradeOffered))
        XCTAssertEqual(refusal { meeting, _ in meeting.updatedAt = self.now.addingTimeInterval(-29 * self.day) }, .skip(.tooRecent))
        XCTAssertEqual(refusal { meeting, _ in meeting.revisions.append(.init(date: self.now.addingTimeInterval(-day), kind: .notes, oldValue: "", newValue: "x")) },
                       .skip(.tooRecent))
        XCTAssertEqual(refusal { meeting, _ in meeting.summary?.createdAt = self.now.addingTimeInterval(-day) }, .skip(.tooRecent))
        XCTAssertEqual(refusal({ _, _ in }, context: context(age: .after90Days)), .skip(.tooRecent))
        XCTAssertEqual(refusal { $1.teachesVoiceProfile = true }, .skip(.teachesVoiceProfile))
        XCTAssertEqual(refusal { $1.tracks[mic] = nil }, .skip(.notVerified(mic)))
        XCTAssertEqual(refusal { $1.tracks[mic]?.isVerified = false }, .skip(.notVerified(mic)))
        // The iPhone's recording too: every recording is checked, not only the one compressed.
        XCTAssertEqual(refusal { $1.tracks[base.tracks[1].id]?.isVerified = false }, .skip(.notVerified(base.tracks[1].id)))
        XCTAssertEqual(refusal { $1.tracks[mic]?.isUploaded = false }, .skip(.notUploaded(mic)))
        XCTAssertEqual(refusal { $1.tracks[mic]?.storage = .lossy }, .skip(.nothingToCompress))
        XCTAssertEqual(refusal { $1.tracks[mic]?.storage = .unsupported }, .skip(.nothingToCompress))
        XCTAssertEqual(refusal { meeting, _ in meeting.tracks[0].encoding = self.encoding() }, .skip(.nothingToCompress))
        // A library that doesn't sync has nothing to upload.
        XCTAssertEqual(refusal { $1.tracks[mic]?.isUploaded = nil; $1.tracks[base.tracks[1].id]?.isUploaded = nil }, .compress([mic]))
    }

    func testBehaviorAgeIsMeasuredFromTheLastActivity() {
        var (meeting, facts) = eligible()
        meeting.updatedAt = now.addingTimeInterval(-31 * day)
        XCTAssertEqual(decide(meeting, facts), .compress([meeting.tracks[0].id]))
        meeting.processingRequests = [ProcessingRequest(meetingID: meeting.id, mode: .summaryOnly, requestedBy: .init(id: "m", name: "Mac"),
                                                        createdAt: now.addingTimeInterval(-40 * day),
                                                        outcome: .init(result: .completed, device: .init(id: "m", name: "Mac"), finishedAt: now.addingTimeInterval(-2 * day)))]
        XCTAssertEqual(decide(meeting, facts), .skip(.tooRecent))
        facts.isBusy = false
    }

    private static func unknown() -> UnknownFields {
        let data = Data(#"{"id":"x","futureField":1}"#.utf8)
        struct Holder: Decodable { var fields: UnknownFields
            init(from decoder: Decoder) throws { fields = try UnknownFields(from: decoder, known: ["id"]) } }
        return try! JSONDecoder().decode(Holder.self, from: data).fields
    }

    private func encoding(previous: String? = nil, path: String = "Originals/mic.caf") -> TrackEncoding {
        TrackEncoding(method: "aac-lc-64", sourceFormat: "Linear PCM", previousSHA256: previous ?? original,
                      previousRelativePath: path, previousFileName: "microphone.caf", encodedAt: now)
    }

    func testBehaviorAClockThatCantBeTrustedRefuses() {
        let (meeting, facts) = eligible()
        var untrusted = context()
        untrusted.clockTrusted = false
        XCTAssertEqual(decide(meeting, facts, untrusted), .skip(.clock))
        // Behind the conversation itself.
        var behind = meeting
        behind.revisions.append(.init(date: now.addingTimeInterval(day), kind: .notes, oldValue: "", newValue: "x"))
        XCTAssertEqual(decide(behind, facts), .skip(.clock))
        XCTAssertEqual(RecordingCompressionEligibility.newestDate(in: [meeting, behind]), now.addingTimeInterval(day))
    }

    func testBehaviorARecordingOfAKindThisVersionDoesntKnowIsLeftAlone() throws {
        let (meeting, facts) = eligible()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(meeting.tracks[0])) as? [String: Any])
        object["source"] = "hologram"
        var changed = meeting
        changed.tracks[0] = try JSONDecoder().decode(RecordingTrack.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decide(changed, facts), .skip(.newerFields))
    }

    // MARK: Who compresses

    func testBehaviorRunnerIsTheRecordingMacWhileItIsAroundOtherwiseTheSmallestMac() {
        var track = RecordingTrack(relativePath: "Originals/a.caf", fileName: "a.caf")
        let recent = now.addingTimeInterval(-day), gone = now.addingTimeInterval(-31 * day)
        XCTAssertEqual(RecordingCompressionRunner.runner(for: track, thisDevice: "M", macs: nil, now: now), "M")
        XCTAssertEqual(RecordingCompressionRunner.runner(for: track, thisDevice: "M", macs: [.init(id: "B", lastSeen: recent)], now: now), "B")
        XCTAssertEqual(RecordingCompressionRunner.runner(for: track, thisDevice: "M", macs: [.init(id: "B", lastSeen: gone)], now: now), "M")
        XCTAssertEqual(RecordingCompressionRunner.runner(for: track, thisDevice: "M", macs: [.init(id: "B", lastSeen: recent, isSuperseded: true)], now: now), "M")
        track.capture = TrackCaptureDetails(method: "test")
        track.capture?.deviceID = "Z"
        XCTAssertEqual(RecordingCompressionRunner.runner(for: track, thisDevice: "M", macs: [.init(id: "Z", lastSeen: recent), .init(id: "B", lastSeen: recent)], now: now), "Z")
        XCTAssertEqual(RecordingCompressionRunner.runner(for: track, thisDevice: "M", macs: [.init(id: "Z", lastSeen: gone), .init(id: "B", lastSeen: recent)], now: now), "B")
        track.capture?.deviceID = "M"
        XCTAssertEqual(RecordingCompressionRunner.runner(for: track, thisDevice: "M", macs: [.init(id: "B", lastSeen: recent)], now: now), "M")
    }

    // MARK: Merging a compressed track's file

    private func file(_ sha: Character, from previous: Character? = nil) -> RecordingCompression.File {
        let digest = String(repeating: sha, count: 64)
        guard let previous else { return .init(relativePath: "Originals/x.caf", fileName: "x.caf", sha256: digest, encoding: nil) }
        return .init(relativePath: "Originals/x.aac-\(digest.prefix(16)).m4a", fileName: "x.m4a", sha256: digest,
                     encoding: encoding(previous: String(repeating: previous, count: 64), path: "Originals/x.caf"))
    }

    private func merge(_ a: RecordingCompression.File, _ b: RecordingCompression.File, _ ancestor: RecordingCompression.File? = nil) -> RecordingCompression.File {
        RecordingCompression.merged(a, b, ancestor: ancestor) { _, _ in }
    }

    func testBehaviorCopyWinsOverItsOriginalWhateverTheAncestor() {
        let o = file("a"), c = file("c", from: "a")
        for ancestor in [nil, o, c] {
            XCTAssertEqual(merge(o, c, ancestor), c)
            XCTAssertEqual(merge(c, o, ancestor), c)
        }
    }

    func testBehaviorTwoCopiesOfOneOriginalKeepTheSmallerHash() {
        let o = file("a"), c1 = file("c", from: "a"), c2 = file("d", from: "a")
        for ancestor in [nil, o, c1, c2] {
            XCTAssertEqual(merge(c1, c2, ancestor), c1)
            XCTAssertEqual(merge(c2, c1, ancestor), c1)
        }
    }

    func testBehaviorFileMergeIsCommutativeAssociativeAndIdempotent() {
        let versions = [file("a"), file("c", from: "a"), file("d", from: "a"), file("e", from: "a")]
        for x in versions {
            XCTAssertEqual(merge(x, x, versions[0]), x)
            for y in versions {
                XCTAssertEqual(merge(x, y, versions[0]), merge(y, x, versions[0]))
                for z in versions {
                    XCTAssertEqual(merge(merge(x, y, versions[0]), z, versions[0]), merge(x, merge(y, z, versions[0]), versions[0]))
                }
            }
        }
    }

    func testBehaviorCompressedOnOneDeviceEditedOnAnotherKeepsBoth() {
        let (base, _) = eligible()
        var compressed = base
        file("c", from: "a").apply(to: &compressed.tracks[0])
        var edited = base
        edited.tracks[0].offset = 4.5
        edited.title = "Renamed"
        for (local, remote) in [(compressed, edited), (edited, compressed)] {
            let result = MeetingMerge.merge(base: base, local: local, remote: remote)
            XCTAssertEqual(result.meeting.tracks[0].sha256, compressed.tracks[0].sha256)
            XCTAssertEqual(result.meeting.tracks[0].encoding, compressed.tracks[0].encoding)
            XCTAssertEqual(result.meeting.tracks[0].offset, 4.5)
            XCTAssertEqual(result.meeting.title, "Renamed")
            XCTAssertTrue(result.warnings.isEmpty, "\(result.warnings)")
        }
        // An older device that merged back to the original can't undo the copy.
        let merged = MeetingMerge.merge(base: compressed, local: compressed, remote: base).meeting
        XCTAssertEqual(merged.tracks[0].sha256, compressed.tracks[0].sha256)
    }

    // MARK: The setting

    func testBehaviorSettingDefaultsTo30DaysAndAnythingUnreadableIsNever() throws {
        var metadata = LibraryMetadata()
        XCTAssertEqual(metadata.recordingCompression, .after30Days)
        for (selection, expected) in [("90d", RecordingCompressionAge.after90Days), ("never", .never), ("30d", .after30Days), ("7d", .never)] {
            metadata.choices = [.init(id: LibraryChoice.Name.compressOlderRecordings.rawValue, value: LibraryChoice(selection: selection), modifiedAt: now)]
            XCTAssertEqual(metadata.recordingCompression, expected, selection)
        }
        for value in [#"{"selection":12}"#, #"{"future":"weekly"}"#, #"{"selection":"30d","until":"2027"}"#] {
            let json = #"{"schemaVersion":1,"folders":[],"templates":[],"vocabulary":[],"choices":[{"id":"compressOlderRecordings","modifiedAt":0,"value":"# + value + "}]}"
            let decoded = try JSONDecoder().decode(LibraryMetadata.self, from: Data(json.utf8))
            XCTAssertEqual(decoded.recordingCompression, .never, value)
        }
    }

    func testBehaviorLaterSettingWinsWhenTwoLibrariesMerge() {
        var a = LibraryMetadata(), b = LibraryMetadata()
        a.choices = [.init(id: LibraryChoice.Name.compressOlderRecordings.rawValue, value: LibraryChoice(selection: "never"), modifiedAt: now)]
        b.choices = [.init(id: LibraryChoice.Name.compressOlderRecordings.rawValue, value: LibraryChoice(selection: "90d"), modifiedAt: now.addingTimeInterval(5))]
        XCTAssertEqual(a.merging(b).recordingCompression, .after90Days)
        XCTAssertEqual(b.merging(a).recordingCompression, .after90Days)
    }

    // MARK: Compatibility

    func testBehaviorOlderReaderKeepsTheEncodingAndWritesItBack() throws {
        var track = RecordingTrack(relativePath: "Originals/x.aac-cccccccccccccccc.m4a", fileName: "x.m4a", sha256: String(repeating: "c", count: 64))
        track.encoding = encoding()
        let written = try JSONEncoder().encode(track)
        /// A version from before compression: the keys it knew, and everything else kept as it came.
        struct OlderTrack: Codable {
            var id: UUID; var relativePath: String; var fileName: String; var createdAt: Date; var sha256: String; var source: String
            var rest: UnknownFields
            enum CodingKeys: String, CodingKey { case id, relativePath, fileName, createdAt, sha256, source }
            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                id = try values.decode(UUID.self, forKey: .id); relativePath = try values.decode(String.self, forKey: .relativePath)
                fileName = try values.decode(String.self, forKey: .fileName); createdAt = try values.decode(Date.self, forKey: .createdAt)
                sha256 = try values.decode(String.self, forKey: .sha256); source = try values.decode(String.self, forKey: .source)
                rest = try UnknownFields(from: decoder, known: ["id", "relativePath", "fileName", "createdAt", "sha256", "source"])
            }
            func encode(to encoder: Encoder) throws {
                var values = encoder.container(keyedBy: CodingKeys.self)
                try values.encode(id, forKey: .id); try values.encode(relativePath, forKey: .relativePath)
                try values.encode(fileName, forKey: .fileName); try values.encode(createdAt, forKey: .createdAt)
                try values.encode(sha256, forKey: .sha256); try values.encode(source, forKey: .source)
                try rest.encode(to: encoder)
            }
        }
        var older = try JSONDecoder().decode(OlderTrack.self, from: written)
        XCTAssertFalse(older.rest.isEmpty)
        older.fileName = "edited.m4a"
        let back = try JSONDecoder().decode(RecordingTrack.self, from: JSONEncoder().encode(older))
        XCTAssertEqual(back.encoding, track.encoding)
        XCTAssertEqual(back.sha256, track.sha256)
        // A newer encoding's own extra keys come back too.
        let newer = #"{"method":"aac-lc-64","rule":2,"sourceFormat":"x","previousSHA256":"\#(original)","previousRelativePath":"Originals/a.caf","previousFileName":"a.caf","encodedAt":0,"future":true}"#
        let decoded = try JSONDecoder().decode(TrackEncoding.self, from: Data(newer.utf8))
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self).contains("future"))
        // One in a shape this version can't read doesn't stop the conversation opening: kept, written back, left alone.
        var plain = RecordingTrack(relativePath: "Originals/x.m4a", fileName: "x.m4a", sha256: String(repeating: "c", count: 64))
        plain.encoding = nil
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any])
        object["encoding"] = ["method": 7]
        let odd = try JSONDecoder().decode(RecordingTrack.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(odd.encoding)
        XCTAssertFalse(odd.unknownFields.isEmpty, "kept, so the recording is left alone here")
        let rewritten = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(odd)) as? [String: Any])
        XCTAssertEqual((rewritten["encoding"] as? [String: Int])?["method"], 7)
    }

    // MARK: Identity

    func testBehaviorCompressedRecordingIsKnownByItsOriginalBytes() {
        var track = RecordingTrack(relativePath: "Originals/x.m4a", fileName: "x.m4a", sha256: String(repeating: "c", count: 64))
        XCTAssertFalse(track.holdsBytes(original))
        track.encoding = encoding()
        XCTAssertTrue(track.holdsBytes(original))
        XCTAssertTrue(track.holdsBytes(track.sha256))
        XCTAssertFalse(track.holdsBytes(""))
        XCTAssertEqual(track.knownDigests, [track.sha256, original])
    }

    func testBehaviorMeasurementOnTheOriginalStillPlacesTheCopy() {
        let reference = RecordingTrack(source: .microphone, relativePath: "Originals/r.caf", fileName: "r.caf", offset: 0, sha256: String(repeating: "d", count: 64))
        var other = RecordingTrack(source: .soundcore, relativePath: "Originals/o.m4a", fileName: "o.m4a", sha256: String(repeating: "c", count: 64))
        other.encoding = encoding()
        let record = TrackAudioAlignment(trackID: other.id, referenceTrackID: reference.id, alignment: AudioAlignment(offset: 2, confidence: 0.9),
                                         trackDigest: original, referenceDigest: reference.sha256)
        XCTAssertTrue(other.holdsBytes(record.trackDigest))
        var stale = other
        stale.encoding = nil
        XCTAssertFalse(stale.holdsBytes(record.trackDigest))
    }
}
