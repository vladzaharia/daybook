import AppKit
import Combine
import DaybookCore
import DaybookKit
import DaybookLink
import Foundation

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
    var selectedDevice: DeviceSession? { place.deviceID.flatMap { devices.session($0) } }

    /// Opens a conversation in the library.
    func showConversation(_ id: UUID) {
        place = .section(.all)
        selectedID = id
    }

    /// Add Device…, or one kind's setup.
    func requestAddDevice(kind: String? = nil, method: ConnectionMethodKind? = nil) {
        addDeviceRequest = AddDeviceRequest(kindID: kind, method: method)
    }

    /// Opens a device's page.
    func showDevice(_ id: String) {
        place = .device(id)
        multiSelection = []
    }

    /// Removes a device. Imported recordings stay; the sidebar leaves its page if it was showing.
    func removeDevice(_ id: String) {
        devices.remove(id)
        if place == .device(id) { place = .section(.all) }
    }

    /// Forgets one of a device's methods; the device goes when its last method does.
    func forgetDeviceMethod(_ method: ConnectionMethodKind, of id: String) {
        devices.forget(method, of: id)
        if place == .device(id), devices.session(id) == nil { place = .section(.all) }
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

    /// "Transcribing", "Summarizing", or "Waiting to transcribe" for a conversation still being processed.
    func deviceProcessingLabel(_ id: UUID) -> String? {
        guard let meeting = meetings.first(where: { $0.id == id }) else { return queuedIDs.contains(id) ? "Waiting to transcribe" : nil }
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
        devices.observeLibrary(library.$meetings.combineLatest($isReady).eraseToAnyPublisher())
        // One Bluetooth owner per recorder: a recorder the iPhone (or another Mac) manages isn't
        // connected here; its recordings arrive through sync.
        let thisDevice = library.thisDevice.id
        devices.observeOwnership(library.$metadata.map { ($0.recorderOwners, thisDevice) }
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }.eraseToAnyPublisher())
        wireRecorderHandoff()
        wireSources()
    }

    // MARK: Recorder handoff (docs/devices.md, "Handing a recorder over")

    /// The handoff talks to phones over the link; its states redraw the device page, Settings, and
    /// the menu bar.
    private func wireRecorderHandoff() {
        let link = phoneLink
        recorderHandoff.link = RecorderHandoff.Link(peers: {
            link.peers.values.map { peer in
                RecorderHandoff.Peer(linkID: peer.deviceID, syncID: peer.capabilities.syncDeviceID, name: peer.name,
                                     deviceClass: peer.deviceClass == .mac ? .mac : .phone,
                                     handsOffRecorders: peer.capabilities.handsOffRecorders)
            }
        }, send: { message, phone in try await link.send(message, to: phone) })
        recorderHandoff.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        phoneLink.changes.sink { [weak self] _ in
            DispatchQueue.main.async { self?.recorderHandoff.peersChanged() }
        }.store(in: &subscriptions)
    }

    /// "Use on This Mac": nobody manages the recorder, or this Mac does: connect. A phone does: ask
    /// it to let go (over Wi‑Fi in seconds when it's connected, otherwise through iCloud), then connect.
    func useRecorderOnThisMac(_ session: DeviceSession) {
        recorderHandoff.useHere(session)
    }

    /// Take Over Anyway, after the person confirmed the risk.
    func takeOverRecorder(_ session: DeviceSession) { recorderHandoff.takeOverAnyway(session) }

    /// Stops waiting for the other device, or clears its answer.
    func cancelRecorderHandoff(_ session: DeviceSession) {
        if recorderHandoff.state(of: session).isPending { recorderHandoff.cancel(session) } else { recorderHandoff.dismiss(session) }
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

