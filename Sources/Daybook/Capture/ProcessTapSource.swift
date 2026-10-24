import Accelerate
import AppKit
import AudioToolbox
import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

/// A process known to the audio server.
struct AudioProcessInfo: Equatable {
    var objectID: AudioObjectID
    var pid: pid_t
    var bundleID: String
    var isRunningOutput: Bool
}

/// Reads the audio server's process list. Needs no permission and shows no prompt.
enum AudioProcessCatalog {
    static func all() -> [AudioProcessInfo] {
        let objects: [AudioObjectID] = CoreAudioProperty.array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        return objects.compactMap { object in
            guard let pid: pid_t = CoreAudioProperty.scalar(object, kAudioProcessPropertyPID) else { return nil }
            let bundle = CoreAudioProperty.string(object, kAudioProcessPropertyBundleID)
                ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
            let output: UInt32 = CoreAudioProperty.scalar(object, kAudioProcessPropertyIsRunningOutput) ?? 0
            return AudioProcessInfo(objectID: object, pid: pid, bundleID: bundle, isRunningOutput: output != 0)
        }
    }

    /// The call app's processes and helpers, never Daybook's own.
    static func processes(for target: CallAppTarget, in processes: [AudioProcessInfo], excluding ownPID: pid_t) -> [AudioProcessInfo] {
        processes.filter { $0.pid != ownPID && !$0.bundleID.isEmpty && target.owns(bundleID: $0.bundleID) }
    }
}

enum ProcessTapError: LocalizedError {
    case appNotFound(String)
    case noOutputDevice
    case status(String, OSStatus)
    case silent(String)

    var errorDescription: String? {
        switch self {
        case .appNotFound(let app): return "\(app) isn’t playing through the Mac’s audio system yet"
        case .noOutputDevice: return "no output device is available"
        case .status(let step, let status): return "couldn’t \(step) (error \(status))"
        case .silent(let app): return "the recording of \(app) stayed silent while it was playing audio; System Audio Recording permission may be off"
        }
    }
}

/// Records only the call app with a Core Audio process tap (macOS 14.2+): the tap mixes the app's
/// processes to stereo, and a private aggregate device clocked by the current output device
/// delivers it. Other apps, notifications, and Daybook itself are not recorded.
///
/// Permission: the first start shows macOS's "System Audio Recording Only" prompt, using
/// NSAudioCaptureUsageDescription. There is no public way to check that permission; when it is
/// denied the tap delivers silence, so a watchdog reports `.silent` after 45 seconds of digital
/// silence while the app's output is running. The controller then falls back to ScreenCaptureKit
/// if that needs no new prompt, and otherwise keeps the tap and warns.
///
/// While running, the source follows the app's helper processes (a browser can start a new audio
/// process mid-call) and rebuilds the aggregate when the default output device changes.
final class ProcessTapSource: CaptureAudioSource, ProcessTapReporting, @unchecked Sendable {
    let method = "process-tap"
    let target: CallAppTarget
    private(set) var capturedBundleIDs: [String] = []
    private let control = DispatchQueue(label: "app.daybook.process-tap.control", qos: .userInitiated)
    private let io = DispatchQueue(label: "app.daybook.process-tap.io", qos: .userInteractive)
    private let routes = AudioRouteMonitor()
    private let lock = NSLock()
    private var format: AVAudioFormat?
    private var onBuffer: CaptureBufferHandler?
    private var onEvent: CaptureEventHandler?
    private var signalSeen = false
    // Control-queue state.
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private let tapUUID = UUID()
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var clockDevice = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var processObjects: [AudioObjectID] = []
    private var timer: DispatchSourceTimer?
    private var silentWhilePlaying = 0
    private var ticks = 0
    private var finished = false
    /// Seconds of exact digital silence, while the app's output is running, before reporting `.silent`.
    /// Long enough for a waiting room or a quiet start; a denied permission stays silent indefinitely.
    static let silenceLimit = 45

    init(target: CallAppTarget) { self.target = target }

    func start(onBuffer: @escaping CaptureBufferHandler, onEvent: @escaping CaptureEventHandler) async throws {
        lock.withLock { self.onBuffer = onBuffer; self.onEvent = onEvent }
        try control.sync {
            let processes = AudioProcessCatalog.processes(for: target, in: AudioProcessCatalog.all(), excluding: getpid())
            guard !processes.isEmpty else { throw ProcessTapError.appNotFound(target.displayName) }
            processObjects = processes.map(\.objectID)
            capturedBundleIDs = Array(Set(processes.map(\.bundleID))).sorted()
            try createTap()
            do { try createAggregateAndStart() } catch { destroyTap(); throw error }
            startMonitoring()
        }
        routes.start { [weak self] _ in self?.control.async { self?.outputDeviceChanged() } }
    }

    func stop() async {
        routes.stop()
        control.sync {
            finished = true
            timer?.cancel(); timer = nil
            stopAggregate()
            destroyTap()
        }
        // Buffers already queued for delivery finish before the writer closes.
        await withCheckedContinuation { continuation in io.async { continuation.resume() } }
        lock.withLock { onBuffer = nil; onEvent = nil }
    }

    // MARK: Core Audio objects (control queue)

    private func createTap() throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        description.uuid = tapUUID
        description.name = "Daybook call capture"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "create the process tap")
        tapID = tap
    }

    private func destroyTap() {
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func createAggregateAndStart() throws {
        guard let output = AudioRouteMonitor.defaultOutputDevice(),
              let outputUID = CoreAudioProperty.string(output, kAudioDevicePropertyDeviceUID) else { throw ProcessTapError.noOutputDevice }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Daybook call capture",
            kAudioAggregateDeviceUIDKey: "app.daybook.call-capture.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapUUID.uuidString]]
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate), "create the capture device")
        aggregateID = aggregate
        clockDevice = output
        do {
            var stream = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var address = CoreAudioProperty.address(kAudioTapPropertyFormat)
            try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &stream), "read the tap format")
            guard let tapFormat = AVAudioFormat(streamDescription: &stream) else { throw ProcessTapError.status("read the tap format", -1) }
            lock.lock(); format = tapFormat; lock.unlock()
            var proc: AudioDeviceIOProcID?
            try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, io) { [weak self] _, input, inputTime, _, _ in
                self?.deliver(input, time: inputTime)
            }, "attach to the capture device")
            ioProc = proc
            try check(AudioDeviceStart(aggregate, proc), "start the capture device")
        } catch {
            stopAggregate()
            throw error
        }
    }

    private func stopAggregate() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProc {
                AudioDeviceStop(aggregateID, ioProc)
                AudioDeviceDestroyIOProcID(aggregateID, ioProc)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        ioProc = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw ProcessTapError.status(step, status) }
    }

    // MARK: Delivery (IO queue)

    private func deliver(_ input: UnsafePointer<AudioBufferList>, time: UnsafePointer<AudioTimeStamp>) {
        lock.lock()
        let format = self.format, handler = onBuffer
        lock.unlock()
        guard let format, let handler else { return }
        // The aggregate lists its clock device's streams first; the tap's buffers are the last ones.
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let needed = format.isInterleaved ? 1 : Int(format.channelCount)
        guard list.count >= needed else { return }
        let first = list.count - needed
        let bytesPerFrame = max(1, Int(format.streamDescription.pointee.mBytesPerFrame))
        let frames = Int(list[first].mDataByteSize) / bytesPerFrame
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let destination = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        // Only float audio is inspected; anything else counts as heard so the watchdog stays quiet.
        var heard = format.commonFormat != .pcmFormatFloat32
        for index in 0..<needed {
            guard let source = list[first + index].mData, let target = destination[index].mData else { return }
            let bytes = Int(min(list[first + index].mDataByteSize, destination[index].mDataByteSize))
            memcpy(target, source, bytes)
            if !heard && format.commonFormat == .pcmFormatFloat32 {
                var peak: Float = 0
                vDSP_maxmgv(source.assumingMemoryBound(to: Float.self), 1, &peak, vDSP_Length(bytes / 4))
                heard = peak > 0
            }
        }
        if heard { lock.lock(); signalSeen = true; lock.unlock() }
        let stamp = time.pointee
        let host = stamp.mFlags.contains(.hostTimeValid)
            ? AVAudioTime.seconds(forHostTime: stamp.mHostTime)
            : CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        handler(buffer, host)
    }

    // MARK: Monitoring (control queue)

    private func startMonitoring() {
        let timer = DispatchSource.makeTimerSource(queue: control)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        guard !finished else { return }
        ticks += 1
        let processes = AudioProcessCatalog.processes(for: target, in: AudioProcessCatalog.all(), excluding: getpid())
        lock.lock(); let heard = signalSeen; lock.unlock()
        if !heard && processes.contains(where: \.isRunningOutput) {
            silentWhilePlaying += 1
            if silentWhilePlaying == Self.silenceLimit {
                report(.failed(ProcessTapError.silent(target.displayName)))
            }
        }
        // Follow helper processes that start mid-call.
        if ticks % 3 == 0 {
            let objects = processes.map(\.objectID)
            if !objects.isEmpty && Set(objects) != Set(processObjects) {
                processObjects = objects
                capturedBundleIDs = Array(Set(capturedBundleIDs + processes.map(\.bundleID))).sorted()
                updateTapProcesses()
            }
        }
    }

    private func updateTapProcesses() {
        let description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        description.uuid = tapUUID
        description.name = "Daybook call capture"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var address = CoreAudioProperty.address(kAudioTapPropertyDescription)
        var reference = description
        let status = withUnsafeMutablePointer(to: &reference) {
            AudioObjectSetPropertyData(tapID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        if status != noErr { rebuild(reason: "The call app started a new audio process; capture restarted to include it.") }
    }

    private func outputDeviceChanged() {
        // A data-source change on the same device (headphone jack) needs no rebuild.
        guard !finished, let device = AudioRouteMonitor.defaultOutputDevice(), device != clockDevice else { return }
        rebuild(reason: "The output device changed to \(AudioRouteMonitor.currentRoute().deviceName); call capture moved with it.")
    }

    /// Recreates the tap and aggregate (for example on the new output device). The writer pads the
    /// short gap and starts a new clock segment.
    private func rebuild(reason: String) {
        stopAggregate()
        destroyTap()
        do {
            try createTap()
            try createAggregateAndStart()
            report(.deviceChanged(reason))
        } catch {
            report(.failed(error))
        }
    }

    private func report(_ event: CaptureSourceEvent) {
        lock.lock(); let handler = onEvent; lock.unlock()
        handler?(event)
    }
}
