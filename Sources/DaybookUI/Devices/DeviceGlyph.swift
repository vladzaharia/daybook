import DaybookDesign
import DaybookKit
import SwiftUI

/// A recorder's symbol on its tile, the same on both apps: teal while the recorder is linked, neutral otherwise. The
/// status sheet's card, the Mac's Device Details, and a recorder's page at a narrow width (`.header`) draw it.
public struct DeviceGlyph: View {
    private let session: DeviceSession
    private let size: DaybookTileSize

    public init(session: DeviceSession, size: DaybookTileSize = .card) {
        self.session = session
        self.size = size
    }

    /// The tile's tone: teal only while the recorder is linked.
    public static func tone(linked: Bool) -> DaybookTile.Tone { linked ? .active : .neutral }

    public var body: some View {
        DaybookTile(symbol: session.kind.systemImage, tone: Self.tone(linked: session.isLinked), size: size)
    }
}
