import AVFoundation
import Foundation

/// Reads a finalized capture or salvages a staged recording after a process exit.
/// Call only for directories that no active RecordingController is writing.
enum CaptureRecovery {
    static func recover(in directory: URL) throws -> CaptureResult? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let resultURL = directory.appendingPathComponent("capture-result.json")
        if FileManager.default.fileExists(atPath: resultURL.path) {
            var result = try decoder.decode(CaptureResult.self, from: Data(contentsOf: resultURL))
            result.directory = directory
            result.tracks = result.tracks.map { track in
                var track = track
                track.url = directory.appendingPathComponent(track.role.rawValue + ".caf")
                return track
            }
            return result
        }
        let manifestURL = directory.appendingPathComponent("capture-session.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        let manifest = try decoder.decode(CaptureSessionManifest.self, from: Data(contentsOf: manifestURL))
        var warnings = ["Recovered an interrupted recording. The final seconds may be incomplete."]
        var tracks: [CapturedAudioTrack] = []
        for role in [CapturedTrackRole.microphone, .systemAudio] {
            let audioURL = directory.appendingPathComponent(role.rawValue + ".caf")
            guard FileManager.default.fileExists(atPath: audioURL.path) else { continue }
            do {
                let audio = try AVAudioFile(forReading: audioURL)
                guard audio.length > 0 else { continue }
                let sidecar = directory.appendingPathComponent(role.rawValue + ".json")
                var track: CapturedAudioTrack
                if let data = try? Data(contentsOf: sidecar),
                   let saved = try? decoder.decode(CapturedAudioTrack.self, from: data) {
                    track = saved
                    track.url = audioURL
                } else {
                    warnings.append("The \(role.rawValue) timing metadata was unavailable; its start time is approximate.")
                    track = CapturedAudioTrack(role: role, url: audioURL, startedAt: manifest.startedAt,
                        firstSampleHostTimeSeconds: manifest.hostTimeSeconds, offsetSeconds: 0,
                        sampleRate: audio.processingFormat.sampleRate, channelCount: audio.processingFormat.channelCount, frameCount: audio.length)
                }
                // CAF is authoritative: the periodic sidecar can trail durable audio.
                track.frameCount = audio.length
                track.sampleRate = audio.processingFormat.sampleRate
                track.channelCount = audio.processingFormat.channelCount
                tracks.append(track)
            } catch {
                warnings.append("Could not recover \(role.rawValue): \(error.localizedDescription)")
            }
        }
        let endedAt = tracks.map { $0.startedAt.addingTimeInterval($0.duration) }.max() ?? manifest.startedAt
        return CaptureResult(id: manifest.id, startedAt: manifest.startedAt, endedAt: endedAt,
                             tracks: tracks, warnings: warnings, directory: directory)
    }
}
