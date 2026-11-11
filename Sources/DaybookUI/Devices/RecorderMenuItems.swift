import DaybookDesign
import DaybookKit
import SwiftUI

/// What a recorder's menus offer besides each app's own items: only what applies to it now, as plain values.
public struct RecorderMenuOffer: Equatable {
    /// Refresh Status: it's connected, and not importing or listing.
    public var refresh = false
    /// Record or Pause on the recorder.
    public var recordControl = false
    public var listenLive = false
    public var details = false
    public var connect = false
    public var disconnect = false
    /// Use on This Mac, or hand it to another device.
    public var handoff = false

    @MainActor
    public init(_ session: DeviceSession) {
        let primary = session.primary
        refresh = primary?.state.isConnected == true && session.queue.current == nil && primary?.isRefreshing != true
        let usable = session.isLinked && session.queue.current == nil
        recordControl = usable && session.direct is any RecordControlConnection
        listenLive = (usable && session.status?.isRecording == true || session.isListeningLive) && session.direct is any LiveListeningConnection
        details = session.direct is any DetailedConnection && (session.status != nil || session.isLinked)
        // Daybook on iPhone connects to the Mac itself, and Apple Watch to the iPhone through WatchConnectivity.
        guard let direct = session.direct, direct.isSetUp, session.kind.id != DaybookPhoneIntegration.id,
              session.kind.id != AppleWatchIntegration.id else { return }
        disconnect = direct.state.isConnected || direct.state.isBusy
        // Connect does nothing while another device manages it: Use on This Mac does.
        connect = !disconnect && session.managedElsewhere == nil && direct.state != .unavailable && session.device.isEnabled(.direct)
        handoff = direct is any ManagedConnection && session.recorderSerial != nil
    }
}

/// A recorder's menu items, the same list on both devices (the Mac's More menu and the iPhone's): Refresh Status;
/// Record or Pause on it, and Listen Live; Details, Connect or Disconnect, and where it can move. On the Mac what
/// can't run now is dimmed (Refresh Status); on the iPhone it's left out.
public struct RecorderMenuItems: View {
    private let session: DeviceSession
    @Environment(\.recorderServices) private var services

    public init(session: DeviceSession) { self.session = session }

    public var body: some View {
        let offer = RecorderMenuOffer(session)
        if Self.dimsWhatCantRun || offer.refresh {
            Button("Refresh Status") { session.primary?.refresh() }.disabled(!offer.refresh)
        }
        if offer.recordControl || offer.listenLive { Divider() }
        if offer.recordControl, let control = session.direct as? any RecordControlConnection {
            let action: RecorderAction = session.status?.isRecording == true ? .pause : .record
            Button(action.label(shortName: session.kind.shortName).title) {
                if action == .pause { control.pauseRecording() } else { control.startRecording() }
            }
            .disabled(control.recordCommandPending)
        }
        if offer.listenLive, let live = session.direct as? any LiveListeningConnection {
            Button(live.live.isListening ? "Stop Listening" : "Listen Live") {
                if live.live.isListening {
                    live.stopListening()
                } else {
                    session.browser.selection = [.recordingNow]
                    live.startListening()
                    services?.showListenLive?(session)
                }
            }
        }
        Divider()
        if offer.details, let services {
            Button(Self.detailsTitle) { services.showDetails(session) }
        }
        if offer.disconnect {
            Button("Disconnect") { session.disconnect(.direct) }
        } else if offer.connect {
            Button("Connect") { session.connect() }
        }
        if offer.handoff, let services {
            let state = services.handoff.state(of: session)
            let presentation = RecorderHandoffPresentation.make(
                state: state, recorder: session.device.name, managedElsewhere: session.managedElsewhere != nil,
                targets: services.handoff.peersToGive(session), overdue: false, place: services.place,
                thisDeviceSymbol: services.thisDeviceSymbol)
            if case .moves(let moves) = presentation {
                ForEach(moves) { move in
                    Button(move.title) {
                        switch move.kind {
                        case .here: services.handoff.useHere(session)
                        case .give(let link):
                            if let peer = services.handoff.peersToGive(session).first(where: { $0.linkID == link }) {
                                services.handoff.give(session, to: peer)
                            }
                        }
                    }
                }
            }
        }
    }

    /// The Mac dims a menu item that can't run now; the iPhone leaves it out.
    static var dimsWhatCantRun: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// "Device Details…" in the Mac's menu; "Details" on the iPhone, which shows a screen.
    static var detailsTitle: String {
        #if os(macOS)
        "Device Details…"
        #else
        "Details"
        #endif
    }
}
