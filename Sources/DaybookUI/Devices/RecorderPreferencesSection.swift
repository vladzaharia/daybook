import DaybookDesign
import DaybookKit
import SwiftUI

/// A recorder's options, in one set of words on both devices (`RecorderStatusWords.Option`): Import automatically,
/// Record along with this device, and on the iPhone Fast transfer and Hand back to your Mac; its name with
/// Rename…; and Remove from This Mac…, which says what it does first. On a recorder's page (`.page`), a card of
/// rows on paper; in the Mac's Settings › Devices (`.form`), rows of the form's group, a part at a time.
public struct RecorderPreferencesSection: View {
    public enum Style: Sendable {
        case page
        /// Rows of a form's group, a part at a time, so each part sits with the rows it belongs with.
        case form(FormPart)
    }

    public enum FormPart: Sendable {
        /// The switches, indented under the direct link they work through.
        case options
        /// The name with Rename…, and Remove….
        case nameAndRemove
    }

    private let session: DeviceSession
    private let style: Style
    @Environment(\.recorderServices) private var services
    @State private var renaming = false
    @State private var name = ""
    @State private var confirmingRemove = false

    public init(session: DeviceSession, style: Style) {
        self.session = session
        self.style = style
    }

    /// The options this recorder has here, in order.
    @MainActor
    public static func options(_ session: DeviceSession, on place: RecorderStatusWords.Place, handsBack: Bool) -> [RecorderStatusWords.Option] {
        guard let direct = session.direct, session.kind.id != DaybookPhoneIntegration.id else { return [] }
        var options: [RecorderStatusWords.Option] = [.importAutomatically]
        if direct.capabilities.contains(.recordControl) { options.append(.recordAlong) }
        if place == .iPhone, session.hasFastTransfer { options.append(.fastTransfer) }
        if place == .iPhone, handsBack, direct is any ManagedConnection { options.append(.handBack) }
        return options
    }

    public var body: some View {
        if let services, session.kind.id != DaybookPhoneIntegration.id {
            let options = Self.options(session, on: services.place, handsBack: services.handsBack != nil)
            // Several rows (each its own row in an iPhone list): the prompts hang on the buttons that ask for them.
            switch style {
            case .page: page(options, services: services)
            case .form(.options): formOptions(options, services: services)
            case .form(.nameAndRemove): formNameAndRemove(services: services)
            }
        }
    }

    /// Rename…, with its prompt for the new name.
    private func renameButton(services: RecorderServices) -> some View {
        Button("Rename…") { startRenaming() }
            .alert("Rename \(session.device.name)", isPresented: $renaming) {
                TextField("Name", text: $name)
                Button("Cancel", role: .cancel) {}
                Button("Rename") { services.devices.rename(session.id, to: name) }
            }
    }

    /// Remove from This Mac… (or iPhone), which says what it does before it does it.
    private func confirmsRemoval<Content: View>(_ content: Content, services: RecorderServices) -> some View {
        content
            .confirmationDialog("Remove \(session.device.name)?", isPresented: $confirmingRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { services.remove(session) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(RecorderStatusWords.removeConsequence(on: services.place))
            }
    }

    // MARK: On the page

    @ViewBuilder
    private func page(_ options: [RecorderStatusWords.Option], services: RecorderServices) -> some View {
        RecorderPageHeading("Options")
        VStack(alignment: .leading, spacing: 0) {
            ForEach(options, id: \.self) { option in
                // The name on the leading edge and the switch on the trailing one, as a form's row has them.
                HStack(spacing: DaybookSpacing.s3) {
                    // The switch carries the name for VoiceOver.
                    Text(option.title(on: services.place)).daybookFont(.body).foregroundStyle(DaybookPalette.Ink.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityHidden(true)
                    Spacer(minLength: DaybookSpacing.s3)
                    Toggle(option.title(on: services.place), isOn: binding(option, services: services))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .macControlSize(.small)
                }
                .disabled(!enabled(option))
                .padding(.vertical, DaybookSpacing.s2 + 2)
                Divider()
            }
            HStack(alignment: .firstTextBaseline, spacing: DaybookSpacing.s3) {
                Text("Name").daybookFont(.body).foregroundStyle(DaybookPalette.Ink.body)
                Spacer(minLength: DaybookSpacing.s3)
                Text(session.device.name)
                    .daybookFont(.body)
                    .foregroundStyle(DaybookPalette.Ink.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                renameButton(services: services)
                    .buttonStyle(.daybookLink)
                    .daybookFont(.body)
            }
            .padding(.vertical, DaybookSpacing.s2 + 2)
        }
        .padding(.horizontal, DaybookSpacing.s3)
        .background(DaybookPalette.quietFill, in: DaybookRadius.shape(DaybookRadius.box))
        // A destructive action as a text link: the error ink, never the link's teal.
        confirmsRemoval(Button(role: .destructive) { confirmingRemove = true } label: {
            Text(RecorderStatusWords.removeTitle(on: services.place))
                .daybookFont(.body)
                .foregroundStyle(DaybookPalette.Ink.error)
                .daybookHitTarget()
        }
        .buttonStyle(.plain), services: services)
        .padding(.top, DaybookSpacing.s3)
    }

    // MARK: In a form

    private func formOptions(_ options: [RecorderStatusWords.Option], services: RecorderServices) -> some View {
        ForEach(options, id: \.self) { option in
            Toggle(option.title(on: services.place), isOn: binding(option, services: services))
                .macControlSize(.regular)
                .padding(.leading, DaybookSpacing.s5)
                .disabled(!enabled(option))
        }
    }

    @ViewBuilder
    private func formNameAndRemove(services: RecorderServices) -> some View {
        LabeledContent("Name") {
            HStack(spacing: DaybookSpacing.s2) {
                Text(session.device.name).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                renameButton(services: services)
            }
        }
        HStack {
            Spacer()
            confirmsRemoval(Button(RecorderStatusWords.removeTitle(on: services.place), role: .destructive) { confirmingRemove = true },
                            services: services)
        }
    }

    // MARK: Values

    private func startRenaming() {
        name = session.device.name
        renaming = true
    }

    /// An option works while the recorder's direct link is set up and on.
    private func enabled(_ option: RecorderStatusWords.Option) -> Bool {
        guard let direct = session.direct else { return false }
        switch option {
        case .importAutomatically, .recordAlong: return direct.isSetUp && session.device.isEnabled(.direct)
        case .fastTransfer, .handBack: return true
        }
    }

    private func binding(_ option: RecorderStatusWords.Option, services: RecorderServices) -> Binding<Bool> {
        switch option {
        case .importAutomatically:
            return Binding(get: { session.device.importsAutomatically }, set: { on in session.update { $0.importsAutomatically = on } })
        case .recordAlong:
            // Off: this device doesn't start it, its button doesn't start this device, and (on an iPhone) its
            // link isn't held in the background for that.
            return Binding(get: { session.device.recordsAlongsideMac }, set: { on in session.update { $0.alsoRecordsWithMac = on } })
        case .fastTransfer:
            return Binding(get: { session.device.usesFastTransfer }, set: { on in session.update { $0.fastTransferForLongRecordings = on } })
        case .handBack:
            return services.handsBack ?? .constant(false)
        }
    }
}
