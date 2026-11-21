import DaybookCore
import DaybookKit
import Foundation
import IOKit.ps

/// Compress Older Recordings on this Mac (docs/architecture.md, "Compressing older recordings"): at idle moments, on
/// power or a well-charged battery, a few conversations a pass, oldest first, stopping the moment recording, processing,
/// or playback starts. The first pass over an existing library finds most of it eligible, so each pass is small and the
/// next idle moment carries on. The iPhone never compresses.
extension AppState {
    /// Conversations compressed in one pass at most.
    static let compressionsPerPass = 3

    /// Nothing else is going on, and the Mac's power allows it.
    var mayCompressRecordings: Bool {
        mayListenToEarlierRecordings && !playback.isPlaying && library.mergingIDs.isEmpty && library.lockWaiterCount == 0
            && MacPower.allowsBackgroundWork()
    }

    /// The library this Mac's first-run week is kept for: its sync ID, or `local` for one that doesn't sync.
    func compressionLibrary() async -> String {
        library.compressionSync == .local ? "local" : (await sync.libraryID())?.uuidString ?? "unknown"
    }

    /// When this Mac may first compress in this library (a week after it first could: `RecordingCompressionSchedule`).
    func compressionStartDate(library id: String) -> Date {
        RecordingCompressionSchedule.startDate(in: preferences, key: Preference.compressionStartsAt, library: id)
    }

    /// Starts a pass after an idle moment, unless one is waiting or under way.
    func compressOlderRecordingsWhenIdle() {
        // The week starts with the first idle moment in a library, whatever the power.
        if library.isLoaded, library.compressionSync != .unknown {
            Task { [weak self] in
                guard let self else { return }
                self.compressionStartsAt = self.compressionStartDate(library: await self.compressionLibrary())
            }
        }
        guard compressionPass == nil, library.isLoaded, mayCompressRecordings else { return }
        compressionPass = Task(priority: .background) { [weak self, delay = compressionDelay] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.compressOlderRecordings()
            self?.compressionPass = nil
        }
    }

    /// A conversation in use here: recorded into, processed, played, merged.
    func isInUse(_ id: UUID) -> Bool {
        recordingID == id || processor.queue.runningID == id || processor.queue.jobs.contains { $0.meetingID == id }
            || playback.meetingID == id || library.mergingIDs.contains(id)
    }

    /// What the pass knows now (`RecordingCompressionPlanner.Inputs`).
    func compressionInputs(now: Date) async -> RecordingCompressionPlanner.Inputs? {
        let syncState = library.compressionSync
        guard syncState != .unknown else { return nil }
        let libraryID = await compressionLibrary()
        let start = compressionStartDate(library: libraryID)
        compressionStartsAt = start
        let connectedLibrary = await sync.libraryID()
        let macs: [RecordingCompressionRunner.Mac]? = syncState == .local ? nil : await sync.knownDevices().compactMap { device in
            guard device.deviceClass == .mac, !device.isCurrentDevice, let lastSeen = device.lastSeen else { return nil }
            return .init(id: device.id, lastSeen: lastSeen, isSuperseded: device.supersededBy != nil)
        }
        let engine = sync.engine
        return .init(now: now, age: library.recordingCompression, startsAt: start,
                     settingsApplied: syncState == .local || (connectedLibrary != nil && library.settingsAppliedFromSync == connectedLibrary),
                     everyDeviceCompresses: syncState == .local ? true : await engine?.everyRecentDeviceCompresses(now: now) ?? false,
                     clockLooksAhead: syncState == .local ? false : await engine?.compressionClockLooksAhead(now: now) ?? true,
                     thisDevice: sync.deviceID, macs: macs,
                     inUse: Set(library.meetings.map(\.id).filter(isInUse)), trashed: Set(library.trashedMeetingIDs()),
                     done: Set(library.meetings.filter { processingStatus(for: $0) == .done }.map(\.id)),
                     upgradeOffered: Set(library.meetings.filter { upgradeOffer(for: $0) != nil }.map(\.id)),
                     voiceprints: (library.metadata.voiceprints ?? []).compactMap(\.value))
    }

    /// One pass: lets go of originals whose copies are in place (here or from another Mac), then compresses up to
    /// `compressionsPerPass` eligible conversations. The library's choice is read again before each conversation, and
    /// once more under the lock before each recording is replaced.
    func compressOlderRecordings(now: Date = Date()) async {
        guard mayCompressRecordings, let first = await compressionInputs(now: now) else { return }
        // Letting go of originals waits with the rest: Never, or before this Mac's start, keeps every original here.
        guard first.age != .never, first.settingsApplied, let start = first.startsAt, now >= start else { return }
        await library.finishCompressions { [weak self] id in self?.isInUse(id) == false }
        var passed = 0
        for candidate in RecordingCompressionPlanner.candidates(library.meetings, first) {
            guard passed < Self.compressionsPerPass, !Task.isCancelled, mayCompressRecordings,
                  library.recordingCompression != .never, let meeting = library.meeting(candidate.meetingID) else { return }
            let files = await library.compressionFacts(for: meeting)
            guard mayCompressRecordings, let inputs = await compressionInputs(now: now), inputs.age != .never,
                  let current = library.meeting(meeting.id) else { return }
            let mine = RecordingCompressionPlanner.tracks(current, among: library.meetings, inputs, files: files)
            guard !mine.isEmpty else { continue }
            passed += 1
            let device = library.compressionSync == .local ? nil : inputs.thisDevice
            // Stops the moment anything else starts: the copy being made is thrown away, the recording stays.
            let work = Task { [library, weak self] in
                await library.compressRecordings(mine, in: current.id, device: device, now: now) { meeting in
                    guard let self else { return false }
                    var now = inputs
                    now.age = library.recordingCompression
                    now.inUse = Set(library.meetings.map(\.id).filter(self.isInUse))
                    return RecordingCompressionPlanner.stillAllowed(meeting, among: library.meetings, now)
                }
            }
            let watch = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    if self?.mayCompressRecordings != true || self?.isInUse(current.id) != false
                        || self?.library.recordingCompression == .never { work.cancel(); return }
                }
            }
            _ = await work.value
            watch.cancel()
        }
    }
}

/// Whether the Mac's power allows background work that can wait: on power, or on a battery at least half charged,
/// outside Low Power Mode and while it isn't running hot.
enum MacPower {
    static let batteryThreshold = 0.5

    static func allowsBackgroundWork() -> Bool {
        let process = ProcessInfo.processInfo
        if process.isLowPowerModeEnabled { return false }
        if process.thermalState == .serious || process.thermalState == .critical { return false }
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return true }
        if let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?, providing == kIOPMACPowerKey { return true }
        guard let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return true }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Double, let maximum = description[kIOPSMaxCapacityKey] as? Double,
                  maximum > 0 else { continue }
            return current / maximum >= batteryThreshold
        }
        return true
    }
}
