import DaybookKit
import DaybookUI
import SwiftUI

/// A recorder's handoff in the status sheet's recorder card (docs/devices.md, "Handing a recorder over"): the rows
/// both apps draw (DaybookUI's `RecorderHandoffView`), as the card's rows. "Use on This iPhone" while a Mac manages
/// it, "Use on Studio Mac" while this iPhone does and the Mac is on Wi‑Fi, and the handoff's progress in between,
/// with Stop Waiting wherever waiting can be called off. "Managed by" is the line above them, not repeated.
struct RecorderHandoffCard: View {
    let session: DeviceSession
    @Environment(PhoneAppModel.self) private var model
    @Environment(\.openURL) private var openURL

    /// Whether there's anything to show: a handoff under way, or one to offer.
    @MainActor
    static func shows(_ session: DeviceSession, devices: PhoneDevices) -> Bool {
        RecorderHandoffView.shows(session, handoff: devices.handoff)
    }

    var body: some View {
        RecorderHandoffView(session: session, style: .card)
            .environment(\.recorderServices, PhoneRecorderServices.make(model: model, openURL: openURL))
    }
}
