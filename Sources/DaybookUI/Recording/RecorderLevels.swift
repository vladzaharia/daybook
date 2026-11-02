import DaybookDesign
import Foundation
import Observation

/// The rolling meters' trails, one per source the recording has (`RecordingStatusWords.meters`), sampled fifteen
/// times a second while recording: on the Mac its level monitor for the microphone and the call, each recorder's
/// live audio, and the levels each iPhone sends over the link; on the iPhone its own microphone (a trail it feeds
/// itself, `adopt`) and each recorder's live audio. Only the meters read the trails, and `heard` changes only when a
/// source's levels start or stop arriving, so nothing else redraws as levels arrive.
@MainActor
@Observable
public final class RecorderLevels {
    /// Where each source's level comes from: 0…1 for a meter, or nil when it has none now.
    public struct Readers {
        public var microphone: @MainActor () -> Double?
        public var call: @MainActor () -> Double?
        public var recorder: @MainActor (String) -> Double?
        public var peer: @MainActor (String) -> Double?

        public init(microphone: @escaping @MainActor () -> Double? = { nil }, call: @escaping @MainActor () -> Double? = { nil },
                    recorder: @escaping @MainActor (String) -> Double? = { _ in nil }, peer: @escaping @MainActor (String) -> Double? = { _ in nil }) {
            self.microphone = microphone
            self.call = call
            self.recorder = recorder
            self.peer = peer
        }

        @MainActor
        public func read(_ source: RecorderMeter.Source) -> Double? {
            switch source {
            case .microphone: return microphone()
            case .call: return call()
            case .recorder(let id): return recorder(id)
            case .peer(let id): return peer(id)
            }
        }
    }

    /// The sources whose levels are arriving; the others' meters rest, flat.
    public private(set) var heard: Set<RecorderMeter.Source> = []
    @ObservationIgnored private var trails: [RecorderMeter.Source: LevelTrail] = [:]
    /// Trails fed elsewhere, at their own pace (the iPhone's microphone); never sampled here.
    @ObservationIgnored private var adopted: [RecorderMeter.Source: LevelTrail] = [:]
    @ObservationIgnored private var sources: [RecorderMeter.Source] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var readers: Readers?
    @ObservationIgnored private var synthetic = false
    @ObservationIgnored private var tick = 0
    public static let capacity = 160

    public init() {}

    public var isRunning: Bool { timer != nil }

    /// A source's trail, for its meter.
    public func trail(_ source: RecorderMeter.Source) -> LevelTrail {
        if let trail = adopted[source] ?? trails[source] { return trail }
        let trail = LevelTrail(capacity: Self.capacity)
        trails[source] = trail
        return trail
    }

    /// Draws `source` from a trail something else feeds; it counts as heard while running.
    public func adopt(_ trail: LevelTrail, for source: RecorderMeter.Source) {
        adopted[source] = trail
        trails[source] = nil
        if isRunning, sources.contains(source), !heard.contains(source) { heard.insert(source) }
    }

    /// The sources to sample: the recording's now. A source that joins starts flat; one that leaves drops its trail.
    public func follow(_ sources: [RecorderMeter.Source]) {
        guard sources != self.sources else { return }
        let joined = sources.filter { !self.sources.contains($0) }
        trails = trails.filter { sources.contains($0.key) }
        self.sources = sources
        // A simulated recording draws a conversation already under way, in every row.
        if synthetic, isRunning {
            for source in joined where adopted[source] == nil {
                let trail = trail(source)
                for back in stride(from: Self.capacity, to: 0, by: -1) { trail.append(Self.synthetic(source, tick: tick - back, in: sources)) }
            }
        }
        var heard = self.heard.intersection(sources)
        if isRunning { heard.formUnion(sources.filter { adopted[$0] != nil }) }
        if heard != self.heard { self.heard = heard }
    }

    /// Starts sampling through `readers`, or stops when `running` is false (the meters fall flat).
    public func run(_ running: Bool, readers: Readers, synthetic: Bool = false) {
        guard running else {
            timer?.invalidate()
            timer = nil
            self.readers = nil
            trails.values.forEach { $0.reset() }
            if !heard.isEmpty { heard = [] }
            return
        }
        guard timer == nil else { return }
        self.readers = readers
        self.synthetic = synthetic
        if synthetic {
            // A simulated recording has no audio: draw a plausible conversation, already under way.
            for _ in 0..<Self.capacity { sample() }
        }
        let timer = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let fed = Set(sources.filter { adopted[$0] != nil })
        if !fed.isSubset(of: heard) { heard.formUnion(fed) }
    }

    /// One reading from every source. A source with none now falls flat, then stops redrawing.
    public func sample() {
        tick &+= 1
        var heard: Set<RecorderMeter.Source> = []
        for source in sources {
            if adopted[source] != nil {
                heard.insert(source)
                continue
            }
            let trail = trail(source)
            let value = synthetic ? Self.synthetic(source, tick: tick, in: sources) : readers?.read(source)
            if let value {
                trail.append(value)
                heard.insert(source)
            } else if trail.values.contains(where: { $0 != 0 }) {
                trail.append(0)
            }
        }
        if heard != self.heard { self.heard = heard }
    }

    /// A stand-in level for each row of a simulated recording: you and the call take turns; a recorder in the room
    /// hears both (the call through the speakers, more quietly), and an iPhone beside you hears you, a little later
    /// and softer.
    private static func synthetic(_ source: RecorderMeter.Source, tick: Int, in sources: [RecorderMeter.Source]) -> Double {
        let t = Double(tick) / 15
        let offset = 0.37 * Double(sources.firstIndex(of: source) ?? 0)
        switch source {
        case .microphone: return speech(t, phase: 0)
        case .call: return speech(t, phase: 2.1)
        case .recorder: return min(1, 0.04 + 0.9 * max(speech(t, phase: offset), 0.55 * speech(t, phase: 2.1 + offset)))
        case .peer: return min(1, 0.05 + 0.8 * speech(t, phase: offset) * (0.8 + 0.2 * sin(t * 1.9)) + 0.2 * speech(t, phase: 2.1 + offset))
        }
    }

    /// Syllables in phrases, taking turns: a deterministic stand-in for speech.
    private static func speech(_ t: Double, phase: Double) -> Double {
        let turn = sin((t + phase) * 0.45) > -0.2 ? 1.0 : 0.15
        let phrase = sin((t + phase) * 1.3) > -0.55 ? 1.0 : 0.1
        let syllable = abs(sin((t + phase) * 7.7)) * (0.6 + 0.4 * abs(sin((t + phase) * 2.9 + 0.7)))
        return min(1, 0.06 + turn * phrase * (0.25 + 0.7 * syllable))
    }

    deinit { timer?.invalidate() }
}
