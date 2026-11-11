#if DEBUG
import DaybookKit
import Foundation

/// `--status-demo phone-working|phone-paused` (debug): this iPhone's own work in the status sheet, for screenshots,
/// without models or a recording. The simulator can't process, so the sheet is told what the processor would say:
/// the newest conversation transcribing at 40% with the next one waiting, or both paused until the iPhone is charging.
enum StatusSheetDemo {
    static var scenario: String? { LaunchOptions.value(after: "--status-demo", in: CommandLine.arguments) }

    static func adjust(_ work: inout StatusOverviewModel.LocalWork, meetings: [Meeting]) {
        guard let scenario, scenario.hasPrefix("phone-") else { return }
        let newest = meetings.sorted { $0.date > $1.date }.prefix(2)
        guard let first = newest.first else { return }
        let second = newest.dropFirst().first
        func entry(_ meeting: Meeting, _ line: String, running: Bool = false, progress: Double? = nil) -> StatusQueueEntry {
            StatusQueueEntry(id: meeting.id, title: meeting.title, line: line, requestedHere: false, progress: progress, isRunning: running)
        }
        switch scenario {
        case "phone-paused":
            let line = ["Paused", ProcessingWords.pausedLine(.lowBattery)].compactMap { $0 }.joined(separator: " · ")
            work.entries = [first, second].compactMap { $0 }.map { entry($0, line) }
            work.line = QueueStatusWords.Queue(waiting: work.entries.count, pause: .lowBattery)
        default:
            work.entries = [entry(first, ProcessingWords.progressLine(.transcribing, fraction: 0.4), running: true, progress: 0.4)]
                + [second].compactMap { $0 }.map { entry($0, ProcessingWords.waitingHereShort(.newAudio)) }
            work.line = QueueStatusWords.Queue(running: .transcribing, fraction: 0.4, waiting: second == nil ? 0 : 1)
        }
    }
}
#endif
