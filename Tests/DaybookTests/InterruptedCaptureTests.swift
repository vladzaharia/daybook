import AVFoundation
import DaybookCore
import DaybookTestSupport
import Foundation
import XCTest
@testable import Daybook

/// A Mac recording that never reached capture-result.json (the app quit or crashed while recording,
/// or while importing it): what `CaptureRecovery` salvages from the staged files, and what opening
/// the library imports from it. Synthetic tones in temporary folders.
@MainActor
final class InterruptedCaptureTests: XCTestCase {
    private let manifest = CaptureSessionManifest(id: UUID(), startedAt: Date(timeIntervalSince1970: 1_700_000_000.5), hostTimeSeconds: 50,
                                                  includeSystemAudio: true)

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookInterrupted-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func tone(seconds: Double, rate: Double, channels: AVAudioChannelCount, frequency: Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for index in 0..<Int(frames) {
                buffer.floatChannelData![channel][index] = Float(0.2 * sin(2 * .pi * frequency * Double(index) / rate))
            }
        }
        return buffer
    }

    /// Writes `buffers` tenths of a second through the real track writer, starting at `hostTime`.
    private func record(_ role: CapturedTrackRole, in directory: URL, buffers: Int, hostTime: TimeInterval, rate: Double,
                        channels: AVAudioChannelCount, frequency: Double, finish: Bool = true) async -> PCMTrackWriter {
        let writer = PCMTrackWriter(role: role, directory: directory, manifest: manifest) { XCTFail($0.localizedDescription) }
        for index in 0..<buffers {
            writer.append(tone(seconds: 0.1, rate: rate, channels: channels, frequency: frequency), hostTimeSeconds: hostTime + Double(index) * 0.1)
        }
        await writer.waitUntilWritten()
        if finish { _ = await writer.finish() }
        return writer
    }

    /// The microphone (16 kHz mono, 2 s from 0.2 s in) and the call (48 kHz stereo, 1.5 s from
    /// 0.25 s in), staged as a recording leaves them: no capture-result.json.
    private func stageInterrupted(in directory: URL) async throws {
        try CaptureJSON.persist(manifest, at: directory.appendingPathComponent("capture-session.json"))
        _ = await record(.microphone, in: directory, buffers: 20, hostTime: 50.2, rate: 16_000, channels: 1, frequency: 440)
        _ = await record(.systemAudio, in: directory, buffers: 15, hostTime: 50.25, rate: 48_000, channels: 2, frequency: 660)
    }

    // MARK: Recovering the staged files

    func testBothTracksComeBackWithTheirOwnTimingWithoutTheResultFile() async throws {
        let directory = try temporaryDirectory()
        try await stageInterrupted(in: directory)
        let recovered = try XCTUnwrap(CaptureRecovery.recover(in: directory))
        XCTAssertEqual(recovered.id, manifest.id)
        XCTAssertEqual(recovered.startedAt, manifest.startedAt)
        XCTAssertEqual(recovered.tracks.map(\.role), [.microphone, .systemAudio])
        let microphone = recovered.tracks[0], call = recovered.tracks[1]
        XCTAssertEqual(microphone.frameCount, 32_000)
        XCTAssertEqual(microphone.sampleRate, 16_000)
        XCTAssertEqual(microphone.channelCount, 1)
        XCTAssertEqual(microphone.offsetSeconds, 0.2, accuracy: 1e-6)
        XCTAssertEqual(call.frameCount, 72_000)
        XCTAssertEqual(call.sampleRate, 48_000)
        XCTAssertEqual(call.channelCount, 2)
        XCTAssertEqual(call.offsetSeconds, 0.25, accuracy: 1e-6)
        XCTAssertEqual(call.startedAt.timeIntervalSince(manifest.startedAt), 0.25, accuracy: 1e-6)
        XCTAssertEqual(microphone.url, directory.appendingPathComponent("microphone.caf"))
        XCTAssertNotNil(call.clockAnchors, "anchors survive, so drift correction still works")
        // The later of the two ends: the microphone, 0.2 s + 2 s in.
        XCTAssertEqual(recovered.endedAt.timeIntervalSince(manifest.startedAt), 2.2, accuracy: 1e-3)
        XCTAssertEqual(recovered.warnings, ["Recovered an interrupted recording. The final seconds may be incomplete."])
    }

    func testATrackWhoseSidecarIsMissingStartsWithTheRecordingAndSaysSo() async throws {
        let directory = try temporaryDirectory()
        try await stageInterrupted(in: directory)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("systemAudio.json"))
        let recovered = try XCTUnwrap(CaptureRecovery.recover(in: directory))
        XCTAssertEqual(recovered.tracks.count, 2)
        let microphone = recovered.tracks[0], call = recovered.tracks[1]
        XCTAssertEqual(microphone.offsetSeconds, 0.2, accuracy: 1e-6, "the track with its sidecar keeps its timing")
        XCTAssertEqual(call.role, .systemAudio)
        XCTAssertEqual(call.startedAt, manifest.startedAt)
        XCTAssertEqual(call.offsetSeconds, 0)
        XCTAssertEqual(call.firstSampleHostTimeSeconds, manifest.hostTimeSeconds)
        XCTAssertEqual(call.frameCount, 72_000, "the audio file says how long it is")
        XCTAssertEqual(call.sampleRate, 48_000)
        XCTAssertEqual(call.channelCount, 2)
        XCTAssertNil(call.clockAnchors)
        XCTAssertTrue(recovered.warnings.contains("The call audio recording’s start time is approximate."), "\(recovered.warnings)")
        XCTAssertTrue(call.notes?.contains { $0.contains("timing file was missing") } == true,
                      "What went wrong is in the capture notes, not the conversation's notice")

        // A damaged sidecar is the same as a missing one.
        try Data("{\"role\":".utf8).write(to: directory.appendingPathComponent("microphone.json"))
        let again = try XCTUnwrap(CaptureRecovery.recover(in: directory))
        XCTAssertEqual(again.tracks.first?.offsetSeconds, 0)
        XCTAssertTrue(again.warnings.contains("The microphone recording’s start time is approximate."))
    }

    func testAnAudioFileThatWasNeverClosedIsReadAsFarAsItReachedTheDisk() async throws {
        let live = try temporaryDirectory(), crashed = try temporaryDirectory()
        try CaptureJSON.persist(manifest, at: live.appendingPathComponent("capture-session.json"))
        // Thirty seconds of host time, so the sidecar (saved every ten) trails the audio.
        let writer = await record(.microphone, in: live, buffers: 300, hostTime: 50.2, rate: 16_000, channels: 1, frequency: 440,
                                  finish: false)
        // The process dies here: the files as they are on disk, the writer never finished.
        for name in ["capture-session.json", "microphone.caf", "microphone.json"] {
            try FileManager.default.copyItem(at: live.appendingPathComponent(name), to: crashed.appendingPathComponent(name))
        }
        _ = await writer.finish()

        XCTAssertEqual(try cafDataChunkSize(crashed.appendingPathComponent("microphone.caf")), -1,
                       "an open CAF hasn't recorded how much audio it holds")
        let sidecar = try CaptureJSON.decoder().decode(CapturedAudioTrack.self, from: Data(contentsOf: crashed.appendingPathComponent("microphone.json")))
        let onDisk = try AVAudioFile(forReading: crashed.appendingPathComponent("microphone.caf")).length
        let recovered = try XCTUnwrap(CaptureRecovery.recover(in: crashed))
        let track = try XCTUnwrap(recovered.tracks.first)
        XCTAssertEqual(track.frameCount, onDisk)
        XCTAssertGreaterThan(track.frameCount, sidecar.frameCount, "the audio file, not the trailing sidecar, says how long it is")
        XCTAssertLessThanOrEqual(track.frameCount, 480_000)
        XCTAssertGreaterThan(track.frameCount, 0)
        XCTAssertEqual(track.offsetSeconds, 0.2, accuracy: 1e-6)
        XCTAssertEqual(track.clockAnchors?.first?.hostTime, 50.2)
    }

    /// The size field of a CAF's audio data chunk: -1 while it's being written, the byte count once
    /// it's closed.
    private func cafDataChunkSize(_ url: URL) throws -> Int64 {
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(bytes.prefix(4), Data("caff".utf8))
        var offset = 8
        while offset + 12 <= bytes.count {
            let type = String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
            let size = bytes[(offset + 4)..<(offset + 12)].reduce(Int64(0)) { $0 << 8 | Int64($1) }
            if type == "data" { return size }
            guard size >= 0 else { break }
            offset += 12 + Int(size)
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    // MARK: Importing it when the library opens

    private func openLibrary(_ root: URL, _ defaults: UserDefaults) async -> AppState {
        let state = AppState(libraryURL: root, defaults: defaults)
        await state.initialize()
        await state.flush()
        return state
    }

    private func copyFolder(_ from: URL, to: URL) throws {
        try? FileManager.default.removeItem(at: to)
        try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: from, to: to)
    }

    /// The app imported the recording but died before removing the staged files: opening the library
    /// again imports nothing twice.
    func testRecoveringAgainAfterACrashBeforeCleanupAddsNoSecondCopy() async throws {
        let root = try temporaryDirectory(), backup = try temporaryDirectory()
        let defaults = makeTestDefaults()
        let staging = root.appendingPathComponent("Staging/\(manifest.id.uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try await stageInterrupted(in: staging)
        try copyFolder(staging, to: backup.appendingPathComponent("staged"))

        let first = await openLibrary(root, defaults)
        let recovered = try XCTUnwrap(first.meetings.first { $0.id == manifest.id })
        XCTAssertEqual(first.meetings.count, 1)
        XCTAssertEqual(Set(recovered.tracks.map(\.source)), [.microphone, .systemAudio])
        XCTAssertEqual(recovered.tracks.filter { $0.derivedFrom == nil }.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))

        try copyFolder(backup.appendingPathComponent("staged"), to: staging)
        let second = await openLibrary(root, defaults)
        let again = try XCTUnwrap(second.meetings.first { $0.id == manifest.id })
        XCTAssertEqual(second.meetings.count, 1, "no second conversation")
        XCTAssertEqual(again.tracks.map(\.id), recovered.tracks.map(\.id), "no second copy of any recording")
        XCTAssertEqual(again.tracks.map(\.sha256), recovered.tracks.map(\.sha256))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path), "and the staged files are cleaned up this time")
    }

    /// The app imported the microphone and died before the call track: opening the library again
    /// adds the call, and the microphone only once.
    func testRecoveringAgainAfterACrashMidImportAddsOnlyWhatWasMissing() async throws {
        let root = try temporaryDirectory(), backup = try temporaryDirectory()
        let defaults = makeTestDefaults()
        let staging = root.appendingPathComponent("Staging/\(manifest.id.uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try await stageInterrupted(in: staging)
        try copyFolder(staging, to: backup.appendingPathComponent("staged"))
        // What the first, interrupted import got to: the microphone alone.
        for name in ["systemAudio.caf", "systemAudio.json"] { try FileManager.default.removeItem(at: staging.appendingPathComponent(name)) }
        let first = await openLibrary(root, defaults)
        let partial = try XCTUnwrap(first.meetings.first { $0.id == manifest.id })
        XCTAssertEqual(partial.tracks.map(\.source), [.microphone])
        let microphone = try XCTUnwrap(partial.tracks.first)

        try copyFolder(backup.appendingPathComponent("staged"), to: staging)
        let second = await openLibrary(root, defaults)
        let complete = try XCTUnwrap(second.meetings.first { $0.id == manifest.id })
        XCTAssertEqual(second.meetings.count, 1)
        let originals = complete.tracks.filter { $0.derivedFrom == nil }
        XCTAssertEqual(originals.filter { $0.source == .microphone }.map(\.id), [microphone.id], "the microphone once, as it was")
        XCTAssertEqual(originals.filter { $0.source == .systemAudio }.count, 1, "the call, added now")
        for derived in complete.tracks where derived.derivedFrom != nil {
            XCTAssertEqual(derived.derivedFrom, microphone.id, "anything derived points at the microphone already there")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }
}
