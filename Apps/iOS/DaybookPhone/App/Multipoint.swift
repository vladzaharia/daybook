import DaybookLink
import Foundation

/// A recording made on this iPhone and a Mac at once (docs/multipoint.md), as the phone sees it.
/// Both record into one conversation ID; the recordings meet in the library through sync, and the
/// Mac places them on one timeline with the clock samples the phone stores on its track.
struct MultipointSession: Equatable, Sendable {
    enum Role: Equatable, Sendable {
        /// The Mac asked this iPhone to record (its conversation; the phone's recording joins it).
        case macLed(macID: UUID)
        /// This iPhone started; it asked one or more Macs to record too.
        case phoneLed
    }

    struct Mac: Equatable, Sendable, Identifiable {
        enum State: Equatable, Sendable {
            case asking
            case recording
            case stopped
            case failed(String)
        }
        var id: UUID
        var name: String
        var state: State
        /// When its recording started, on the Mac's clock.
        var startedAt: Date?
        /// This iPhone started it, so this iPhone stops it.
        var startedByPhone: Bool

        /// It recorded this conversation too, or may have, so this iPhone's recording joins it.
        var mayHaveRecorded: Bool {
            switch state {
            case .asking, .recording, .stopped: return true
            case .failed: return false
            }
        }
    }

    var conversationID: UUID
    var role: Role
    var macs: [Mac] = []
    /// The Mac's own recording started here, on its clock (from a request's timing).
    var leadStartedAt: Date?
    /// Mac clock − iPhone clock, when the request carried one.
    var leadClockOffset: TimeInterval?
    /// The conversation as the Mac leading it has it, for creating it here if it hasn't synced yet.
    var title: String?
    var date: Date?

    var isMacLed: Bool { if case .macLed = role { return true } else { return false } }

    var recordingMacs: [Mac] { macs.filter { $0.state == .recording } }

    /// One line for the recording screen and the Live Activity: "Also recording on Studio Mac",
    /// "Recording with Studio Mac", "Asking Studio Mac…". Nil when no Mac is involved.
    var line: String? {
        let names = recordingMacs.map(\.name)
        if case .macLed = role, let lead = macs.first {
            return lead.state == .stopped ? "\(lead.name) stopped recording" : "Recording with \(lead.name)"
        }
        if !names.isEmpty { return "Also recording on \(ListFormatter.localizedString(byJoining: names))" }
        if let asking = macs.first(where: { $0.state == .asking }) { return "Asking \(asking.name) to record…" }
        return nil
    }

    /// Short form for the Dynamic Island and Lock Screen.
    var shortLine: String? {
        guard let first = recordingMacs.first ?? (isMacLed ? macs.first : nil) else { return nil }
        return isMacLed ? "With \(first.name)" : "Also on \(first.name)"
    }

    mutating func update(_ id: UUID, _ change: (inout Mac) -> Void) {
        guard let index = macs.firstIndex(where: { $0.id == id }) else { return }
        change(&macs[index])
    }
}
