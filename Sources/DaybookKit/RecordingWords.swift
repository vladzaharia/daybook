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
        // The iPhone's and Apple Watch's microphone tracks are named for the device already, never this Mac's.
        guard track.deviceKind != DaybookPhoneIntegration.id, track.deviceKind != AppleWatchIntegration.id else { return nil }
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

    /// A recording in a sentence, as Version History says what happened to it: "the Soundcore Work recording",
    /// "“Interview.m4a”".
    public static func inSentence(_ track: RecordingTrack, in meeting: Meeting, phoneName: String? = nil) -> String {
        if track.source == .imported, track.deviceKind == nil { return "“\(track.fileName)”" }
        return "the \(baseName(track, phoneName: phoneName)) recording"
    }

    /// The title of the conversation a recording moves into: a file's name, or what made it and when ("Soundcore
    /// Work at 3:50 PM").
    public static func conversationTitle(_ track: RecordingTrack, phoneName: String? = nil) -> String {
        if track.source == .imported, track.deviceKind == nil { return (track.fileName as NSString).deletingPathExtension }
        let start = track.startedAt ?? track.createdAt
        return "\(baseName(track, phoneName: phoneName)) at \(start.formatted(date: .omitted, time: .shortened))"
    }

    /// What made a recording, without what was done to it: "Microphone", "Soundcore Work", "Alex’s iPhone".
    static func baseName(_ track: RecordingTrack, phoneName: String?) -> String {
        if track.deviceKind == DaybookPhoneIntegration.id { return phoneName ?? "iPhone" }
        if let kind = track.deviceKind, let device = DeviceCatalog.kind(kind)?.name { return device }
        return track.source.recordingName
    }

    /// Audio a recording lost while the device couldn't keep up, as its capture details and the conversation say it:
    /// "2.4 s of call audio were lost while the disk was busy." `name` is what the sound was ("call audio",
    /// "microphone audio"); `because` says why, after "while".
    public nonisolated static func lostAudio(_ seconds: TimeInterval, of name: String, while because: String = "the disk was busy") -> String {
        let amount = Self.seconds(seconds)
        return "\(amount) of \(name) \(amount == "1 s" || amount == "1 min" ? "was" : "were") lost while \(because)."
    }

    /// What a recording rebuilt at launch says, in its conversation on both apps, when Daybook ended while it recorded:
    /// what was written is kept, and the last seconds may not have reached the disk.
    public nonisolated static let recoveredAfterQuit = "Daybook quit while recording. The recording was recovered; the last seconds may be missing."
    /// And when Stop had ended it and Daybook was ended while saving it: nothing is missing.
    public nonisolated static let savedAfterInterruptedSave = "Saved after Daybook was interrupted while saving."

    /// Under "Saved", for a recording stopped while the iPhone was locked: it's whole, and it's joined and filed once
    /// the iPhone is unlocked (the Live Activity, the recorder after Stop).
    public nonisolated static let finishesWhenUnlocked = "Finishes when you unlock iPhone"
    /// What Siri and Shortcuts say of that Stop.
    public nonisolated static let savedUntilUnlock = "Saved to Daybook. It finishes when you unlock iPhone."

    /// A short stretch of audio in seconds as a sentence says it: "0.4 s", "2.4 s", "42 s", "3 min".
    public nonisolated static func seconds(_ value: TimeInterval) -> String {
        let value = max(0, value)
        if value < 10 {
            let tenths = (value * 10).rounded() / 10
            return tenths == tenths.rounded() ? "\(Int(tenths)) s" : String(format: "%.1f s", tenths)
        }
        if value < 90 { return "\(Int(value.rounded())) s" }
        return "\(Int((value / 60).rounded())) min"
    }

    /// The glyph beside a recording, the same on both apps: the device it came from when one did ("iphone" for an
    /// iPhone's microphone, the recorder's own glyph), otherwise what it is ("mic", "desktopcomputer" for computer
    /// audio, "doc" for a file).
    public static func symbol(_ track: RecordingTrack) -> String {
        if let kind = track.deviceKind, let device = DeviceCatalog.kind(kind) { return device.systemImage }
        switch track.source {
        case .microphone: return "mic"
        case .systemAudio: return "desktopcomputer"
        case .soundcore: return "recordingtape"
        case .imported: return "doc"
        }
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
