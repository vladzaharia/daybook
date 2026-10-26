import DaybookCore
import Foundation

/// Which of a device's recordings the library already holds, read from each track's device
/// identity. Derived from the library rather than preferences, so it survives sync and works on
/// another Mac.
public struct DeviceLibraryLinks: Equatable {
    /// Recordings imported in full, and the conversation that holds each.
    public var imported: [String: UUID] = [:]
    /// Recordings saved only partly, through Listen Live. A later full import joins that conversation.
    public var partial: [String: UUID] = [:]
    /// Imports from this device, newest first, for "Recently imported".
    public var recent: [Entry] = []

    public struct Entry: Equatable, Identifiable {
        public let recordingID: String
        public let meetingID: UUID
        public let trackID: UUID
        public let importedAt: Date
        public let fileName: String
        public var id: UUID { trackID }

        public init(recordingID: String, meetingID: UUID, trackID: UUID, importedAt: Date, fileName: String) {
            self.recordingID = recordingID
            self.meetingID = meetingID
            self.trackID = trackID
            self.importedAt = importedAt
            self.fileName = fileName
        }
    }

    /// A partial capture's recording ID ends with this, so it never counts as the whole recording.
    public static let partialSuffix = "~live"

    public static func partialID(_ recordingID: String) -> String { recordingID + partialSuffix }

    /// The recording a Listen Live portion belongs to; any other ID unchanged.
    public static func wholeRecordingID(_ recordingID: String) -> String {
        recordingID.hasSuffix(partialSuffix) ? String(recordingID.dropLast(partialSuffix.count)) : recordingID
    }

    public init(imported: [String: UUID] = [:], partial: [String: UUID] = [:]) {
        self.imported = imported; self.partial = partial
    }

    /// Links for one device kind. With a serial number, tracks from a different recorder of the same
    /// kind don't count; tracks without one (exports) always do.
    public init(meetings: [Meeting], kind: String, serial: String? = nil, recentLimit: Int = 10) {
        var entries: [Entry] = []
        for meeting in meetings {
            for track in meeting.tracks {
                guard let device = track.device, device.kind == kind else { continue }
                if let serial, let other = device.serial, !serial.isEmpty, other != serial { continue }
                if device.recordingID.hasSuffix(Self.partialSuffix) {
                    let id = String(device.recordingID.dropLast(Self.partialSuffix.count))
                    partial[id] = partial[id] ?? meeting.id
                } else {
                    imported[device.recordingID] = meeting.id
                    // Existing libraries used name/size file IDs. Their verified import digest
                    // also recognizes the new content ID on another device without reimporting.
                    if device.recordingID.hasPrefix("file:"), !track.sha256.isEmpty {
                        imported[ImportFolderWatcher.recordingID(sha256: track.sha256)] = meeting.id
                    }
                }
                entries.append(Entry(recordingID: device.recordingID, meetingID: meeting.id, trackID: track.id,
                                     importedAt: track.createdAt, fileName: track.fileName))
            }
        }
        for id in imported.keys { partial[id] = nil }
        recent = Array(entries.sorted { $0.importedAt > $1.importedAt }.prefix(recentLimit))
    }
}

/// When a recorder's recording started, read from its identity: Soundcore recording IDs are Unix start
/// times on the recorder's clock. The one place every surface dates or titles an import from.
@MainActor
public enum DeviceRecordingStart {
    public static func date(of identity: DeviceRecordingIdentity) -> Date? {
        guard identity.kind == SoundcoreWorkIntegration.id,
              let seconds = UInt32(DeviceLibraryLinks.wholeRecordingID(identity.recordingID)) else { return nil }
        return SoundcoreRecording(id: seconds, size: 0).date
    }
}

/// The list column's groups: New on the recorder and Already in Daybook, newest first.
public struct DeviceRecordingSplit: Equatable {
    public struct Imported: Equatable, Identifiable {
        public let recording: DeviceRecording
        public let meetingID: UUID
        public var id: String { recording.id }

        public init(recording: DeviceRecording, meetingID: UUID) {
            self.recording = recording
            self.meetingID = meetingID
        }
    }

    public var inProgress: DeviceRecording?
    public var new: [DeviceRecording] = []
    public var imported: [Imported] = []

    public init(recordings: [DeviceRecording], links: DeviceLibraryLinks) {
        var seen = Set<String>()
        for recording in recordings.sorted(by: Self.newestFirst) where seen.insert(recording.id).inserted {
            if recording.isInProgress { inProgress = recording; continue }
            if let meetingID = links.imported[recording.id] { imported.append(.init(recording: recording, meetingID: meetingID)) }
            else { new.append(recording) }
        }
    }

    public static func newestFirst(_ a: DeviceRecording, _ b: DeviceRecording) -> Bool {
        switch (a.sortDate, b.sortDate) {
        case let (x?, y?): return x != y ? x > y : a.id > b.id
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return (a.fileName ?? a.id).localizedStandardCompare(b.fileName ?? b.id) == .orderedAscending
        }
    }
}

/// A conversation recorded on this Mac whose time span intersects a device recording.
public struct DeviceOverlap: Equatable, Identifiable {
    public let meetingID: UUID
    public let title: String
    public let start: Date
    public let end: Date
    public var id: UUID { meetingID }

    /// Conversations recorded on this Mac that overlap `start ..< start + duration`, most overlap first.
    /// It's only a hint: overlapping in time isn't proof of the same conversation.
    public static func find(start: Date, duration: TimeInterval, in meetings: [Meeting]) -> [DeviceOverlap] {
        guard duration > 0 else { return [] }
        let end = start.addingTimeInterval(duration)
        var result: [(overlap: DeviceOverlap, amount: TimeInterval)] = []
        for meeting in meetings {
            guard meeting.tracks.contains(where: { $0.source == .microphone || $0.source == .systemAudio }),
                  let length = meeting.duration, length > 0 else { continue }
            let meetingEnd = meeting.date.addingTimeInterval(length)
            let amount = min(end, meetingEnd).timeIntervalSince(max(start, meeting.date))
            guard amount > 0 else { continue }
            result.append((DeviceOverlap(meetingID: meeting.id, title: meeting.title, start: meeting.date, end: meetingEnd), amount))
        }
        return result.sorted { $0.amount > $1.amount }.map(\.overlap)
    }

    /// "from 3:28 PM to 4:41 PM", or "at 3:30 PM" for a conversation shorter than a minute.
    public var span: String {
        let start = start.formatted(date: .omitted, time: .shortened)
        let end = end.formatted(date: .omitted, time: .shortened)
        return start == end ? "at \(start)" : "from \(start) to \(end)"
    }

    public init(meetingID: UUID, title: String, start: Date, end: Date) {
        self.meetingID = meetingID
        self.title = title
        self.start = start
        self.end = end
    }
}

/// A recording that didn't import, kept in memory so it can be tried again.
public struct DeviceImportFailure: Equatable, Identifiable {
    public let recording: DeviceRecording
    public let method: ConnectionMethodKind
    public let message: String
    public let date: Date
    public var id: String { recording.id }

    public init(recording: DeviceRecording, method: ConnectionMethodKind, message: String, date: Date) {
        self.recording = recording
        self.method = method
        self.message = message
        self.date = date
    }
}
