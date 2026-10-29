import AVFoundation
import Foundation
import Speech

/// Turns live audio into tentative captions, from any source: an iPhone recording, a Mac's
/// microphone or call, a recorder's live listening. A captioner never blocks or fails the capture it
/// listens to: `append` is cheap and callable from an audio thread (audio is dropped when the
/// recognizer falls behind), and any failure ends only the captions (`states`).
///
/// Each instance is independent; several can run at once (a Mac captions You and Call separately).
public protocol LiveCaptioning: AnyObject, Sendable {
    /// The whole segment list each time it changes: tentative text replaced in place, then final.
    var updates: AsyncStream<[LiveCaptionSegment]> { get }
    var states: AsyncStream<LiveCaptionState> { get }
    /// Begins listening in `locale`. `sourceFormat` is the audio's format when known (it may change;
    /// buffers carry their own). Returns once captioning runs, or has said why it can't.
    func start(locale: Locale, sourceFormat: AVAudioFormat?) async
    /// One buffer of any PCM format. `time` places it on the source's own timeline from an arbitrary
    /// start (sample time at its rate, or host time); nil follows on from the previous buffer.
    func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?)
    /// The audio ended: finish what was heard, keep it as final, and stop.
    func finish() async
}

extension AVAudioTime {
    /// Seconds on the source's timeline: sample time at its rate when valid, else host time.
    var captionSeconds: TimeInterval? {
        if isSampleTimeValid, sampleRate > 0 { return Double(sampleTime) / sampleRate }
        if isHostTimeValid { return AVAudioTime.seconds(forHostTime: hostTime) }
        return nil
    }
}

// MARK: Availability and authorization

/// Whether captions can run for a language: ready, after a system download, or not at all. Asking
/// never downloads anything.
public enum LiveCaptionAvailability: Equatable, Sendable {
    case ready(Locale)
    case needsDownload(Locale)
    case unavailable(String)

    public static func check(locale: Locale) async -> LiveCaptionAvailability {
        guard #available(macOS 26, iOS 26, *) else { return .unavailable("Live captions need a newer system.") }
        return await check(locale: locale, asking: .system)
    }

    /// What `check` asks the system: questions only. Nothing here can request or install an asset,
    /// which is how asking never downloads. Tests answer for the system.
    struct Questions: Sendable {
        enum ModelStatus: Sendable { case installed, notInstalled, unsupported }
        var deviceSupportsCaptions: @Sendable () -> Bool
        var supportedLocale: @Sendable (Locale) async -> Locale?
        var modelStatus: @Sendable (Locale) async -> ModelStatus

        @available(macOS 26, iOS 26, *)
        static var system: Questions {
            Questions(deviceSupportsCaptions: { SpeechTranscriber.isAvailable },
                      supportedLocale: { await SpeechTranscriber.supportedLocale(equivalentTo: $0) },
                      modelStatus: { locale in
                          switch await AssetInventory.status(forModules: [SpeechCaptioner.transcriber(locale: locale)]) {
                          case .installed: return .installed
                          case .supported, .downloading: return .notInstalled
                          case .unsupported: return .unsupported
                          @unknown default: return .unsupported
                          }
                      })
        }
    }

    static func check(locale: Locale, asking system: Questions) async -> LiveCaptionAvailability {
        guard system.deviceSupportsCaptions() else { return .unavailable("Live captions aren’t available on this device.") }
        guard let supported = await system.supportedLocale(locale) else {
            return .unavailable("Captions aren’t available for \(name(locale)).")
        }
        switch await system.modelStatus(supported) {
        case .installed: return .ready(supported)
        case .notInstalled: return .needsDownload(supported)
        case .unsupported: return .unavailable("Captions aren’t available for \(name(locale)).")
        }
    }

    /// Languages captions can use, by name.
    public static func supportedLocales() async -> [Locale] {
        guard #available(macOS 26, iOS 26, *), SpeechTranscriber.isAvailable else { return [] }
        return await SpeechTranscriber.supportedLocales.sorted { name($0) < name($1) }
    }

    /// "English (United States)".
    public static func name(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    public var locale: Locale? {
        switch self {
        case .ready(let locale), .needsDownload(let locale): return locale
        case .unavailable: return nil
        }
    }
}

/// Speech-recognition authorization (`SFSpeechRecognizer`). `SpeechAnalyzer` with `SpeechTranscriber`
/// runs on the device, and the system doesn't say up front whether it also needs this authorization
/// (it couldn't be exercised here: the simulator has no transcriber, and this Mac's wasn't run to
/// avoid a privacy prompt). So `SpeechCaptioner` doesn't ask at launch or at start: only when the
/// analyzer fails before any result while authorization is undetermined does it ask once (if the app
/// allows) and try again. Apps that allow it declare `NSSpeechRecognitionUsageDescription`.
public enum LiveCaptionAuthorization {
    public static var status: SFSpeechRecognizerAuthorizationStatus { SFSpeechRecognizer.authorizationStatus() }

    /// Asks once; returns whether captions may run. Needs `NSSpeechRecognitionUsageDescription`.
    public static func request() async -> Bool {
        if status == .authorized { return true }
        return await withCheckedContinuation { done in
            SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0 == .authorized) }
        }
    }
}

// MARK: Speech framework

/// Live captions from the Speech framework, on this device only: `SpeechAnalyzer` with a
/// `SpeechTranscriber` reporting volatile and fast results with audio time ranges.
///
/// - Input of any PCM format is converted on a utility task to
///   `SpeechAnalyzer.bestAvailableAudioFormat`; up to `backlog` buffers wait, and the oldest are
///   dropped when the recognizer falls behind (raise it for sources that arrive in bursts).
/// - Speech assets are system-managed (`AssetInventory`): installation is requested only when
///   `allowsDownload` (a person turned captions on and is recording), never in tests or demos.
@available(macOS 26, iOS 26, *)
public final class SpeechCaptioner: LiveCaptioning, @unchecked Sendable {
    public let updates: AsyncStream<[LiveCaptionSegment]>
    public let states: AsyncStream<LiveCaptionState>
    private let updatesContinuation: AsyncStream<[LiveCaptionSegment]>.Continuation
    private let statesContinuation: AsyncStream<LiveCaptionState>.Continuation
    private let input: AsyncStream<(AVAudioPCMBuffer, TimeInterval?)>
    private let inputContinuation: AsyncStream<(AVAudioPCMBuffer, TimeInterval?)>.Continuation
    private let allowsDownload: Bool
    private let asksForAuthorization: Bool
    private var askedForAuthorization = false
    private var heardAnything = false
    private let times: CaptionTimeMap
    private let lock = NSLock()
    private var assembler = LiveCaptionAssembler()
    private var analyzer: SpeechAnalyzer?
    private var feeding: Task<Void, Never>?
    private var listening: Task<Void, Never>?
    private var started = false

    /// `asksForAuthorization`: if the analyzer fails before any result while speech-recognition
    /// authorization is undetermined, ask once and try again (see `LiveCaptionAuthorization`).
    /// `timelineOrigin`: the buffers' time that captions count from (`CaptionTimeMap`); nil counts
    /// from the first buffer heard.
    public init(allowsDownload: Bool, asksForAuthorization: Bool = false, backlog: Int = 64, timelineOrigin: TimeInterval? = nil) {
        self.allowsDownload = allowsDownload
        self.asksForAuthorization = asksForAuthorization
        times = CaptionTimeMap(origin: timelineOrigin)
        (updates, updatesContinuation) = AsyncStream<[LiveCaptionSegment]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        (states, statesContinuation) = AsyncStream<LiveCaptionState>.makeStream(bufferingPolicy: .bufferingNewest(8))
        (input, inputContinuation) = AsyncStream<(AVAudioPCMBuffer, TimeInterval?)>.makeStream(bufferingPolicy: .bufferingNewest(backlog))
    }

    /// The transcriber Daybook uses: volatile and fast results, with each result's audio time range.
    public static func transcriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
                          attributeOptions: [.audioTimeRange])
    }

    public func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) {
        inputContinuation.yield((buffer, time?.captionSeconds))
    }

    public func start(locale: Locale, sourceFormat: AVAudioFormat?) async {
        guard lock.withLock({ () -> Bool in defer { started = true }; return !started }) else { return }
        statesContinuation.yield(.preparing)
        switch await LiveCaptionAvailability.check(locale: locale) {
        case .unavailable(let reason):
            end(.unavailable(reason))
        case .needsDownload(let supported):
            guard allowsDownload else {
                end(.unavailable("Captions for \(LiveCaptionAvailability.name(supported)) need a download, which starts when you record with captions on."))
                return
            }
            do {
                let modules: [any SpeechModule] = [Self.transcriber(locale: supported)]
                if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                    statesContinuation.yield(.downloading(nil))
                    let progress = request.progress, states = statesContinuation
                    let watcher = Task {
                        while !Task.isCancelled {
                            states.yield(.downloading(progress.totalUnitCount > 0 ? progress.fractionCompleted : nil))
                            try? await Task.sleep(for: .seconds(1))
                        }
                    }
                    defer { watcher.cancel() }
                    try await request.downloadAndInstall()
                }
                await run(locale: supported, sourceFormat: sourceFormat)
            } catch {
                end(.failed("The captions download didn’t finish: \(error.localizedDescription)"))
            }
        case .ready(let supported):
            await run(locale: supported, sourceFormat: sourceFormat)
        }
    }

    private func run(locale: Locale, sourceFormat: AVAudioFormat?) async {
        let transcriber = Self.transcriber(locale: locale)
        let modules: [any SpeechModule] = [transcriber]
        do {
            guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules, considering: sourceFormat) else {
                end(.unavailable("Live captions can’t use this audio."))
                return
            }
            let analyzer = SpeechAnalyzer(modules: modules, options: SpeechAnalyzer.Options(priority: .utility, modelRetention: .whileInUse))
            let (analyzerInputs, analyzerContinuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
            try await analyzer.prepareToAnalyze(in: analyzerFormat)
            try await analyzer.start(inputSequence: analyzerInputs)
            lock.withLock { self.analyzer = analyzer }
            let times = self.times, input = self.input
            feeding = Task.detached(priority: .utility) {
                let converter = CaptionConverter(output: analyzerFormat)
                for await (buffer, time) in input {
                    times.feed(sourceTime: time, duration: Double(buffer.frameLength) / buffer.format.sampleRate)
                    // A buffer that won't convert is skipped; the capture has it regardless.
                    if let converted = converter.convert(buffer) { analyzerContinuation.yield(AnalyzerInput(buffer: converted)) }
                }
                analyzerContinuation.finish()
            }
            listening = Task.detached(priority: .utility) { [weak self] in
                do {
                    for try await result in transcriber.results {
                        self?.receive(text: String(result.text.characters), start: times.sourceTime(result.range.start.seconds),
                                      end: times.sourceTime(result.range.end.seconds), isFinal: result.isFinal)
                    }
                } catch is CancellationError {
                } catch {
                    self?.end(.failed("Captions stopped: \(error.localizedDescription)"))
                }
            }
            statesContinuation.yield(.listening)
        } catch {
            if await authorizeAfterFailure() { return await run(locale: locale, sourceFormat: sourceFormat) }
            end(.failed("Captions couldn’t start: \(error.localizedDescription)"))
        }
    }

    /// The analyzer failed before hearing anything: if speech-recognition authorization is
    /// undetermined and the app allows it, ask once. Returns whether to try again.
    private func authorizeAfterFailure() async -> Bool {
        let ask = lock.withLock { () -> Bool in
            guard asksForAuthorization, !askedForAuthorization, !heardAnything else { return false }
            askedForAuthorization = true
            return true
        }
        guard ask, LiveCaptionAuthorization.status == .notDetermined else { return false }
        return await LiveCaptionAuthorization.request()
    }

    private func receive(text: String, start: TimeInterval, end: TimeInterval, isFinal: Bool) {
        let snapshot = lock.withLock { () -> [LiveCaptionSegment]? in
            heardAnything = true
            return assembler.apply(text: text, start: start, end: end, isFinal: isFinal) ? assembler.segments : nil
        }
        if let snapshot { updatesContinuation.yield(snapshot) }
    }

    public func finish() async {
        inputContinuation.finish()
        await feeding?.value
        let analyzer = lock.withLock { self.analyzer }
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await listening?.value
        let snapshot = lock.withLock { () -> [LiveCaptionSegment] in assembler.finalizeAll(); return assembler.segments }
        updatesContinuation.yield(snapshot)
        end(.finished)
    }

    private func end(_ state: LiveCaptionState) {
        statesContinuation.yield(state)
        if state == .finished || !state.isActive {
            if state == .finished { updatesContinuation.finish(); statesContinuation.finish() }
            inputContinuation.finish()
        }
    }
}

/// Converts any PCM buffer to the analyzer's format, rebuilding the converter when the input format
/// changes (an audio route change, a recorder at its own rate). The converter keeps its state between
/// buffers, so resampling small buffers back to back leaves no seams. Several channels are mixed
/// down, not dropped. Use from one task at a time.
public final class CaptionConverter: @unchecked Sendable {
    private let output: AVAudioFormat
    private var converter: AVAudioConverter?
    private var input: AVAudioFormat?

    public init(output: AVAudioFormat) { self.output = output }

    public func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        if buffer.format == output { return buffer }
        if input != buffer.format || converter == nil {
            converter = AVAudioConverter(from: buffer.format, to: output)
            converter?.downmix = buffer.format.channelCount > output.channelCount
            input = buffer.format
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * output.sampleRate / buffer.format.sampleRate).rounded(.up)) + 32
        guard let result = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: result, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, result.frameLength > 0 else { return nil }
        return result
    }
}

// MARK: Scripted captions

/// Captions from a script, for demos (`--demo-captions`) and tests: each line arrives word by word as
/// tentative text, then becomes final. Ignores the audio, but counts it.
public final class ScriptedCaptioner: LiveCaptioning, @unchecked Sendable {
    public struct Line: Sendable {
        public var at: TimeInterval
        public var text: String
        public init(at: TimeInterval, text: String) { self.at = at; self.text = text }
    }

    public let updates: AsyncStream<[LiveCaptionSegment]>
    public let states: AsyncStream<LiveCaptionState>
    private let updatesContinuation: AsyncStream<[LiveCaptionSegment]>.Continuation
    private let statesContinuation: AsyncStream<LiveCaptionState>.Continuation
    private let lines: [Line]
    private let wordInterval: TimeInterval
    /// Holds the last line tentative (a sentence still being heard), as on a live screen.
    private let leavesLastTentative: Bool
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var assembler = LiveCaptionAssembler()
    private var buffers = 0

    public init(lines: [Line], wordInterval: TimeInterval = 0.3, leavesLastTentative: Bool = true) {
        self.lines = lines
        self.wordInterval = wordInterval
        self.leavesLastTentative = leavesLastTentative
        (updates, updatesContinuation) = AsyncStream<[LiveCaptionSegment]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        (states, statesContinuation) = AsyncStream<LiveCaptionState>.makeStream(bufferingPolicy: .bufferingNewest(8))
    }

    /// Buffers appended so far.
    public var buffersSeen: Int { lock.withLock { buffers } }

    /// A short meeting, in step with the iPhone app's `--demo-notes`.
    public static func demo() -> ScriptedCaptioner {
        ScriptedCaptioner(lines: [
            Line(at: 0.6, text: "Okay, let's start with what the phone app records on its own."),
            Line(at: 4.2, text: "It keeps recording with the screen locked, and a call pauses it."),
            Line(at: 8.4, text: "Then everything waits for the Mac to transcribe."),
            Line(at: 11.6, text: "Can we measure both displays on the Duo before we fix the layout constants?"),
        ])
    }

    public func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) {
        lock.withLock { buffers += 1 }
    }

    public func start(locale: Locale, sourceFormat: AVAudioFormat?) async {
        statesContinuation.yield(.listening)
        let lines = self.lines, interval = wordInterval, leaves = leavesLastTentative
        let started = Date()
        task = Task { [weak self] in
            for (index, line) in lines.enumerated() {
                let wait = line.at - Date().timeIntervalSince(started)
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                let words = line.text.split(separator: " ").map(String.init)
                for count in 1...words.count {
                    guard !Task.isCancelled else { return }
                    self?.apply(text: words.prefix(count).joined(separator: " "), start: line.at,
                                end: line.at + Double(count) * interval, isFinal: false)
                    try? await Task.sleep(for: .seconds(interval))
                }
                if !(leaves && index == lines.count - 1) {
                    self?.apply(text: line.text, start: line.at, end: line.at + Double(words.count) * interval, isFinal: true)
                }
            }
        }
    }

    /// Posts one result directly (tests).
    public func apply(text: String, start: TimeInterval, end: TimeInterval, isFinal: Bool) {
        let snapshot = lock.withLock { () -> [LiveCaptionSegment]? in
            return assembler.apply(text: text, start: start, end: end, isFinal: isFinal) ? assembler.segments : nil
        }
        if let snapshot { updatesContinuation.yield(snapshot) }
    }

    public func finish() async {
        task?.cancel()
        await task?.value
        let snapshot = lock.withLock { () -> [LiveCaptionSegment] in assembler.finalizeAll(); return assembler.segments }
        updatesContinuation.yield(snapshot)
        statesContinuation.yield(.finished)
        updatesContinuation.finish()
        statesContinuation.finish()
    }
}
