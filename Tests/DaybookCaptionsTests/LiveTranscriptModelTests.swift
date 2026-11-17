import AVFoundation
@testable import DaybookCaptions
import DaybookTestSupport
import XCTest

/// What the live transcript view reads (`LiveTranscriptModel`): every line since the recording began, in order,
/// the open one replaced in place, kept within a bound, and followed until the person scrolls away. Scripted
/// captioners and a temporary folder; no speech recognition, nothing recorded.
@MainActor
final class LiveTranscriptModelTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveTranscriptModelTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func line(_ text: String, _ start: TimeInterval, tentative: Bool = false, id: UUID = UUID()) -> LiveCaptionSegment {
        LiveCaptionSegment(id: id, start: start, end: start + 1, text: text, isTentative: tentative)
    }

    // MARK: The lines

    func testBehaviorEveryLineSinceTheRecordingBeganIsKeptInOrderNotJustTheNewest() async throws {
        let session = LiveCaptionSession(store: LiveCaptionStore(libraryRoot: root), saveInterval: .seconds(60))
        let captioner = ScriptedCaptioner(lines: [])
        XCTAssertTrue(session.begin(meetingID: UUID(), captioners: [(.microphone, captioner)]))
        await session.start(locale: Locale(identifier: "en_US"))
        try await waitUntil("listening") { session.states[.microphone] == .listening }
        let total = 40
        for index in 0..<total {
            captioner.apply(text: "Line \(index)", start: Double(index) * 2, end: Double(index) * 2 + 1.5, isFinal: true)
        }
        try await waitUntil("all heard") { session.version > 0 && session.segments.last?.text == "Line \(total - 1)" }
        let tail = await LiveCaptionMixer().tailLength
        XCTAssertEqual(session.segments.count, tail, "the surfaces keep only the newest few")

        let model = LiveTranscriptModel()
        model.apply(await session.transcriptSource.read())
        XCTAssertEqual(model.lines.map(\.text), (0..<total).map { "Line \($0)" }, "the whole transcript, oldest first")
        await session.finish()
    }

    func testBehaviorTheLineBeingSpokenUpdatesInPlace() async throws {
        let session = LiveCaptionSession(store: LiveCaptionStore(libraryRoot: root), saveInterval: .seconds(60))
        let captioner = ScriptedCaptioner(lines: [])
        XCTAssertTrue(session.begin(meetingID: UUID(), captioners: [(.microphone, captioner)]))
        await session.start(locale: Locale(identifier: "en_US"))
        try await waitUntil("listening") { session.states[.microphone] == .listening }
        captioner.apply(text: "Budget agreed", start: 0.4, end: 1.5, isFinal: true)
        captioner.apply(text: "Next we", start: 1.6, end: 1.9, isFinal: false)
        try await waitUntil("two lines") { session.segments.count == 2 }

        let model = LiveTranscriptModel()
        let source = session.transcriptSource
        model.apply(await source.read())
        let open = try XCTUnwrap(model.lines.last)
        XCTAssertTrue(open.isTentative)
        let before = model.revision

        captioner.apply(text: "Next we ship it", start: 1.6, end: 2.6, isFinal: false)
        try await waitUntil("revised") { session.segments.last?.text == "Next we ship it" }
        model.apply(await source.read())
        XCTAssertEqual(model.lines.map(\.text), ["Budget agreed", "Next we ship it"], "replaced, not appended")
        XCTAssertEqual(model.lines.last?.id, open.id, "the same line, so a row is revised rather than added")
        XCTAssertGreaterThan(model.revision, before)

        captioner.apply(text: "Next we ship it.", start: 1.6, end: 2.8, isFinal: true)
        try await waitUntil("final") { session.segments.last?.isTentative == false }
        model.apply(await source.read())
        XCTAssertEqual(model.lines.count, 2)
        XCTAssertEqual(model.lines.last?.isTentative, false)
        await session.finish()
    }

    func testBehaviorNothingChangesWhenAReadingHasNothingNew() {
        let model = LiveTranscriptModel()
        let reading = LiveTranscriptModel.Reading(lines: [line("Hello", 0)], names: ["device:a": "Soundcore"])
        model.apply(reading)
        let revision = model.revision
        model.apply(reading)
        XCTAssertEqual(model.revision, revision, "the same lines again is not a change")
        XCTAssertEqual(model.names["device:a"], "Soundcore")
    }

    func testBehaviorLinesWithoutWordsAreLeftOut() {
        let model = LiveTranscriptModel()
        model.apply(.init(lines: [line("Hello", 0), line("  ", 1), line("There", 2)]))
        XCTAssertEqual(model.lines.map(\.text), ["Hello", "There"])
    }

    func testBehaviorWhenTheCaptionsEndWhatWasCapturedStays() async throws {
        let session = LiveCaptionSession(store: LiveCaptionStore(libraryRoot: root), saveInterval: .seconds(60))
        let captioner = ScriptedCaptioner(lines: [])
        XCTAssertTrue(session.begin(meetingID: UUID(), captioners: [(.microphone, captioner)]))
        await session.start(locale: Locale(identifier: "en_US"))
        try await waitUntil("listening") { session.states[.microphone] == .listening }
        captioner.apply(text: "Last words", start: 0.4, end: 1.5, isFinal: false)
        try await waitUntil("heard") { session.segments.count == 1 }
        let model = LiveTranscriptModel()
        model.apply(await session.transcriptSource.read())
        await session.finish()
        XCTAssertTrue(session.segments.isEmpty, "the recording's own surfaces let go of them")
        model.apply(.init(lines: []))
        XCTAssertEqual(model.lines.map(\.text), ["Last words"], "an emptied source is the recording ending, not the words going")
    }

    // MARK: The bound

    func testBehaviorOnlyTheNewestLinesAreKeptForAVeryLongRecording() {
        let model = LiveTranscriptModel(maxLines: 100)
        let all = (0..<250).map { line("Line \($0)", Double($0)) }
        model.apply(.init(lines: all))
        XCTAssertEqual(model.lines.count, 100)
        XCTAssertEqual(model.lines.first?.text, "Line 150")
        XCTAssertEqual(model.lines.last?.text, "Line 249", "the newest words are never the ones dropped")
        model.apply(.init(lines: all + [line("Line 250", 250)]))
        XCTAssertEqual(model.lines.count, 100)
        XCTAssertEqual(model.lines.last?.text, "Line 250")
        XCTAssertEqual(LiveTranscriptModel.maxLines, 10_000, "hours of speech: about one line every few seconds")
    }

    func testBehaviorSavedCaptionsAreNotTouchedByTheBound() async throws {
        let store = LiveCaptionStore(libraryRoot: root)
        let session = LiveCaptionSession(store: store, saveInterval: .seconds(60))
        let captioner = ScriptedCaptioner(lines: [])
        let id = UUID()
        XCTAssertTrue(session.begin(meetingID: id, captioners: [(.microphone, captioner)]))
        await session.start(locale: Locale(identifier: "en_US"))
        try await waitUntil("listening") { session.states[.microphone] == .listening }
        for index in 0..<30 { captioner.apply(text: "Line \(index)", start: Double(index) * 2, end: Double(index) * 2 + 1.5, isFinal: true) }
        try await waitUntil("heard") { session.segments.last?.text == "Line 29" }
        let model = LiveTranscriptModel(maxLines: 5)
        model.apply(await session.transcriptSource.read())
        XCTAssertEqual(model.lines.count, 5)
        await session.finish()
        XCTAssertEqual(store.captions(for: id)?.segments.count, 30, "what's saved is every line")
    }

    // MARK: Reading while open

    func testBehaviorItReadsOnlyWhenTheSourceMovedAndStopsWhenCancelled() async throws {
        var reads = 0
        var version = 1
        var lines = [line("One", 0)]
        let source = LiveTranscriptModel.Source(version: { version }, read: {
            reads += 1
            return .init(lines: lines)
        })
        let model = LiveTranscriptModel(interval: .milliseconds(10))
        let task = Task { await model.run(source) }
        try await waitUntil("first read") { model.lines.count == 1 }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(reads, 1, "an unchanged source isn't read again")
        lines.append(line("Two", 1))
        version = 2
        try await waitUntil("second read") { model.lines.count == 2 }
        XCTAssertEqual(reads, 2)
        task.cancel()
        await task.value
        lines.append(line("Three", 2))
        version = 3
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(model.lines.count, 2, "closed: nothing reads")
    }

    func testBehaviorASourceWithoutAVersionIsComparedEachTime() async throws {
        var lines = [line("One", 0)]
        let model = LiveTranscriptModel(interval: .milliseconds(10))
        let task = Task { await model.run(.init(read: { .init(lines: lines) })) }
        try await waitUntil("first") { model.lines.count == 1 }
        lines[0].text = "One, revised"
        try await waitUntil("revised") { model.lines.first?.text == "One, revised" }
        task.cancel()
    }

    // MARK: Following

    func testBehaviorItFollowsTheNewestWordsUntilThePersonScrollsUpAndJumpsBack() {
        let model = LiveTranscriptModel()
        let content = CGSize(width: 400, height: 2_000), container = CGSize(width: 400, height: 500)
        XCTAssertTrue(model.isFollowing, "opens at the latest words")

        // At the bottom.
        model.scrolled(distanceFromLatest: 0, content: content, container: container)
        XCTAssertTrue(model.isFollowing)
        // New words make the content taller: its bottom moves away, which is not the person.
        model.scrolled(distanceFromLatest: 40, content: CGSize(width: 400, height: 2_040), container: container)
        XCTAssertTrue(model.isFollowing, "growing content doesn't stop following")
        model.scrolled(distanceFromLatest: 0, content: CGSize(width: 400, height: 2_040), container: container)
        XCTAssertTrue(model.isFollowing)

        // The person scrolls up to read.
        model.scrolled(distanceFromLatest: 120, content: CGSize(width: 400, height: 2_040), container: container)
        XCTAssertFalse(model.isFollowing, "stops following")
        model.scrolled(distanceFromLatest: 300, content: CGSize(width: 400, height: 2_040), container: container)
        XCTAssertFalse(model.isFollowing)
        // Words arriving while they read leave it where it is.
        model.scrolled(distanceFromLatest: 340, content: CGSize(width: 400, height: 2_080), container: container)
        XCTAssertFalse(model.isFollowing, "never taken back by arriving words")

        // The one control.
        let jumps = model.jumps
        model.jumpToLatest()
        XCTAssertTrue(model.isFollowing)
        XCTAssertEqual(model.jumps, jumps + 1)

        // The jump lands at the end; they scroll up again, then back down to the end themselves.
        model.scrolled(distanceFromLatest: 0, content: CGSize(width: 400, height: 2_080), container: container)
        model.scrolled(distanceFromLatest: 200, content: CGSize(width: 400, height: 2_080), container: container)
        XCTAssertFalse(model.isFollowing)
        model.scrolled(distanceFromLatest: 3, content: CGSize(width: 400, height: 2_080), container: container)
        XCTAssertTrue(model.isFollowing, "back at the latest")
    }

    func testBehaviorResizingTheViewIsNotScrollingAway() {
        let model = LiveTranscriptModel()
        model.scrolled(distanceFromLatest: 0, content: CGSize(width: 400, height: 2_000), container: CGSize(width: 400, height: 500))
        model.scrolled(distanceFromLatest: 200, content: CGSize(width: 400, height: 2_000), container: CGSize(width: 400, height: 300))
        XCTAssertTrue(model.isFollowing, "a smaller window moves the bottom away without the person scrolling")
    }
}
