import DaybookCore
import DaybookDesign
import DaybookKit
import DaybookLink
import DaybookUI
import SwiftUI

/// The device page for Daybook on iPhone: the shared page for a paired Daybook (`PeerDevicePage`), as the iPhone's
/// page for a Mac shows it. Whether it's connected, what it's recording with Stop on it, the recorders it manages,
/// whether it can start recording here, its facts, and Unpair, with what needs the person (pairing again, or sync
/// that's off). Nothing imports from it: its recordings are conversations already, arrive through sync, and are the
/// list beside the page.
struct PhoneOverview: View {
    let state: AppState
    let session: DeviceSession
    /// Sync turning on or off redraws the page (its problem says when it's off).
    private let sync: LibrarySyncController
    @Environment(\.openWindow) private var openSettingsWindow

    init(state: AppState, session: DeviceSession) {
        self.state = state
        self.session = session
        sync = state.sync
    }

    private var phone: PhoneLinkConnection? { session.direct as? PhoneLinkConnection }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            PeerDevicePage(PeerPage(facts(now: context.date), here: PairingWords.here(.mac), now: context.date), actions: actions)
        }
        .scrollContentBackground(.hidden)
        .background(DaybookPalette.paper)
    }

    /// What the page says, from the phone's link and its device.
    private func facts(now: Date) -> PeerPage.Facts {
        let phase = phone?.recordingPhase
        let conversation = phone?.recordingConversationID
        let phoneID = UUID(uuidString: session.id)
        // Stop is taken when the phone stops for a page (and hasn't said this Mac may not start recording there), or
        // when it records this conversation with this Mac.
        let recordsTogether = conversation.map { id in
            state.recordingID == id && (state.phoneLeads[id]?.sessionID == session.id || state.isRecording(id, with: session.id))
        } ?? false
        let problem: PeerPage.Problem?
        if phone?.isDamaged == true {
            problem = .damaged
        } else if let phone, !phone.isSetUp {
            problem = .notPaired
        } else if let deviceProblem = session.problem {
            // Sync is off: the one thing that keeps its recordings from arriving.
            problem = .other(deviceProblem.message)
        } else {
            problem = nil
        }
        return PeerPage.Facts(
            id: session.id, name: session.device.name, kind: .iPhone, isConnected: session.direct?.state.isConnected == true,
            activity: phase == .paused ? .paused : phase == nil ? .idle : .recording,
            lastSeen: session.direct?.lastConnectedAt, recordingSince: session.status?.recordingStartedAt,
            conversationTitle: conversation.flatMap { id in state.meetings.first { $0.id == id }?.title },
            canStop: (phone?.stopsForPages == true && phone?.takesStarts == true) || recordsTogether,
            recorders: phone?.recorders(now: now) ?? [],
            transcribes: phone?.peer?.capabilities.processing?.transcribes,
            appVersion: phone?.peer?.capabilities.appVersion,
            pairedAt: phoneID.flatMap { id in state.phoneLink.paired.first { $0.deviceID == id }?.pairedAt },
            problem: problem)
    }

    private var actions: PeerPageActions {
        let phoneID = UUID(uuidString: session.id)
        let conversation = phone?.recordingConversationID
        return PeerPageActions(
            openConversation: conversation.map { id in { state.showConversation(id) } },
            stop: phone.map { phone in { phone.pauseRecording() } },
            stopPending: phone?.recordCommandPending == true,
            pairAgain: { state.requestAddDevice(kind: DaybookPhoneIntegration.id) },
            problemAction: session.problem == nil ? nil : (title: "Library Settings…", perform: {
                LaunchOptions.defaults.set(SettingsPane.library.rawValue, forKey: SettingsPane.storageKey)
                openSettingsWindow.settings()
            }),
            canStartRecording: phone?.isSetUp == true ? Binding(get: { session.device.recordsAlongsideMac },
                                                               set: { on in session.update { $0.alsoRecordsWithMac = on } }) : nil,
            unpair: {
                if let phoneID, state.phoneLink.isPaired(phoneID) { state.unpairPhone(phoneID) } else { state.removeDevice(session.id) }
            })
    }
}
