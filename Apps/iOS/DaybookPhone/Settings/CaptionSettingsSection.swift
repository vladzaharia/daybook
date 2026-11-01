import DaybookCaptions
import DaybookKit
import SwiftUI

// MARK: Live captions

/// Live captions while recording, and their language, with an honest word on whether they can run.
struct CaptionSettingsSection: View {
    @Environment(PhoneAppModel.self) private var model
    @State private var availability: LiveCaptionAvailability?
    @State private var locales: [Locale] = []

    var body: some View {
        @Bindable var settings = model.settings
        Section {
            Toggle("Live Captions While Recording", isOn: $settings.liveCaptions)
            if settings.liveCaptions {
                Picker("Language", selection: $settings.captionLocaleIdentifier) {
                    Text("Same as iPhone").tag(String?.none)
                    ForEach(locales, id: \.identifier) { locale in
                        Text(LiveCaptionAvailability.name(locale)).tag(Optional(locale.identifier))
                    }
                }
            }
        } footer: {
            if let footer { Text(footer) }
        }
        .task(id: settings.captionLocaleIdentifier) {
            if locales.isEmpty { locales = await LiveCaptionAvailability.supportedLocales() }
            availability = await LiveCaptionAvailability.check(locale: settings.captionLocale)
        }
    }

    private var footer: String? {
        switch availability {
        case .needsDownload(let locale)?:
            return "Captions for \(LiveCaptionAvailability.name(locale)) download the first time you record with them on."
        case .unavailable(let reason)?: return reason
        case .ready?, nil: return nil
        }
    }
}
