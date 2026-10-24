import AVFoundation
@testable import DaybookCaptions
import XCTest

/// The shared caption engine without speech recognition: assembling volatile and final results,
/// timing across gaps and bursts, converting any PCM format, scripted captioners running side by
/// side, and asking about availability (which never downloads).
final class LiveCaptionEngineTests: XCTestCase {
    func testTentativeTextIsReplacedInPlaceAndFinalTextStays() {
        var assembler = LiveCaptionAssembler()
        assembler.apply(text: "Okay let's", start: 0.5, end: 1.1, isFinal: false)
        let tentativeID = assembler.segments[0].id
        assembler.apply(text: "Okay, let's start", start: 0.5, end: 1.6, isFinal: false)
        XCTAssertEqual(assembler.segments.map(\.text), ["Okay, let's start"])
        XCTAssertEqual(assembler.segments[0].id, tentativeID, "revised in place, so a view doesn't flicker")
        assembler.apply(text: "Okay, let's start.", start: 0.5, end: 1.8, isFinal: true)
        assembler.apply(text: "It keeps", start: 2.0, end: 2.4, isFinal: false)
        XCTAssertEqual(assembler.segments.map(\.text), ["Okay, let's start.", "It keeps"])
        XCTAssertEqual(assembler.segments.map(\.isTentative), [false, true])
        XCTAssertFalse(assembler.apply(text: "It keeps", start: 2.0, end: 2.4, isFinal: false), "nothing new, nothing posted")
        assembler.apply(text: " ", start: 2.0, end: 2.4, isFinal: false)
        XCTAssertEqual(assembler.segments.map(\.text), ["Okay, let's start."], "a blank revision removes the tentative words")
        assembler.apply(text: "Then", start: 3, end: 3.2, isFinal: false)
        assembler.finalizeAll()
        XCTAssertEqual(assembler.segments.map(\.isTentative), [false, false])
    }

    func testTimesFollowTheSourceThroughAPause() {
        let map = CaptionTimeMap()
        // Ten seconds in 0.1 s buffers on a host clock, a 5 s pause, then more.
        for index in 0..<100 { map.feed(sourceTime: 1_000 + Double(index) * 0.1, duration: 0.1) }
        for index in 0..<20 { map.feed(sourceTime: 1_015 + Double(index) * 0.1, duration: 0.1) }
        XCTAssertEqual(map.sourceTime(4), 4, accuracy: 0.001)
        XCTAssertEqual(map.sourceTime(11), 16, accuracy: 0.001, "audio after the pause sits after it")
    }

    func testBurstsWithTheirOwnTimesKeepTheirPlaceAndUntimedAudioFollowsOn() {
        // A recorder sends 30 s of decoded audio at once, stamped by sample time from an arbitrary start.
        let map = CaptionTimeMap()
        for index in 0..<30 { map.feed(sourceTime: 120 + Double(index), duration: 1) }
        map.feed(sourceTime: nil, duration: 1)
        XCTAssertEqual(map.sourceTime(0), 0, accuracy: 0.001, "the first buffer is the origin")
        XCTAssertEqual(map.sourceTime(30.5), 30.5, accuracy: 0.001)
        let time = AVAudioTime(sampleTime: 96_000, atRate: 48_000)
        XCTAssertEqual(time.captionSeconds ?? 0, 2, accuracy: 0.0001)
    }

    func testAFixedOriginKeepsTheRecordingsTimeWhenTheOpeningWasDropped() {
        // A Mac's call track: buffers stamped in seconds since the recording began. The recognizer
        // was still starting for the first 3 s, so those buffers were dropped, never fed.
        let map = CaptionTimeMap(origin: 0)
        for index in 30..<100 { map.feed(sourceTime: Double(index) * 0.1, duration: 0.1) }
        XCTAssertEqual(map.sourceTime(0), 3, accuracy: 0.001, "the first audio heard sits where it was recorded")
        XCTAssertEqual(map.sourceTime(2), 5, accuracy: 0.001)
        let drifting = CaptionTimeMap()
        for index in 30..<100 { drifting.feed(sourceTime: Double(index) * 0.1, duration: 0.1) }
        XCTAssertEqual(drifting.sourceTime(0), 0, accuracy: 0.001, "without one, captions count from what was heard first")
    }

    func testSegmentsCarryTheirSourceAndCaptionsSavedWithoutOneStillDecode() throws {
        let you = LiveCaptionSegment(start: 1, end: 2, text: "I'll send the deck", isTentative: false, source: .microphone)
        let decoded = try JSONDecoder().decode(LiveCaptionSegment.self, from: JSONEncoder().encode(you))
        XCTAssertEqual(decoded, you)
        XCTAssertEqual(decoded.source, .microphone)
        // An iPhone's captions, saved before sources existed, and a source this version doesn't know.
        let phone = Data(#"{"id":"\#(UUID().uuidString)","start":0.5,"end":1.5,"text":"Okay","isTentative":false}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(LiveCaptionSegment.self, from: phone).source)
        let later = Data(#"{"id":"\#(UUID().uuidString)","start":0,"end":1,"text":"Hi","isTentative":true,"source":"room"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(LiveCaptionSegment.self, from: later).source?.rawValue, "room")
        // Without a source nothing is written for it, so the iPhone's files are unchanged.
        let plain = String(decoding: try JSONEncoder().encode(LiveCaptionSegment(start: 0, end: 1, text: "Hi", isTentative: false)), as: UTF8.self)
        XCTAssertFalse(plain.contains("source"))
    }

    func testAnyPCMFormatConvertsToTheAnalyzersFormat() throws {
        let output = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
        let converter = CaptionConverter(output: output)
        // A second of 0.1 s buffers in each format; the converter rebuilds itself when the format changes.
        // A resampler holds a few frames back between calls, so the total is checked, not each buffer.
        for (rate, channels) in [(48_000.0, AVAudioChannelCount(1)), (44_100, 2), (16_000, 1)] {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
            var total: AVAudioFrameCount = 0
            for _ in 0..<10 {
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate / 10)))
                buffer.frameLength = buffer.frameCapacity
                let converted = try XCTUnwrap(converter.convert(buffer), "\(rate) Hz × \(channels)")
                XCTAssertEqual(converted.format, output)
                total += converted.frameLength
            }
            XCTAssertEqual(Double(total), 16_000, accuracy: 400, "\(rate) Hz × \(channels)")
        }
    }

    func testScriptedCaptionersRunSideBySide() async throws {
        // A Mac captions You and Call separately: two captioners at once, each with its own segments.
        let you = ScriptedCaptioner(lines: [.init(at: 0, text: "I'll send the deck")], wordInterval: 0.01, leavesLastTentative: false)
        let call = ScriptedCaptioner(lines: [.init(at: 0, text: "Thanks, see you Friday")], wordInterval: 0.01, leavesLastTentative: false)
        async let a: [LiveCaptionSegment] = last(of: you.updates)
        async let b: [LiveCaptionSegment] = last(of: call.updates)
        await you.start(locale: Locale(identifier: "en_US"), sourceFormat: nil)
        await call.start(locale: Locale(identifier: "en_US"), sourceFormat: nil)
        try await Task.sleep(for: .milliseconds(400))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!, frameCapacity: 480))
        you.append(buffer, at: nil)
        await you.finish()
        await call.finish()
        let (youSegments, callSegments) = await (a, b)
        XCTAssertEqual(youSegments.map(\.text), ["I'll send the deck"])
        XCTAssertEqual(callSegments.map(\.text), ["Thanks, see you Friday"])
        XCTAssertEqual(you.buffersSeen, 1)
        XCTAssertEqual(call.buffersSeen, 0)
    }

    func testAskingAboutAvailabilityNeverDownloads() async {
        // Answers whatever this machine has; the only point is that it returns without installing anything.
        let availability = await LiveCaptionAvailability.check(locale: Locale(identifier: "en_US"))
        switch availability {
        case .ready, .needsDownload, .unavailable: break
        }
        XCTAssertEqual(LiveCaptionAvailability.name(Locale(identifier: "en_US")).isEmpty, false)
    }

    private func last(of stream: AsyncStream<[LiveCaptionSegment]>) async -> [LiveCaptionSegment] {
        var last: [LiveCaptionSegment] = []
        for await snapshot in stream { last = snapshot }
        return last
    }
}
