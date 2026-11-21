import DaybookCore
import DaybookIntelligence
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

    /// The library this Mac's first-run week and clock are kept for: its sync ID, or `local` for one that doesn't sync;
    /// nil while it isn't known (sync connecting), and then nothing happens.
    func compressionLibrary() async -> String? {
        switch library.compressionSync {
        case .local: return "local"
        case .unknown: return nil
        case .connected: return await sync.libraryID()?.uuidString
        }
    }

    /// When this Mac may first compress in this library (a week after it first could: `RecordingCompressionSchedule`).
    func compressionStartDate(library id: String) -> Date {
        RecordingCompressionSchedule.startDate(in: preferences, key: Preference.compressionStartsAt, library: id)
    }

    /// Starts a pass after an idle moment, unless one is waiting or under way.
    func compressOlderRecordingsWhenIdle() {
        // The week starts with the first idle moment in a library, whatever the power.
        if library.isLoaded {
            Task { [weak self] in
                guard let self, let id = await self.compressionLibrary() else { return }
                self.compressionStartsAt = self.compressionStartDate(library: id)
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

    /// This Mac's last pass in a library, for the clock check (`RecordingCompressionClock`): its wall-clock date, and,
    /// when it was in this boot, how long ago it was by the continuous clock.
    private func lastCompressionPass(_ id: String) -> (date: Date?, elapsed: TimeInterval?) {
        let date = preferences.object(forKey: "\(Preference.compressionLastPass).\(id)") as? Date
        guard let mark = preferences.dictionary(forKey: "\(Preference.compressionLastPassClock).\(id)"),
              let boot = mark["boot"] as? String, !boot.isEmpty, boot == ContinuousClockMark.boot,
              let then = mark["seconds"] as? Double else { return (date, nil) }
        return (date, ContinuousClockMark.seconds() - then)
    }

    private func rememberCompressionPass(_ id: String, at now: Date) {
        preferences.set(now, forKey: "\(Preference.compressionLastPass).\(id)")
        preferences.set(["boot": ContinuousClockMark.boot, "seconds": ContinuousClockMark.seconds()], forKey: "\(Preference.compressionLastPassClock).\(id)")
    }

    /// What the pass knows now (`RecordingCompressionPlanner.Inputs`), for the library `id` (read once per pass); `canListen`:
    /// the pass has the transcript bar's model.
    func compressionInputs(now: Date, library id: String, clockSteady: Bool, canListen: Bool) async -> RecordingCompressionPlanner.Inputs? {
        let syncState = library.compressionSync
        guard syncState != .unknown else { return nil }
        let start = compressionStartDate(library: id)
        compressionStartsAt = start
        let devices = syncState == .local ? [] : await sync.knownDevices()
        let macs: [RecordingCompressionRunner.Mac]? = syncState == .local ? nil : devices.compactMap { device in
            guard device.deviceClass == .mac, !device.isCurrentDevice, let lastSeen = device.lastSeen else { return nil }
            return .init(id: device.id, lastSeen: lastSeen, isSuperseded: device.supersededBy != nil)
        }
        let engine = sync.engine
        // In a synced library, applied for the library this pass is for (`id`): a library switched mid-pass isn't.
        let settingsApplied = syncState == .local ? id == "local" : await library.settingsAreCurrent(library: UUID(uuidString: id) ?? UUID())
        let lineage = await library.trashedMeetings()
        // Never too while a voiceprint can't be read (`compressionPassAge`).
        return .init(now: now, age: library.compressionPassAge, startsAt: start, settingsApplied: settingsApplied,
                     everyDeviceCompresses: syncState == .local ? true : await engine?.everyRecentDeviceCompresses(now: now) ?? false,
                     clockLooksAhead: syncState == .local ? false : await engine?.compressionClockLooksAhead(now: now) ?? true,
                     thisDevice: sync.deviceID, macs: macs,
                     inUse: Set(library.meetings.map(\.id).filter(isInUse)), trashed: Set(library.trashedMeetingIDs()),
                     done: Set(library.meetings.filter { processingStatus(for: $0) == .done }.map(\.id)),
                     upgradeOffered: Set(library.meetings.filter { upgradeOffer(for: $0) != nil }.map(\.id)),
                     // A voiceprint holds its recording back until this Mac holds its clip.
                     voiceprints: library.holdingBackVoiceprints(lineage: lineage),
                     lineage: lineage, refused: library.compressionHeldBack(now: now), clockSteady: clockSteady, canListen: canListen)
    }

    /// The transcript quality bar's ears: the transcription model processing uses, when it's installed here; nil when it
    /// isn't (recordings with speech then wait for a pass that has it). Nothing is downloaded for it.
    func compressionListener() async -> RecordingCompressionListener? {
        let key = transcriptionModel
        guard !key.isEmpty, await runtime.installedModels().contains(key) else { return nil }
        let runtime = self.runtime, language = library.transcriptionLanguage
        // Parakeet transcribes the same audio the same way every time; Whisper and others don't (docs/validation.md).
        return RecordingCompressionListener(model: key, isDeterministic: key.hasPrefix("parakeet")) { url, spans in
            try await SpanTranscription.transcribe(url, spans: spans, inference: runtime, model: ModelReference(key), language: language)
        }
    }

    /// One pass: lets go of originals whose copies are in place (here or from another Mac), then compresses up to
    /// `compressionsPerPass` eligible conversations. The library's choice is read again before each conversation, and
    /// once more under the lock before each recording is replaced, with everything else the pass knows gathered again.
    func compressOlderRecordings(now: Date = Date()) async {
        guard mayCompressRecordings, let id = await compressionLibrary() else { return }
        // The clock: steady since this Mac's last pass, and not far past every other device's.
        let newestOther = library.compressionSync == .local ? nil
            : await sync.knownDevices().filter { !$0.isCurrentDevice }.compactMap(\.lastSeen).max()
        let last = lastCompressionPass(id)
        let steadyHere = RecordingCompressionClock.trusts(now: now, lastPass: last.date, elapsed: last.elapsed, newestOtherDevice: nil)
        let steady = steadyHere && RecordingCompressionClock.trusts(now: now, lastPass: nil, newestOtherDevice: newestOther)
        // A jump seen in this boot keeps the last pass as it was, so it stays seen until the Mac restarts.
        if steadyHere || last.elapsed == nil { rememberCompressionPass(id, at: now) }
        // Recordings with speech are compressed only with the model to hear them; this pass's, read once.
        let listener = await compressionListener()
        guard steady, let before = await compressionInputs(now: now, library: id, clockSteady: steady, canListen: listener != nil),
              before.settingsApplied else { return }
        // Voice clips no profile needs any more go whatever the choice, once the library's settings are here.
        await library.reconcileVoiceClips(now: now)
        // Letting go of originals waits with the rest: Never, or before this Mac's start, keeps every original here.
        guard before.age != .never, let start = before.startsAt, now >= start else { return }
        // The speech voice profiles learned from, cut from originals that may be replaced or let go soon.
        await library.makeVoiceClips(olderThan: before.age.interval.map { now.addingTimeInterval(-$0) }) { [weak self] in
            self?.mayCompressRecordings == true
        }
        guard mayCompressRecordings, let first = await compressionInputs(now: now, library: id, clockSteady: steady, canListen: listener != nil),
              first.age != .never, first.settingsApplied else { return }
        await library.finishCompressions { [weak self] id in self?.isInUse(id) == false }
        var passed = 0
        for candidate in RecordingCompressionPlanner.candidates(library.meetings, first) {
            guard passed < Self.compressionsPerPass, !Task.isCancelled, mayCompressRecordings,
                  library.compressionPassAge != .never, let meeting = library.meeting(candidate.meetingID) else { return }
            let files = await library.compressionFacts(for: meeting)
            guard mayCompressRecordings, let inputs = await compressionInputs(now: now, library: id, clockSteady: steady, canListen: listener != nil),
                  inputs.age != .never,
                  let current = library.meeting(meeting.id) else { return }
            let mine = RecordingCompressionPlanner.tracks(current, among: library.meetings, inputs, files: files)
            guard !mine.isEmpty else { continue }
            passed += 1
            let device = library.compressionSync == .local ? nil : inputs.thisDevice
            // Stops the moment anything else starts: the copy being made is thrown away, the recording stays.
            let work = Task { [library, weak self] in
                await library.compressRecordings(mine, in: current.id, device: device, now: now, listener: listener) { meeting in
                    // Everything gathered again, under the lock: the choice, voice profiles, devices, settings, the clock.
                    guard let self, let fresh = await self.compressionInputs(now: Date(), library: id, clockSteady: steady,
                                                                             canListen: listener != nil) else { return false }
                    return RecordingCompressionPlanner.stillAllowed(meeting, among: library.meetings, fresh)
                }
            }
            let watch = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    if self?.mayCompressRecordings != true || self?.isInUse(current.id) != false
                        || self?.library.compressionPassAge == .never { work.cancel(); return }
                }
            }
            _ = await work.value
            watch.cancel()
        }
    }
}

/// This Mac's continuous clock (`mach_continuous_time`: it counts through sleep, and nobody can set it) and the boot it
/// counts from (`kern.bootsessionuuid`; empty when it can't be read, and then nothing is compared across passes).
enum ContinuousClockMark {
    static func seconds() -> TimeInterval {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1e9
    }

    static let boot: String = {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return "" }
        return String(cString: bytes)
    }()
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
