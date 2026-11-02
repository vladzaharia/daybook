import DaybookKit
import DaybookUI
import SwiftUI

/// Settings › About: DaybookUI's `AboutScreen`, with the version, the privacy statement the Mac shows too, and
/// Acknowledgements.
struct AboutPage: View {
    var body: some View {
        AboutScreen(acknowledgements: SettingsRoute.acknowledgements)
    }
}

/// Settings › About › Acknowledgements: DaybookUI's `AcknowledgementsScreen`, the Mac's too. The models this iPhone
/// can use (live captions' and its own processing's) and those behind the library's results, by the rule both apps
/// follow, then the software it ships with the notices and licenses its bundle carries.
struct AcknowledgementsPage: View {
    @Environment(PhoneAppModel.self) private var model

    /// The models this iPhone credits (`ModelAcknowledgements.entries`).
    @MainActor
    static func entries(for model: PhoneAppModel) -> [ModelAcknowledgement] {
        let models = model.models
        let usable = Set((models.roles + models.processingRoles).flatMap(models.options(for:)).map(\.key))
        return ModelAcknowledgements.entries(from: models.catalog, usable: usable, meetings: model.library.controller.meetings)
    }

    var body: some View {
        AcknowledgementsScreen(entries: Self.entries(for: model))
    }
}
