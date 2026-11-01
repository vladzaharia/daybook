import DaybookCaptions
import DaybookKit
import DaybookLive
import DaybookUI
import SwiftUI

// MARK: Live captions

/// Settings › Recording › Live Captions: DaybookUI's section, as the Mac shows it, with this iPhone's
/// downloaded live recognizers. They caption before the Speech framework does wherever they cover the
/// language, so the footer and the languages count them.
struct CaptionSettingsSection: View {
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        let settings = model.settings, models = model.models
        LiveCaptionSettingsSection(settings: settings, liveLanguages: models.liveCaptionLanguages,
                                   liveCovers: models.installedSet(for: settings.captionLocale).transcribes(settings.captionLocale),
                                   deviceName: "This iPhone")
    }
}

extension PhoneSettings: LiveCaptionPreferences {
    var captionsEnabled: Bool {
        get { liveCaptions }
        set { liveCaptions = newValue }
    }

    var captionLanguage: String? {
        get { captionLocaleIdentifier }
        set { captionLocaleIdentifier = newValue }
    }
}

extension PhoneModels {
    /// The languages ("en", "ja") the downloaded live recognizers that fit this iPhone cover: the chosen
    /// one and the catalog's others, as a recording would try them.
    var liveCaptionLanguages: [String] {
        let defaults = LiveModelChoices.defaults(for: .liveTranscription, platform: .iOS, catalog: catalog, engines: LiveEngines.descriptors)
        let keys = ([choice(for: .liveTranscription)].compactMap { $0 } + defaults.compactMap { catalog.model($0) })
            .filter(fits).map(\.key)
        return LiveModelSet.languages(of: keys, inventory: inventory)
    }
}
