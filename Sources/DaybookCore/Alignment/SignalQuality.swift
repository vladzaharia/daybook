import Foundation

/// Estimated signal-to-noise ratio along a recording, one value per `interval` of its own clock.
/// Fusion uses it to prefer the clearer source where several heard the same speech.
public struct SignalQualityProfile: Codable, Equatable, Sendable {
    public var interval: TimeInterval
    /// Speech level over the local background level, dB (0 where nothing stands out).
    public var snr: [Float]
    public init(interval: TimeInterval, snr: [Float]) { self.interval = interval; self.snr = snr }

    /// The estimate at a time in the recording's own seconds; nil outside it.
    public func snr(at time: TimeInterval) -> Float? {
        guard interval > 0, time.isFinite, time >= 0 else { return nil }
        let index = Int(time / interval)
        return index < snr.count ? snr[index] : nil
    }

    /// Speech level: the 90th percentile of frame levels within ±1 s. Background: the 10th
    /// percentile within ±15 s. Uncalibrated, but comparable between sources of the same event.
    public static func measure(_ features: AudioFeatures, interval: TimeInterval = 1) -> SignalQualityProfile {
        let perInterval = max(1, Int(interval * AudioFeatures.frameRate))
        let count = (features.level.count + perInterval - 1) / perInterval
        guard count > 0 else { return SignalQualityProfile(interval: interval, snr: []) }
        var high = [Float](repeating: -100, count: count), low = [Float](repeating: -100, count: count)
        for index in 0..<count {
            let slice = features.level[(index * perInterval)..<min(features.level.count, (index + 1) * perInterval)].sorted()
            high[index] = slice[min(slice.count - 1, slice.count * 9 / 10)]
            low[index] = slice[slice.count / 10]
        }
        let speechRadius = max(1, Int(1 / interval)), noiseRadius = max(1, Int(15 / interval))
        let snr = (0..<count).map { index -> Float in
            let speech = high[max(0, index - speechRadius)...min(count - 1, index + speechRadius)].max() ?? -100
            let floor = low[max(0, index - noiseRadius)...min(count - 1, index + noiseRadius)].min() ?? -100
            return max(0, min(60, speech - floor))
        }
        return SignalQualityProfile(interval: interval, snr: snr)
    }
}

extension AudioAligner {
    /// Signal-to-noise profile of a recording, reusing cached alignment features.
    public static func signalQuality(of url: URL, digest: String? = nil, cache: AudioFeatureCache? = .shared) throws -> SignalQualityProfile {
        let features = try cache?.features(for: url, digest: digest) ?? AudioFeatures.extract(from: url)
        return SignalQualityProfile.measure(features)
    }
}
