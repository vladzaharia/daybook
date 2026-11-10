import AppKit
import DaybookCaptions
import DaybookCore
import DaybookDevices
import DaybookKit
import DaybookLink
import DaybookUI
import Foundation
import SwiftUI

/// Asks the main window to present Add Device: the kind chooser, or one kind's setup, optionally
/// for an existing device (to add its other methods) or straight to one method.
struct AddDeviceRequest: Identifiable, Equatable {
    let id = UUID()
    var kindID: String?
    var method: ConnectionMethodKind?
}

/// The devices' side of the app: wiring the hub to the library, and the device actions that need it.
extension AppState {
    var hasDevices: Bool { devices.hasDevices }

    /// The device the sidebar has selected, if any.
    var selectedDevice: DeviceSession? { window.place.deviceID.flatMap { devices.session($0) } }

    /// Opens a conversation in the library.
    func showConversation(_ id: UUID) {
        window.place = .section(.all)
        window.openID = id
    }

    /// Add Device…, or one kind's setup.
    func requestAddDevice(kind: String? = nil, method: ConnectionMethodKind? = nil) {
        addDeviceRequest = AddDeviceRequest(kindID: kind, method: method)
    }

    /// Opens a device's page.
    func showDevice(_ id: String) {
        window.place = .device(id)
        window.selection = []
    }

    /// Removes a device. Imported recordings stay; the sidebar leaves its page if it was showing.
    func removeDevice(_ id: String) {
        devices.remove(id)
        if window.place == .device(id) { window.place = .section(.all) }
    }

    /// Forgets one of a device's methods; the device goes when its last method does.
    func forgetDeviceMethod(_ method: ConnectionMethodKind, of id: String) {
        devices.forget(method, of: id)
        if window.place == .device(id), devices.session(id) == nil { window.place = .section(.all) }
    }

    /// Choose Folder… for a device's files method. Suggests iCloud Drive, where a phone's Save to
    /// Files lands. Returns whether a folder was chosen.
    @discardableResult
    func chooseDeviceFolder(for session: DeviceSession) -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Watch Folder"
        let source = session.kind.id == SoundcoreWorkIntegration.id ? "the Soundcore app" : "your recorder"
        panel.message = "Choose where you save recordings exported from \(source), such as a “Daybook Import” folder in iCloud Drive."
        // The person's iCloud Drive (`UserHome`), not the sandbox container's. Existence can be checked anywhere; the
        // panel falls back on its own when iCloud Drive itself is missing.
        let suggested = UserHome.iCloudDrive.appendingPathComponent("Daybook Import", isDirectory: true)
        panel.directoryURL = FileManager.default.fileExists(atPath: suggested.path) ? suggested : UserHome.iCloudDrive
        // Choosing again (in the App Sandbox a bookmark made before can stop working): start beside where it was.
        if let known = session.files?.suggestedFolder { panel.directoryURL = known.deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url, let files = session.files else { return false }
        do {
            try files.watch(url)
            session.update { $0.disabledMethods.remove(.files) }
            if devices.pendingSetup === session { devices.commitSetup() }
            return true
        } catch {
            report("Couldn’t Use That Folder", "Choose another folder.", error)
            return false
        }
    }

    // MARK: The recorder screens both apps share (DaybookUI)

    /// What the shared recorder screens need from this Mac: its words, its handoff and library, and what only the
    /// Mac does (Finder, the open panel, Settings › Devices, the details popover).
    var recorderServices: RecorderServices {
        let phoneLink = phoneLink
        return RecorderServices(
            place: .mac, handoff: recorderHandoff, devices: devices, library: library, thisDeviceSymbol: Self.thisMacSymbol,
            processingLabel: { [weak self] in self?.deviceProcessingLabel($0) },
            showConversation: { [weak self] in self?.showConversation($0) },
            linkState: { session in
                phoneLink.phoneRecorders.values.joined().first { $0.kind == session.kind.id && $0.serial != nil && $0.serial == session.recorderSerial }
            },
            openSystemSettings: { action in
                switch action {
                case .openPrivacySettings: PrivacySettings.open(.bluetooth)
                default:
                    if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") { NSWorkspace.shared.open(url) }
                }
            },
            stopImporting: { session, all in session.requestStop(all: all) },
            showDetails: { session in session.browser.showingDetails = true },
            remove: { [weak self] session in self?.removeDevice(session.id) },
            captionStatus: { [weak self] state in LiveCaptionStatus.line(state, locale: self?.captionSettings.locale ?? .current) },
            chooseFolder: { [weak self] session in self?.chooseDeviceFolder(for: session) ?? false },
            revealFolder: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
            revealAudio: { [weak self] meetingID, recordingID in
                guard let self else { return }
                DeviceActions.revealAudio(state: self, meetingID: meetingID, recordingID: recordingID)
            },
            setUpMethod: { [weak self] session, method in self?.requestAddDevice(kind: session.kind.id, method: method) },
            showListenLive: { session in session.browser.selection = [.recordingNow] },
            detailsPopover: { session in AnyView(DeviceDetailsView(session: session, browser: session.browser)) })
    }

    /// This Mac's glyph: a MacBook's laptop, another Mac's desktop (`SettingsWords.thisDeviceSymbol`).
    static let thisMacSymbol: String = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let identifier = String(cString: model)
        return SettingsWords.thisDeviceSymbol(model: identifier, name: Host.current().localizedName)
    }()

    /// "Transcribing", "Summarizing", or "Waiting to transcribe" for a conversation still being processed.
    func deviceProcessingLabel(_ id: UUID) -> String? {
        guard let meeting = meetings.first(where: { $0.id == id }) else { return processor.queue.queuedIDs.contains(id) ? "Waiting to transcribe" : nil }
        switch processingStatus(for: meeting) {
        case .processing(let progress) where progress.device == nil: return progress.stage == .summarizing ? "Summarizing" : "Transcribing"
        case .requested(.queued): return "Waiting to transcribe"
        default: return nil
        }
    }

    /// The title a recorder's new conversation starts with: "Soundcore Work at 10:02 AM", or the
    /// file's name for an exported file.
    func deviceMeetingTitle(_ url: URL, _ identity: DeviceRecordingIdentity) -> String {
        guard let start = deviceRecordingStart(identity) else { return url.deletingPathExtension().lastPathComponent }
        let name = DeviceCatalog.kind(identity.kind)?.name ?? "Recorder"
        return "\(name) at \(start.formatted(date: .omitted, time: .shortened))"
    }

    /// When a recorder's recording started, when its ID says (Soundcore IDs are Unix start times).
    func deviceRecordingStart(_ identity: DeviceRecordingIdentity) -> Date? { DeviceRecordingStart.date(of: identity) }

    /// Connects the devices to the library. Call once from `init`.
    func wireDevices() {
        devices.importer = { [weak self] url, identity, attachTo, source in
            guard let self else { throw AppError.libraryUnavailable }
            return try await self.importFromDevice(url, identity: identity, attachTo: attachTo, source: source)
        }
        devices.observeLibrary { [weak self] in (self?.meetings ?? [], self?.isReady == true) }
        // One Bluetooth owner per recorder: a recorder the iPhone (or another Mac) manages isn't
        // connected here; its recordings arrive through sync.
        let thisDevice = library.thisDevice.id
        devices.observeOwnership { [weak library] in (library?.recorderOwners ?? [], thisDevice) }
        wireRecorderHandoff()
        wireSources()
        devices.onRecorderButton = { [weak self] session, on in self?.recorderButton(session, on) }
    }

    /// A recorder this Mac manages started or stopped from its own button, which this Mac hears while
    /// it's connected (docs/multipoint.md, "Starting anywhere"). Started, this Mac records too (and so
    /// every device that records along with it), or the recorder joins the recording under way; stopped,
    /// the recording it's part of stops everywhere. Its "Record along" preference decides, and this Mac
    /// never asks for the microphone for it: nobody may be at the Mac to answer.
    func recorderButton(_ session: DeviceSession, _ on: Bool) {
        guard isReady, session.managedElsewhere == nil, session.device.recordsAlongsideMac else { return }
        if on {
            if let id = recordingID { sources.recorders.recorderJoined(session, meetingID: id); return }
            guard !isStartingRecording, !isStoppingRecording, microphoneAccess() == .authorized else { return }
            pendingRecorderLead = session.id
            Task {
                if let start = phoneCapture.start {
                    _ = await start(newMeeting(title: "Conversation at \(Date().formatted(date: .omitted, time: .shortened))", selecting: false), nil)
                } else {
                    await startRecording(from: .elsewhere)
                }
                if recordingID == nil { pendingRecorderLead = nil }
            }
        } else {
            guard let id = recordingID, !isStoppingRecording, sources.recorders.records(session.id, in: id) else { return }
            post(["\(session.device.name) stopped recording, so this Mac stopped too."])
            Task { if let stop = phoneCapture.stop { await stop(id) } else { await stopRecording(manual: true) } }
        }
    }

    // MARK: Recorder handoff (docs/devices.md, "Handing a recorder over")

    /// The handoff talks to phones over the link; the device page, Settings, and the menu bar read its states.
    private func wireRecorderHandoff() {
        let link = phoneLink
        recorderHandoff.link = RecorderHandoff.Link(peers: {
            link.peers.values.map { peer in
                RecorderHandoff.Peer(linkID: peer.deviceID, syncID: peer.capabilities.syncDeviceID, name: peer.name,
                                     deviceClass: peer.deviceClass == .mac ? .mac : .phone,
                                     handsOffRecorders: peer.capabilities.handsOffRecorders)
            }
        }, send: { message, phone in try await link.send(message, to: phone) })
        watches.append(ObservationWatch({ _ = link.peers; _ = link.paired }) { [weak self] in self?.recorderHandoff.peersChanged() })
    }

    /// "Use on This Mac": nobody manages the recorder, or this Mac does: connect. A phone does: ask
    /// it to let go (over Wi‑Fi in seconds when it's connected, otherwise through iCloud), then connect.
    func useRecorderOnThisMac(_ session: DeviceSession) {
        recorderHandoff.useHere(session)
    }

    /// "Use on Alex’s iPhone": offers the recorder to a connected phone.
    func giveRecorder(_ session: DeviceSession, to peer: RecorderHandoff.Peer) { recorderHandoff.give(session, to: peer) }

    /// Phones on Wi‑Fi this Mac could hand the recorder to.
    func handoffTargets(for session: DeviceSession) -> [RecorderHandoff.Peer] { recorderHandoff.peersToGive(session) }

    /// The handoff's headline for a recorder, when one is under way or just answered.
    func handoffLine(for session: DeviceSession) -> String? {
        RecorderHandoff.Words.headline(recorderHandoff.state(of: session), recorder: session.device.name, here: "this Mac")
    }

    /// A recorder's recording, into `attachTo` when that conversation still exists. Without one, a
    /// multipoint link or a match in time and sound can still add it to an existing conversation.
    func importFromDevice(_ url: URL, identity: DeviceRecordingIdentity, attachTo: UUID?, source: AudioSource) async throws -> UUID {
        // Another device's import of it may have arrived through sync while it transferred: keep that one.
        if let held = DeviceLibraryLinks.meeting(holding: identity, in: meetings) { return held }
        let attach = attachTo.flatMap { id in meetings.contains { $0.id == id } ? id : nil }
        guard let id = try await importAudio([url], source: source, attachTo: attach, device: identity).first else {
            throw AppError.invalidAudio(url.lastPathComponent)
        }
        return id
    }
}

