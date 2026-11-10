import DaybookCaptions
import DaybookDesign
import DaybookKit
import Foundation
import Observation
import SwiftUI

/// A device's live caption preferences, as Settings changes them: on or off, and the language. Each app's
/// own settings (never synced) conform.
@MainActor
public protocol LiveCaptionPreferences: AnyObject, Observable {
    var captionsEnabled: Bool { get set }
    /// Nil follows the device's language.
    var captionLanguage: String? { get set }
}

extension LiveCaptionPreferences {
    /// The language captions listen in.
    public var captionLocale: Locale { captionLanguage.map(Locale.init(identifier:)) ?? .current }
}

/// Live captions in Settings, the same on the Mac and the iPhone: on or off, the language, and, while
/// they're on, a plain word on whether they can run in it. The languages are the Speech framework's and
/// those the downloaded live recognizers cover (`liveLanguages`); `liveCovers` says a downloaded recognizer
/// covers the chosen one, which then captions with nothing more to download. Asking never downloads
/// anything. Its header is title case, as Settings' section headers are on both; its labels are sentence case on the
/// Mac, and the iPhone title-cases them (`SettingsWords.titleCased`).
public struct LiveCaptionSettingsSection<Settings: LiveCaptionPreferences>: View {
    @Bindable private var settings: Settings
    private let liveLanguages: [String]
    private let liveCovers: Bool
    private let deviceName: String
    private let systemCaptions: Bool
    @State private var availability: LiveCaptionAvailability?
    @State private var speechLocales: [Locale] = []
    @Environment(\.daybookDensity) private var density

    /// - Parameters:
    ///   - deviceName: The device's own name in a sentence's middle: "This Mac", "This iPhone".
    ///   - systemCaptions: Whether the Speech framework captions here (macOS 26; every iPhone Daybook runs on).
    public init(settings: Settings, liveLanguages: [String], liveCovers: Bool, deviceName: String,
                systemCaptions: Bool = LiveCaptionAvailability.systemSupportsCaptions) {
        self.settings = settings
        self.liveLanguages = liveLanguages
        self.liveCovers = liveCovers
        self.deviceName = deviceName
        self.systemCaptions = systemCaptions
    }

    private var supported: Bool { LiveCaptionLanguages.supported(systemCaptions: systemCaptions, liveLanguages: liveLanguages) }
    private var locales: [Locale] {
        LiveCaptionLanguages.options(speech: speechLocales, live: liveLanguages, selected: settings.captionLanguage)
    }

    /// A label as this device's Settings set them.
    private func words(_ text: String) -> String { density == .touch ? SettingsWords.titleCased(text) : text }

    public var body: some View {
        Section {
            Toggle(words("Show while recording"), isOn: $settings.captionsEnabled)
                .macControlSize(.regular)
                .disabled(!supported)
            if supported && settings.captionsEnabled {
                Picker(words("Language"), selection: $settings.captionLanguage) {
                    Text("Same as \(deviceName)").tag(String?.none)
                    if !locales.isEmpty { Divider() }
                    ForEach(locales, id: \.identifier) { locale in
                        Text(LiveCaptionAvailability.name(locale)).tag(Optional(locale.identifier))
                    }
                }
            }
        } header: {
            Text("Live Captions")
        } footer: {
            if let footer = LiveCaptionLanguages.footer(systemCaptions: systemCaptions, liveLanguages: liveLanguages, liveCovers: liveCovers,
                                                        enabled: settings.captionsEnabled, locale: settings.captionLocale,
                                                        availability: availability) {
                SettingsFooter(footer)
            }
        }
        .task(id: settings.captionLanguage) {
            guard systemCaptions else { return }
            if speechLocales.isEmpty { speechLocales = await LiveCaptionAvailability.supportedLocales() }
            availability = await LiveCaptionAvailability.check(locale: settings.captionLocale)
        }
    }
}
