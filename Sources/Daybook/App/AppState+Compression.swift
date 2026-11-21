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

    /// When this Mac may first compress (a week after it first could: `RecordingCompressionSchedule`).
    var compressionStartDate: Date {
        RecordingCompressionSchedule.startDate(in: preferences, key: Preference.compressionStartsAt)
    }

    /// Starts a pass after an idle moment, unless one is waiting or under way.
    func compressOlderRecordingsWhenIdle() {
        _ = compressionStartDate
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

    /// One pass: lets go of originals whose copies are in place (here or from another Mac), then compresses up to
    /// `compressionsPerPass` eligible conversations.
    func compressOlderRecordings(now: Date = Date()) async {
        guard mayCompressRecordings else { return }
        let start = compressionStartDate
        let age = library.recordingCompression
        // Letting go of originals waits with the rest: Never, or before this Mac's start, keeps every original here.
        guard age != .never, now >= start else { return }
        await library.finishCompressions { [weak self] id in self?.isInUse(id) == false }
        let syncState = library.compressionSync
        guard syncState != .unknown else { return }
        let everyDevice = syncState == .local ? true : await sync.engine?.everyRecentDeviceCompresses(now: now) ?? false
        let macs: [RecordingCompressionRunner.Mac]? = syncState == .local ? nil : await sync.knownDevices().compactMap { device in
            guard device.deviceClass == .mac, !device.isCurrentDevice, let lastSeen = device.lastSeen else { return nil }
            return .init(id: device.id, lastSeen: lastSeen, isSuperseded: device.supersededBy != nil)
        }
        let context = RecordingCompressionEligibility.Context(now: now, age: age, startsAt: start, everyDeviceCompresses: everyDevice)
        let learnedFrom = Set((library.metadata.voiceprints ?? []).compactMap { $0.value?.meetingID })
        let trashed = Set(library.trashedMeetingIDs())
        let thisDevice = sync.deviceID
        var passed = 0
        let oldestFirst = library.meetings.sorted { RecordingCompressionEligibility.lastActivity(of: $0) < RecordingCompressionEligibility.lastActivity(of: $1) }
        for candidate in oldestFirst {
            guard passed < Self.compressionsPerPass, !Task.isCancelled, mayCompressRecordings else { return }
            guard let meeting = library.meeting(candidate.id) else { continue }
            func facts(_ tracks: [UUID: RecordingCompressionEligibility.TrackFacts]) -> RecordingCompressionEligibility.ConversationFacts {
                .init(isBusy: isInUse(meeting.id), isTrashed: trashed.contains(meeting.id), isDone: processingStatus(for: meeting) == .done,
                      offersUpgrade: upgradeOffer(for: meeting) != nil, teachesVoiceProfile: learnedFrom.contains(meeting.id), tracks: tracks)
            }
            // Everything but the files first, so a conversation that can't go anyway isn't read.
            let assumed = Dictionary(uniqueKeysWithValues: meeting.tracks.map { ($0.id, RecordingCompressionEligibility.TrackFacts(isVerified: true, isUploaded: true, storage: .lossless)) })
            guard case .compress = RecordingCompressionEligibility.decide(meeting, facts: facts(assumed), context: context) else { continue }
            let found = await library.compressionFacts(for: meeting)
            guard mayCompressRecordings, let current = library.meeting(meeting.id),
                  case .compress(let ids) = RecordingCompressionEligibility.decide(current, facts: facts(found), context: context) else { continue }
            let mine = ids.filter { id in
                current.tracks.first { $0.id == id }.map { RecordingCompressionRunner.runner(for: $0, thisDevice: thisDevice, macs: macs, now: now) == thisDevice } ?? false
            }
            guard !mine.isEmpty else { continue }
            passed += 1
            // Stops the moment anything else starts: the copy being made is thrown away, the recording stays.
            let work = Task { [library] in await library.compressRecordings(mine, in: current.id, device: syncState == .local ? nil : thisDevice, now: now) }
            let watch = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    if self?.mayCompressRecordings != true || self?.isInUse(current.id) != false { work.cancel(); return }
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
