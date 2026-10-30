import DaybookCore
import DaybookDevices
import Foundation

/// How both apps describe a conversation's recordings in Audio (the Mac's inspector, the iPhone's
/// Info): a name that says what the recording is, where it was made when the name doesn't say, and,
/// only when the conversation has several, how it lines up with the others. A 0:00 start,
/// confidence, and clock drift aren't said (docs/interface.md, "Words").
@MainActor
public enum RecordingWords {
    /// "Microphone", "Computer audio, echo removed", the recorder or iPhone it came from ("Soundcore
    /// Work", "Alex’s iPhone"), or the file's name. `phoneName` names the paired iPhone a recording came
    /// from, when this device knows it.
    public static func name(_ track: RecordingTrack, in meeting: Meeting, phoneName: String? = nil) -> String {
        if track.source == .imported { return track.fileName }
        var name = track.source.recordingName
        if track.deviceKind == DaybookPhoneIntegration.id { name = phoneName ?? "iPhone" }
        else if let kind = track.deviceKind, let device = DeviceCatalog.kind(kind)?.name { name = device }
        if track.isLivePortion { return "\(name), live" }
        if track.derivedFrom != nil { return "\(name), \(RecordingTrack.processingName(track.processing))" }
        if meeting.tracks.contains(where: { $0.derivedFrom == track.id }) { return "\(name), original" }
        return name
    }

    /// Where a recording was made, when its name doesn't say: `mac` ("This Mac" on the Mac, "Your Mac"
    /// on the iPhone) for a Mac's microphone and computer audio, the recorder a file was exported from.
    /// Nil when the name says it already.
    public static func place(_ track: RecordingTrack, in meeting: Meeting, mac: String) -> String? {
        guard track.deviceKind != DaybookPhoneIntegration.id else { return nil }
        switch track.source {
        case .microphone, .systemAudio: return mac
        case .soundcore, .imported:
            guard let device = track.deviceKind.flatMap({ DeviceCatalog.kind($0)?.name }) else { return nil }
            return name(track, in: meeting).hasPrefix(device) ? nil : device
        }
    }

    /// How a recording sits among the conversation's others: "Lined up by sound · starts 0:12", "The
    /// main recording", "Couldn’t line up". A conversation's only recording has nothing to line up
    /// with, and starting with the conversation goes without saying, so neither is said. `pending` is
    /// what's said of one still to be lined up.
    public static func timing(_ track: RecordingTrack, in meeting: Meeting, pending: String) -> String? {
        if isUnaligned(track, in: meeting) { return "Couldn’t line up" }
        guard meeting.tracks.filter({ $0.derivedFrom == nil }).count > 1 else { return nil }
        let report = meeting.alignmentReports.first { $0.trackID == track.id }
        let placement = meeting.timelinePlacement(of: track.id)
        let starts = placement.map { TimeLabel.short($0.offset) }.flatMap { $0 == TimeLabel.short(0) ? nil : "starts \($0)" }
        func line(_ parts: String?...) -> String? {
            let words = parts.compactMap { $0 }
            return words.isEmpty ? nil : words.joined(separator: " · ")
        }
        switch track.alignment?.method {
        case .audio?: return line("Lined up by sound", starts)
        case .transcript?: return line("Lined up by shared phrases", starts)
        case .clock?: return line("Placed by the clocks only", starts)
        case .manual?: return line("Timing set by you", starts)
        case .pending?: return pending
        case .unaligned?: return "Couldn’t line up"
        case nil:
            switch report?.method {
            case .unaligned?: return "Couldn’t line up"
            case .anchors?: return line("Lined up by shared phrases", starts)
            case .audio?: return line("Lined up by sound", starts)
            case .timestamps?: return line("Placed by the clocks only", starts)
            case .reference?: return "The main recording"
            // Placed as it was recorded: where is the place, and only a later start is news.
            case .provided?: return line(starts)
            case nil: return placement == nil ? "Not lined up yet" : line(starts)
            }
        }
    }

    /// The line under a recording's name, each thing said once: where it was made, then how it sits
    /// among the conversation's other recordings ("This Mac · The main recording").
    public static func line(_ track: RecordingTrack, in meeting: Meeting, mac: String, pending: String) -> String? {
        let parts = [place(track, in: meeting, mac: mac), timing(track, in: meeting, pending: pending)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Nothing could place the recording on the conversation's timeline.
    public static func isUnaligned(_ track: RecordingTrack, in meeting: Meeting) -> Bool {
        track.alignment?.method == .unaligned || meeting.alignmentReports.contains { $0.trackID == track.id && $0.method == .unaligned }
    }
}

extension AudioSource {
    /// The plain name a recording goes by: "Microphone", "Computer audio".
    public var recordingName: String {
        switch self {
        case .microphone: return "Microphone"
        case .systemAudio: return "Computer audio"
        case .soundcore: return "Soundcore Work"
        case .imported: return "Imported file"
        }
    }
}

extension RecordingTrack {
    /// How a derived track's processing reads in the interface: "echo removed".
    public static func processingName(_ processing: String?) -> String {
        processing == echoCancelledProcessing ? "echo removed" : "processed"
    }
}
