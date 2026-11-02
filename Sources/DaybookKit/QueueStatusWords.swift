import DaybookCore
import Foundation

/// This device's processing queue in one line, the same on both apps: Floating Notes' home and chip on a Mac, the
/// iPhone's status sheet when it processes its own recordings. "This Mac  Transcribing · 40% · 1 waiting",
/// "This iPhone  Paused · Continues when iPhone is charging". Nil while there's no work.
public enum QueueStatusWords {
    public struct Queue: Equatable, Sendable {
        /// The step the running conversation is in; nil when nothing runs.
        public var running: ProcessingRequest.Stage?
        public var fraction: Double?
        /// The running conversation's summary counts down to this device until then.
        public var countdown: Date?
        /// The running conversation's summary is in the cloud, with this model.
        public var cloudModel: String?
        /// Conversations waiting their turn.
        public var waiting: Int
        /// Conversations waiting for models to download.
        public var awaitingModels: Int
        /// Why the queue waits instead of running.
        public var pause: ProcessingWords.PauseReason?
        /// The models it waits for, downloading.
        public var download: ConversationStatusPresentation.LocalCapabilities.Download?

        public init(running: ProcessingRequest.Stage? = nil, fraction: Double? = nil, countdown: Date? = nil, cloudModel: String? = nil,
                    waiting: Int = 0, awaitingModels: Int = 0, pause: ProcessingWords.PauseReason? = nil,
                    download: ConversationStatusPresentation.LocalCapabilities.Download? = nil) {
            self.running = running; self.fraction = fraction; self.countdown = countdown; self.cloudModel = cloudModel
            self.waiting = waiting; self.awaitingModels = awaitingModels; self.pause = pause; self.download = download
        }

        public var isEmpty: Bool {
            running == nil && countdown == nil && cloudModel == nil && waiting == 0 && awaitingModels == 0 && pause == nil && download == nil
        }
    }

    public static func line(_ queue: Queue, words: DeviceWords, now: Date = Date()) -> StatusLineWords? {
        guard !queue.isEmpty else { return nil }
        func line(_ text: String, _ tone: StatusLineWords.Tone, progress: Double? = nil, short: String? = nil,
                  countdown: Date? = nil) -> StatusLineWords {
            StatusLineWords(id: "queue", symbol: words.symbol, title: words.hereTitle, text: text, tone: tone, progress: progress,
                            shortText: short, countdownUntil: countdown)
        }
        let waiting = queue.waiting > 0 ? " · \(queue.waiting) waiting" : ""
        if let until = queue.countdown {
            let seconds = max(1, Int(until.timeIntervalSince(now).rounded(.up)))
            return line("Summarizing in \(seconds) s\(waiting)", .calm, short: "Summarizing in \(seconds) s", countdown: until)
        }
        if let model = queue.cloudModel { return line("Summarizing with \(model)\(waiting)", .working, short: "Summarizing…") }
        if let stage = queue.running {
            let progress = ProcessingWords.progressLine(stage, fraction: queue.fraction)
            return line(progress + waiting, .working, progress: queue.fraction, short: waiting.isEmpty ? nil : progress)
        }
        if let pause = queue.pause {
            let why = ProcessingWords.pausedLine(pause, device: words.hereDeviceName)
            // Narrow, the reason stays: "Continues when iPhone is charging" says it waits, and for what.
            return line(["Paused", why].compactMap { $0 }.joined(separator: " · "), .calm, short: why)
        }
        if let download = queue.download {
            let text = "Downloading \(download.name) · \(ProcessingWords.percentText(download.fraction))"
            return line(text + waiting, .working, progress: download.fraction, short: waiting.isEmpty ? nil : text)
        }
        if queue.waiting > 0 {
            return line("\(queue.waiting) waiting to transcribe", .calm, short: "\(queue.waiting) waiting")
        }
        return line("Waiting for models", .attention)
    }
}
