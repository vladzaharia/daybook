import DaybookCaptions
import XCTest

/// Every source's captions of one recording put together as they arrive (`LiveCaptionMixer`): other devices'
/// lines moved onto this recording's timeline and labelled with their source, each utterance read once from
/// the source that heard it best, partial overlaps without doubled words, sticky verdicts, lines taken back,
/// and an incremental cost that doesn't grow with the recording.
final class LiveCaptionMixTests: XCTestCase {
    private func line(_ text: String, _ start: TimeInterval, _ end: TimeInterval, source: LiveCaptionSource? = nil,
                      tentative: Bool = false, id: UUID = UUID()) -> LiveCaptionSegment {
        LiveCaptionSegment(id: id, start: start, end: end, text: text, isTentative: tentative, source: source)
    }

    private let phone = LiveCaptionSource.device("phone")
    private let recorder = LiveCaptionSource.device("soundcore")

    func testAnotherDevicesLinesJoinOnThisRecordingsTimeline() async {
        let mixer = LiveCaptionMixer()
        await mixer.ownSources([.microphone, .call])
        _ = await mixer.heard([line("Can we start?", 1, 2)], from: .microphone)
        _ = await mixer.heard([line("The launch is on the fourteenth.", 8, 10)], from: .call)
        // The recorder began ten seconds before this Mac: its 15 s is this recording's 5 s.
        _ = await mixer.received([line("Before this Mac started recording.", 2, 6), line("Priya owns the checklist.", 15, 17)],
                                 from: recorder, offset: -10, changesOnly: false)
        let mixed = await mixer.lines()
        XCTAssertEqual(mixed.map(\.text), ["Can we start?", "Priya owns the checklist.", "The launch is on the fourteenth."])
        XCTAssertEqual(mixed[1].start, 5, accuracy: 0.001)
        XCTAssertEqual(mixed.map(\.source), [.microphone, recorder, .call], "several own sources keep their source")
        XCTAssertTrue(mixed[1].source?.isDevice == true)
        XCTAssertFalse(LiveCaptionSource.microphone.isDevice)
    }

    func testTheRoomHeardTwiceReadsOnce() async {
        let mixer = LiveCaptionMixer()
        await mixer.ownSources([.microphone])
        let own = line("So the launch moves to the fourteenth, and Priya owns the checklist.", 10, 14)
        _ = await mixer.heard([own], from: .microphone)
        // The phone in the same room, its clock a second off and its recognizer a little different.
        _ = await mixer.received([line("so the launch moves to the 14th and priya owns the check list", 9.5, 13.5),
                                  line("Sorry, could you repeat that?", 20, 21.5)], from: phone, offset: 1, changesOnly: true)
        let mixed = await mixer.lines()
        XCTAssertEqual(mixed.map(\.text), ["So the launch moves to the fourteenth, and Priya owns the checklist.", "Sorry, could you repeat that?"],
                       "one utterance, one line; only what this device didn't hear is added")
        XCTAssertNil(mixed[0].source, "one own source: its lines carry none")
        XCTAssertEqual(mixed[0].alsoHeard, [phone], "the phone heard it too, so its transcript replaces the line")
        XCTAssertEqual(mixed[1].source, phone)

        // Too far apart in time to be the same words.
        let late = LiveCaptionMixer()
        _ = await late.heard([own], from: .microphone)
        _ = await late.received([line("so the launch moves to the 14th and priya owns the check list", 9.5, 13.5)], from: phone,
                                offset: 30, changesOnly: true)
        let apart = await late.lines()
        XCTAssertEqual(apart.count, 2)
    }

    func testAPartialOverlapShowsEachWordOnce() async {
        let mixer = LiveCaptionMixer()
        _ = await mixer.heard([line("We still need legal to sign off", 19, 22)], from: .microphone)
        // The phone cut the same speech in another place: it began partway through this Mac's line and ran on.
        _ = await mixer.received([line("legal to sign off on the pricing page before Friday.", 20.5, 25)], from: phone,
                                 offset: 0, changesOnly: true)
        let mixed = await mixer.lines()
        XCTAssertEqual(mixed.map(\.text), ["We still need legal to sign off", "on the pricing page before Friday."])
        XCTAssertEqual(mixed.map(\.source), [nil, phone], "its new words, under its own label")
        XCTAssertEqual(mixed.flatMap { LiveCaptionMix.words($0.text) },
                       LiveCaptionMix.words("We still need legal to sign off on the pricing page before Friday"), "each word once")
        XCTAssertLessThan(mixed[0].start, mixed[1].start)

        // The other way round: the phone heard the beginning, this device the rest.
        let other = LiveCaptionMixer()
        _ = await other.received([line("We still need legal to sign off", 19, 22)], from: phone, offset: 0, changesOnly: true)
        _ = await other.heard([line("legal to sign off on the pricing page before Friday.", 20.5, 25)], from: .microphone)
        let reversed = await other.lines()
        XCTAssertEqual(reversed.flatMap { LiveCaptionMix.words($0.text) },
                       LiveCaptionMix.words("We still need legal to sign off on the pricing page before Friday"), "each word once")
    }

    func testThisDevicesTentativeRevisionsDontToggleAFeedLine() async {
        let mixer = LiveCaptionMixer()
        let heard = line("We still need legal to sign off on the pricing page.", 10, 14)
        _ = await mixer.received([heard], from: phone, offset: 0, changesOnly: true)
        let id = UUID()
        // This device's recognizer revises its line as the words come, some revisions matching the phone's, some not.
        for (text, end) in [("We", 10.4), ("We still", 10.8), ("We still need legal", 11.6), ("Wheat steel kneel", 11.8),
                            ("We still need legal to sign", 12.6), ("We still need legal to sign off on the", 13.4)] {
            _ = await mixer.heard([line(text, 10.1, end, tentative: true, id: id)], from: .microphone)
            let lines = await mixer.lines()
            XCTAssertEqual(lines.first { $0.id == heard.id }?.text, heard.text, "the phone's line stays as it is while \"\(text)\" is revised")
        }
        // Final, the utterance reads once: from this device (no levels to say otherwise), heard by the phone too.
        _ = await mixer.heard([line("We still need legal to sign off on the pricing page.", 10.1, 14.1, id: id)], from: .microphone)
        let settled = await mixer.lines()
        XCTAssertEqual(settled.map(\.text), ["We still need legal to sign off on the pricing page."])
        XCTAssertEqual(settled.first?.id, id)
        XCTAssertEqual(settled.first?.alsoHeard, [phone])
    }

    func testTheSourceThatHeardItLoudestReadsASettledUtterance() async {
        let mixer = LiveCaptionMixer()
        _ = await mixer.heard([line("the launch moves to the fourteenth", 10, 12.5)], from: .microphone,
                              levels: [.microphone: 0.2, phone: 0.7])
        _ = await mixer.received([line("The launch moves to the fourteenth.", 10.2, 12.6)], from: phone, offset: 0, changesOnly: true,
                                 levels: [.microphone: 0.2, phone: 0.7])
        let mixed = await mixer.lines()
        XCTAssertEqual(mixed.map(\.text), ["The launch moves to the fourteenth."], "the phone, nearer the speaker, heard it best")
        XCTAssertEqual(mixed.first?.source, phone)
        XCTAssertEqual(mixed.first?.alsoHeard, [.microphone])
    }

    func testTheCallReadsItsEchoAndHeadphonesKeepThemApart() async {
        let mixer = LiveCaptionMixer()
        await mixer.ownSources([.microphone, .call])
        _ = await mixer.heard([line("So the launch moves to the 14th, and Priya owns the checklist.", 10, 13.5)], from: .call)
        _ = await mixer.heard([line("so the launch moves to the fourteenth and priya owns the check list", 10.2, 13.8)], from: .microphone)
        var mixed = await mixer.lines()
        XCTAssertEqual(mixed.map(\.source), [.call], "the speakers' echo reads as the call")
        // Headphones from 30 s: the same words from the microphone are then something you said.
        _ = await mixer.echoes(false, from: 30)
        _ = await mixer.heard([line("So the launch moves to the 14th, and Priya owns the checklist.", 10, 13.5),
                               line("Legal signs off by Friday.", 40, 41.5)], from: .call)
        _ = await mixer.heard([line("so the launch moves to the fourteenth and priya owns the check list", 10.2, 13.8),
                               line("Legal signs off by Friday?", 41, 42.2)], from: .microphone)
        mixed = await mixer.lines()
        XCTAssertEqual(mixed.map(\.source), [.call, .call, .microphone])

        XCTAssertTrue(LiveCaptionMix.matches(LiveCaptionMix.words("we still need legal to sign off on the pricing page"),
                                             LiveCaptionMix.words("We still need legal to sign off on the pricing page before Friday.")))
        XCTAssertTrue(LiveCaptionMix.matches(LiveCaptionMix.words("Let’s see — legal to sign off the pricing page by Friday"),
                                             LiveCaptionMix.words("We still need legal to sign off on the pricing page before Friday.")),
                      "close enough to be the same words")
        XCTAssertFalse(LiveCaptionMix.matches(LiveCaptionMix.words("I can ask legal today."),
                                              LiveCaptionMix.words("We still need legal to sign off on the pricing page before Friday.")))
        XCTAssertEqual(LiveCaptionMix.words("Let’s go, Priya's 14th!"), ["lets", "go", "priyas", "14th"])
        XCTAssertEqual(LiveCaptionMix.sharedRun(["a", "b", "c", "d"], ["x", "a", "c", "y", "d"]), 3)
    }

    func testAPhonesChangesUpdateItsLinesInPlaceAndWhatItTakesBackLeaves() async {
        let mixer = LiveCaptionMixer()
        let first = line("We still need", 3, 4, tentative: true)
        _ = await mixer.received([first, line("Hello.", 1, 2)], from: phone, offset: 0, changesOnly: true)
        var revised = first
        revised.text = "We still need legal to sign off."
        revised.isTentative = false
        _ = await mixer.received([revised], from: phone, offset: 0, changesOnly: true)
        var mixed = await mixer.lines()
        XCTAssertEqual(mixed.map(\.text), ["Hello.", "We still need legal to sign off."])
        XCTAssertEqual(mixed.map(\.isTentative), [false, false])

        // A tentative line the phone's recognizer dropped is taken back.
        let dropped = line("and then", 5, 5.5, tentative: true)
        _ = await mixer.received([dropped], from: phone, offset: 0, changesOnly: true)
        _ = await mixer.received([], removed: [dropped.id], from: phone, offset: 0, changesOnly: true)
        mixed = await mixer.lines()
        XCTAssertEqual(mixed.map(\.text), ["Hello.", "We still need legal to sign off."])
        // A captioner's own list drops one too.
        _ = await mixer.heard([line("Mine", 6, 7, tentative: true)], from: .microphone)
        _ = await mixer.heard([], from: .microphone)
        let lines = await mixer.lines()
        XCTAssertEqual(lines.count, 2)
    }

    func testOnlyThisDevicesAndItsRecordersLinesGoOn() async {
        let mixer = LiveCaptionMixer()
        _ = await mixer.heard([line("Mine", 1, 2)], from: .microphone)
        _ = await mixer.received([line("The recorder's", 3, 4)], from: recorder, offset: 0, changesOnly: false)
        _ = await mixer.received([line("A Mac's call", 5, 6)], from: .device("mac:x:call"), offset: 0, changesOnly: true, forwards: false)
        let forwarded = await mixer.forwardable()
        XCTAssertEqual(forwarded.map(\.text), ["Mine", "The recorder's"])
    }

    // MARK: Cost

    /// Four hours of this device's microphone and three other devices' lines, then live updates at ten a second
    /// (this device's tentative line revised word by word, each device's changes a second at a time): each update
    /// costs under 2 ms on average, however long the recording is.
    func testFourHoursOfThreeFeedsUpdateInUnderTwoMillisecondsEach() async {
        let mixer = LiveCaptionMixer()
        await mixer.ownSources([.microphone])
        let vocabulary = ["the", "launch", "moves", "to", "fourteenth", "and", "priya", "owns", "checklist", "we", "still", "need", "legal",
                          "sign", "off", "on", "pricing", "page", "before", "friday", "send", "deck", "around", "after", "lunch", "budget",
                          "review", "quarter", "numbers", "team", "meeting", "plan", "next", "week", "customer", "feedback", "ship"]
        var generator = SeededGenerator(seed: 42)
        func sentence(_ count: Int) -> String { (0..<count).map { _ in vocabulary.randomElement(using: &generator)! }.joined(separator: " ") }
        let feeds = [phone, recorder, LiveCaptionSource.device("phone:2")]
        var own: [LiveCaptionSegment] = []
        var heard: [LiveCaptionSource: [LiveCaptionSegment]] = [:]
        var time: TimeInterval = 0
        while time < 4 * 3_600 {
            let count = Int.random(in: 6...22, using: &generator)
            let text = sentence(count), length = Double(count) * 0.35
            own.append(line(text, time, time + length))
            for (index, feed) in feeds.enumerated() where Int.random(in: 0..<10, using: &generator) < 7 {
                heard[feed, default: []].append(line(text, time + 0.3 * Double(index + 1), time + length + 0.3 * Double(index + 1)))
            }
            time += length + Double.random(in: 0.2...1.5, using: &generator)
        }
        // The four hours, as they'd have arrived: a minute at a time.
        var index = 0
        while index < own.count {
            let next = min(own.count, index + 20)
            _ = await mixer.heard(Array(own[..<next]), from: .microphone)
            let until = own[next - 1].end
            for feed in feeds {
                let lines = (heard[feed] ?? []).filter { $0.end <= until && $0.end > (index == 0 ? -1 : own[index - 1].end) }
                _ = await mixer.received(lines, from: feed, offset: 0, changesOnly: true)
            }
            index = next
        }
        // Then a minute live, ten updates a second: the processor time each takes (what the mixer costs, whatever
        // else the machine is doing), and the time each is waited for.
        let clock = ContinuousClock()
        var processor: UInt64 = 0
        var waits: [Duration] = []
        func measured(_ update: () async -> Void) async {
            let before = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
            waits.append(await clock.measure { await update() })
            processor += clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - before
        }
        var live = own
        var start = time
        for second in 0..<60 {
            live.append(line(sentence(1), start, start + 0.4, tentative: true))
            for tick in 0..<10 {
                // This device's tentative line, a word longer each time, final at the tenth.
                var tail = live[live.count - 1]
                tail.text = sentence(2 + tick)
                tail.end = tail.start + 0.35 * Double(2 + tick)
                tail.isTentative = tick < 9
                live[live.count - 1] = tail
                let snapshot = live
                await measured { _ = await mixer.heard(snapshot, from: .microphone, levels: [.microphone: 0.4]) }
                // Each other device's changes, a second at a time between them.
                if tick % 3 == 0 {
                    let feed = feeds[(second + tick / 3) % feeds.count]
                    let changed = line(sentence(8), start + 0.3, start + 3, tentative: tick < 9)
                    await measured { _ = await mixer.received([changed], from: feed, offset: 0, changesOnly: true) }
                }
            }
            start = live[live.count - 1].end + 0.5 + Double(second % 3) * 0.1
        }
        let average = Double(processor) / Double(waits.count) / 1e6
        XCTAssertLessThan(average, 2, "average processor time per update, in milliseconds")
        let median = waits.sorted()[waits.count / 2]
        XCTAssertLessThan(median, .milliseconds(2), "the median update waited for")
        let total = await mixer.lines().count
        XCTAssertGreaterThan(total, own.count, "four hours of lines, and the feeds' that added something")
    }
}

/// A repeatable random sequence, so the cost test runs on the same captions every time.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
