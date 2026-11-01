import DaybookCore
import Foundation

/// What a device that processes its own recordings (the iPhone) does with the requests in its library
/// (docs/iphone.md, "Processing on this iPhone"). It works under the same `ProcessingRequest` claims a
/// Mac does, so the two never both transcribe a recording:
///
/// - **Its own recordings.** It carries out only requests it made, and transcribes only recordings made
///   or brought in on it (`Device.owns`). A Mac's recording is the Mac's.
/// - **Claimed when filed.** A request it can carry out is claimed in the same save that files the
///   recording, so a Mac that receives the recording sees the claim and leaves it. A Mac never
///   transcribes again what this device transcribed: its jobs only transcribe recordings without a
///   transcript.
/// - **Fusion where the last recording arrives.** Once its recordings are transcribed it fuses here
///   when every recording of the conversation is transcribed and on the timeline (`fusesHere`).
///   Otherwise (a recording made with a Mac, which the Mac lines up by sound) it gives the request back
///   for the Mac that has the others, which places, fuses, and summarizes.
/// - **Summaries** go through the summary placement once the conversation is fused here
///   (`placeSummary`): a countdown, then this device, a Mac, or the cloud (docs/multipoint.md, "Where
///   summaries run"). A summary placed on this device runs as its own work (`summarize`), on the
///   Summarize request the placement claimed for it. Transcribe Everything Again and Identify Speakers
///   Again done here are finished here, so a Mac never does that work again.
///
/// Pure: the app and tests ask it.
public enum OnDeviceProcessing {
    /// What a request asks of this device.
    public enum Work: Equatable, Sendable {
        /// Transcribe these recordings, with speakers and voice profiles, then fuse and place the summary.
        case transcribe([UUID])
        /// Find the speakers again in these recordings' saved transcripts, then fuse and place the summary.
        case identifySpeakers([UUID])
        /// Every recording is transcribed and on the timeline (a job that stopped once it had transcribed):
        /// fuse, label the speakers, and place the summary.
        case placeSummary
        /// The summary the placement chose to run on this device.
        case summarize
    }

    /// The device deciding: who it is, what its models can do now, which recordings are its own, and the
    /// Summarize requests its summary placement handed it to run here.
    public struct Device: Sendable {
        public var identity: ProcessingRequest.Device
        public var capabilities: ProcessingCapabilities
        public var owns: @Sendable (RecordingTrack) -> Bool
        /// Summarize requests to run here (`SummaryPlace.thisDevice`). Any other Summarize request waits for a
        /// Mac, or for the cloud the placement runs.
        public var summariesHere: Set<UUID>

        public init(identity: ProcessingRequest.Device, capabilities: ProcessingCapabilities,
                    owns: @escaping @Sendable (RecordingTrack) -> Bool, summariesHere: Set<UUID> = []) {
            self.identity = identity; self.capabilities = capabilities; self.owns = owns; self.summariesHere = summariesHere
        }
    }

    /// The work `request` asks of this device now, or nil when it's another device's (a Mac's
    /// recording, a request another device made or holds) or this device can't do it.
    public static func work(for request: ProcessingRequest, in meeting: Meeting, device: Device, at now: Date = Date()) -> Work? {
        guard request.isClaimable(by: device.identity, at: now), !request.isSatisfied(by: meeting) else { return nil }
        let can = device.capabilities
        // A summary placed here, on whichever Summarize request the placement claimed for it.
        if device.summariesHere.contains(request.id) { return request.mode == .summaryOnly && can.summarizes ? .summarize : nil }
        guard request.requestedBy.id == device.identity.id else { return nil }
        // An upgrade it asked of a Mac, whose model is the better one, is the Mac's (docs/multipoint.md, "Upgrade").
        if let upgrade = request.upgrade, upgrade.device?.id != device.identity.id { return nil }
        let tracks = meeting.transcribableTracks
        switch request.mode {
        case .newAudio:
            let untranscribed = tracks.filter { track in !meeting.transcripts.contains { $0.trackID == track.id } }
            if !untranscribed.isEmpty {
                guard transcribes(can), untranscribed.allSatisfy(device.owns) else { return nil }
                return .transcribe(untranscribed.map(\.id))
            }
            return transcribes(can) && fusesHere(meeting) ? .placeSummary : nil
        case .fullRetranscription, .speakerRefresh:
            guard !tracks.isEmpty, tracks.allSatisfy(device.owns) else { return nil }
            // Each recording once: a run made since the request was asked is that recording done.
            let pending = tracks.filter { track in !meeting.transcripts.contains { $0.trackID == track.id && $0.createdAt >= request.createdAt } }
            if pending.isEmpty { return can.findsSpeakers && fusesHere(meeting) ? .placeSummary : nil }
            if request.mode == .fullRetranscription {
                return transcribes(can) ? .transcribe(pending.map(\.id)) : nil
            }
            let transcribed = pending.filter { track in meeting.transcripts.contains { $0.trackID == track.id } }
            return can.findsSpeakers && !transcribed.isEmpty ? .identifySpeakers(transcribed.map(\.id)) : nil
        case .summaryOnly:
            // Only the summaries placed here (above): one waiting for a Mac, or in the cloud, isn't this device's to run.
            return nil
        }
    }

    /// It transcribes as a Mac does, with speakers and voice profiles; without the speaker models a
    /// recording waits for a Mac rather than getting a transcript without speakers.
    private static func transcribes(_ can: ProcessingCapabilities) -> Bool { can.transcribes && can.findsSpeakers }

    /// Whether this device fuses the conversation: every recording that needs a transcript has one and
    /// sits on the timeline. A recording still to be lined up (made with a Mac, or alongside another
    /// recording) leaves fusion to a Mac, which lines recordings up by their sound.
    public static func fusesHere(_ meeting: Meeting) -> Bool {
        let tracks = meeting.transcribableTracks
        return !tracks.isEmpty && tracks.allSatisfy { track in
            meeting.transcripts.contains { $0.trackID == track.id } && meeting.timelinePlacement(of: track.id) != nil
        }
    }

    /// The open request this device would carry out first in `meeting`, oldest first.
    public static func next(in meeting: Meeting, device: Device, at now: Date = Date()) -> (request: ProcessingRequest, work: Work)? {
        for request in meeting.openProcessingRequests.sorted(by: { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }) {
            if let work = work(for: request, in: meeting, device: device, at: now) { return (request, work) }
        }
        return nil
    }
}
