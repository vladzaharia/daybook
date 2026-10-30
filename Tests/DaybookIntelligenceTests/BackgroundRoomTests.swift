import DaybookCore
import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookIntelligence

/// Rooms more like real ones than `SoundClassifierTests`' living room: voices and a TV heard through
/// a room's reverberation from across it, a TV's and a kitchen radio's small loudspeakers, a radio
/// host without music, and a song with vocals. Apple's classifier and `BackgroundAudio.judge` on
/// each, against what each passage really is; docs/validation.md has the measurements. Speech from
/// `say`, music from tones and noise; nothing is downloaded or recorded.
final class BackgroundRoomTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("BackgroundRoomTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    // MARK: Fixtures

    /// Each line from `say` once for the whole class: the scenes share them.
    private static var spoken: [String: [Float]] = [:]

    private func voice(_ text: String, _ name: String) throws -> [Float] {
        if let samples = Self.spoken[name + "|" + text] { return samples }
        guard let samples = try SyntheticAudio.speech(text, voice: name, in: folder) else { throw XCTSkip("The \(name) voice isn't available to `say` here.") }
        Self.spoken[name + "|" + text] = samples
        return samples
    }

    /// Someone at the table: a little of the room.
    private func near(_ x: [Float]) -> [Float] { SyntheticAudio.reverberated(x, SyntheticAudio.room(rt60: 0.45, directToReverberant: 10, seed: 3)) }
    /// Across a living room: more room than voice.
    private func across(_ x: [Float], seed: UInt64 = 5) -> [Float] {
        SyntheticAudio.reverberated(x, SyntheticAudio.room(rt60: 0.6, directToReverberant: -4, seed: seed))
    }
    /// A TV across the room: its small loudspeaker, then the room.
    private func tv(_ x: [Float]) -> [Float] { across(SyntheticAudio.loudspeaker(x, low: 150, high: 6_000)) }
    /// A kitchen radio across the room: a smaller loudspeaker still.
    private func radio(_ x: [Float]) -> [Float] { across(SyntheticAudio.loudspeaker(x, low: 250, high: 4_000), seed: 9) }

    /// A presenter over a music bed `bedBelow` dB under them, as one signal.
    private func presenter(_ speech: [Float], bedBelow: Float?) -> [Float] {
        guard let bedBelow else { return SyntheticAudio.level(speech, 0) }
        var mix = SyntheticAudio.level(speech, 0)
        SyntheticAudio.add(SyntheticAudio.level(SyntheticAudio.music(seconds: Double(speech.count) / SyntheticAudio.rate + 1), -bedBelow), into: &mix, at: 0)
        return mix
    }

    private struct Scene {
        var name: String
        var mix: [Float]
        var passages: [(segment: TranscriptSegment, background: Bool, what: String)] = []
        let track = UUID()

        init(_ name: String, seconds: Double) { self.name = name; mix = SyntheticAudio.silence(seconds) }

        /// `sound` from `at`, at `decibels` (against −22 dBFS), heard as a passage by `speaker` unless nil.
        mutating func add(_ sound: [Float], at: Double, decibels: Float, seconds: Double? = nil, speaker: String?, text: String = "",
                          background: Bool, what: String) {
            SyntheticAudio.add(SyntheticAudio.level(sound, decibels), into: &mix, at: at, seconds: seconds)
            guard let speaker else { return }
            let length = min(seconds ?? .infinity, Double(sound.count) / SyntheticAudio.rate)
            passages.append((TranscriptSegment(trackID: track, start: at + 0.3, end: at + max(1, length - 0.3), text: text, speakerID: speaker),
                             background, what))
        }
    }

    private struct Outcome { var what: String; var background: Bool; var judged: BackgroundAudio.Kind?; var speech, music, level: Double }

    /// Classifies the scene, judges its passages, and prints a row per passage.
    private func run(_ scene: Scene) throws -> [Outcome] {
        let url = folder.appendingPathComponent("\(scene.name).wav")
        try SyntheticAudio.write(SyntheticAudio.limited(scene.mix), to: url)
        let analysis = try SoundClassifier.analyze(url: url)
        let verdict = BackgroundAudio.judge(scene.passages.map(\.segment), analysis: analysis)
        var lines: [String] = []
        let outcomes = scene.passages.map { passage -> Outcome in
            let frames = analysis.frames(from: passage.segment.start, to: passage.segment.end)
            func mean(_ key: KeyPath<BackgroundAudioAnalysis.Frame, Double>) -> Double { frames.map { $0[keyPath: key] }.reduce(0, +) / Double(max(1, frames.count)) }
            let levels = frames.compactMap(\.level).sorted()
            let outcome = Outcome(what: passage.what, background: passage.background, judged: verdict.segments[passage.segment.id],
                                  speech: mean(\.speech), music: mean(\.background), level: levels.isEmpty ? -127 : levels[levels.count / 2])
            let right = (outcome.judged != nil) == outcome.background
            lines.append(String(format: "%@ | %.2f | %.2f | %.0f dB | %@ | %@", outcome.what, outcome.speech, outcome.music, outcome.level,
                                outcome.judged?.rawValue ?? "kept", right ? "right" : (outcome.background ? "missed" : "WRONGLY LEFT OUT")))
            return outcome
        }
        print("BackgroundRoomTests \(scene.name):\n" + lines.joined(separator: "\n"))
        return outcomes
    }

    // MARK: Scenes

    private let lines = (
        plan: "Okay, so let's go over the launch plan for next week. Priya will send the checklist on Friday.",
        budget: "Sorry, the TV is on in the other room. Anyway, I will review the budget numbers with finance before Monday.",
        travel: "That works for me. I think we can cut travel and hold marketing flat this quarter.",
        thursday: "Great. Let's meet again on Thursday to make the final call on the launch date.",
        news: "Tonight on the evening news, heavy rain is expected across the region, and officials urge drivers to stay home.",
        weather: "Coming up after the break, the weekend forecast and the scores from tonight's game.",
        host: "Good morning, it's seven fifteen. Traffic is slow on the bridge this morning, so leave a little early if you can.",
        song: "We are walking down the road tonight, singing all the way back home, and the stars are shining bright."
    )

    /// Each passage judged as what it is: background left out, the conversation kept.
    private func assertRight(_ outcomes: [Outcome], file: StaticString = #filePath, line: UInt = #line) {
        for outcome in outcomes {
            XCTAssertEqual(outcome.judged != nil, outcome.background, outcome.what, file: file, line: line)
        }
    }

    func testATVAcrossTheRoom() throws {
        let person = try voice(lines.plan, "Samantha"), later = try voice(lines.budget, "Samantha"), other = try voice(lines.travel, "Fred")
        let news = try voice(lines.news, "Daniel"), weather = try voice(lines.weather, "Daniel")
        var scene = Scene("tv-across-the-room", seconds: 70)
        scene.add(near(person), at: 0, decibels: 0, seconds: 11, speaker: "A", background: false, what: "the person, at the table")
        scene.add(tv(presenter(news, bedBelow: 3)), at: 12, decibels: -10, seconds: 11, speaker: "TV", background: true,
                  what: "a presenter over a bed 3 dB under, TV across the room, 10 dB down")
        scene.add(tv(presenter(weather, bedBelow: 0)), at: 24, decibels: -10, seconds: 8, speaker: "TV", background: true,
                  what: "the same, the bed as loud as the voice")
        scene.add(tv(SyntheticAudio.music(seconds: 8)), at: 33, decibels: -12, speaker: "TV", background: true, what: "the TV's music alone")
        scene.add(near(later), at: 42, decibels: 0, seconds: 11, speaker: "A", background: false, what: "the person again")
        scene.add(near(other), at: 54, decibels: -3, seconds: 11, speaker: "B", background: false, what: "a second person, 3 dB down")
        assertRight(try run(scene))
    }

    func testATVOnWhileTheyTalk() throws {
        let person = try voice(lines.plan, "Samantha"), later = try voice(lines.thursday, "Samantha"), other = try voice(lines.travel, "Fred")
        let news = try voice(lines.news + " " + lines.weather, "Daniel")
        var scene = Scene("tv-on-while-they-talk", seconds: 50)
        // The TV runs the whole time, 14 dB under the people: its presenter is heard alone between them.
        let broadcast = Array(tv(presenter(news + news + news, bedBelow: 3)).prefix(Int(50 * SyntheticAudio.rate)))
        scene.add(broadcast, at: 0, decibels: -14, speaker: nil, background: true, what: "")
        scene.add(near(person), at: 0, decibels: 0, seconds: 10, speaker: "A", background: false, what: "the person over the TV")
        scene.passages.append((TranscriptSegment(trackID: scene.track, start: 11, end: 18.5, text: "", speakerID: "TV"), true,
                               "the presenter between them, 14 dB down"))
        scene.add(near(other), at: 19, decibels: -3, seconds: 11, speaker: "B", background: false, what: "a second person over the TV")
        scene.passages.append((TranscriptSegment(trackID: scene.track, start: 30.5, end: 37.5, text: "", speakerID: "TV"), true,
                               "the presenter again"))
        scene.add(near(later), at: 38, decibels: 0, seconds: 11, speaker: "A", background: false, what: "the person again")
        assertRight(try run(scene))
    }

    func testAPresenterAcrossTheRoomAtSeveralDistances() throws {
        let person = try voice(lines.plan, "Samantha"), later = try voice(lines.thursday, "Samantha"), news = try voice(lines.news, "Daniel")
        for (decibels, bed) in [(Float(-6), Float(3)), (-10, 3), (-14, 3), (-10, 0), (-10, 6)] {
            var scene = Scene("presenter-\(Int(-decibels))-bed-\(Int(bed))", seconds: 38)
            scene.add(near(person), at: 0, decibels: 0, seconds: 11, speaker: "A", background: false, what: "the person")
            scene.add(tv(presenter(news, bedBelow: bed)), at: 12, decibels: decibels, seconds: 12, speaker: "TV", background: true,
                      what: "presenter \(Int(-decibels)) dB down, bed \(Int(bed)) dB under")
            scene.add(near(later), at: 26, decibels: 0, seconds: 11, speaker: "A", background: false, what: "the person")
            let outcomes = try run(scene)
            if decibels > -7 {
                // Closer than 7 dB down it could be someone in the room: kept, the conservative side.
                XCTAssertTrue(outcomes.allSatisfy { $0.judged == nil }, "A presenter 6 dB down stays")
            } else {
                assertRight(outcomes)
            }
        }
    }

    /// The limit: someone farther from the microphone than the others (more room than voice, 8 dB or
    /// more down) with music in the room within about 9 dB of their voice sounds, to the classifier and
    /// the level, like a TV across the room.
    func testSomeoneAcrossTheTableWithMusicInTheRoom() throws {
        let person = try voice(lines.plan, "Samantha"), later = try voice(lines.thursday, "Samantha"), other = try voice(lines.travel, "Tessa")
        for (decibels, musicBelow) in [(Float(-6), Float(12)), (-6, 6), (-10, 6)] {
            var scene = Scene("across-the-table-\(Int(-decibels))-music-\(Int(musicBelow))", seconds: 38)
            scene.add(across(SyntheticAudio.music(seconds: 38)), at: 0, decibels: decibels - musicBelow, speaker: nil, background: false, what: "")
            scene.add(near(person), at: 0, decibels: 0, seconds: 11, speaker: "A", background: false, what: "the person")
            scene.add(across(other, seed: 11), at: 12, decibels: decibels, seconds: 12, speaker: "B", background: false,
                      what: "someone across the table, \(Int(-decibels)) dB down, music \(Int(musicBelow)) dB under")
            scene.add(near(later), at: 26, decibels: 0, seconds: 11, speaker: "A", background: false, what: "the person")
            let outcomes = try run(scene)
            if decibels < -7 {
                XCTExpectFailure("Someone 10 dB down over music 6 dB under them reads as a TV across the room") { assertRight(outcomes) }
            } else {
                assertRight(outcomes)
            }
        }
    }

    /// The limit: without music or applause, a broadcast voice is a voice.
    func testARadioHostWithoutMusic() throws {
        let person = try voice(lines.plan, "Samantha"), later = try voice(lines.thursday, "Samantha"), host = try voice(lines.host, "Karen")
        var scene = Scene("radio-host", seconds: 38)
        scene.add(near(person), at: 0, decibels: 0, seconds: 11, speaker: "A", background: false, what: "the person")
        scene.add(radio(host), at: 12, decibels: -10, seconds: 12, speaker: "Radio", background: true,
                  what: "a radio host without music, kitchen radio across the room, 10 dB down")
        scene.add(near(later), at: 26, decibels: 0, seconds: 11, speaker: "A", background: false, what: "the person")
        let outcomes = try run(scene)
        XCTAssertTrue(outcomes.allSatisfy { $0.judged == nil }, "Everything stays, the radio host included")
    }

    func testASongWithVocals() throws {
        let person = try voice(lines.plan, "Samantha"), later = try voice(lines.thursday, "Samantha"), budget = try voice(lines.budget, "Samantha")
        let sung = try voice(lines.song, "Good News")
        let seconds = Double(sung.count) / SyntheticAudio.rate
        var song = SyntheticAudio.level(sung, 0)
        SyntheticAudio.add(SyntheticAudio.level(SyntheticAudio.music(seconds: seconds + 1), -3), into: &song, at: 0)
        let played = across(SyntheticAudio.loudspeaker(song, low: 80, high: 7_000))
        var scene = Scene("song-with-vocals", seconds: 30 + seconds + 12)
        scene.add(near(person), at: 0, decibels: 0, seconds: 11, speaker: "A", background: false, what: "the person")
        scene.add(played, at: 12, decibels: -8, speaker: "C", text: lines.song, background: true, what: "a song with vocals across the room, 8 dB down")
        // The person talks over the same song, quieter now.
        scene.add(played, at: 13 + seconds, decibels: -18, speaker: nil, background: false, what: "")
        scene.add(near(budget), at: 13 + seconds, decibels: 0, seconds: 11, speaker: "A", background: false, what: "the person over the song, 18 dB down")
        scene.add(near(later), at: 25 + seconds, decibels: 0, seconds: 11, speaker: "A", background: false, what: "the person")
        assertRight(try run(scene))
    }
}
