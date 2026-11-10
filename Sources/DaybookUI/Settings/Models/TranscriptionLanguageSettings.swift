import DaybookDesign
import DaybookKit
import SwiftUI

/// Settings › Models › Transcription › Language, the same row on both apps: the language the library's conversations
/// are transcribed in. It's a library setting that syncs (`LibraryController.transcriptionLanguage`), so a change here
/// changes what every device transcribes with. Automatic, then every language a transcription model in the catalog
/// covers, by name. In a window it's a pop-up; under touch it opens the list, as the iPhone's Settings lists languages.
public struct TranscriptionLanguageSettings: View {
    /// One choice in the list: its tag (a language code, "" for Automatic) and what it says.
    public struct Item: Equatable, Identifiable, Sendable {
        public let id: String
        public let title: String

        public init(id: String, title: String) { self.id = id; self.title = title }
    }

    @Binding private var language: String?
    private let catalog: ModelCatalog
    @Environment(\.daybookDensity) private var density

    /// - Parameters:
    ///   - language: The library's transcription language; nil for Automatic.
    ///   - catalog: The models whose languages are offered: this device's catalog, whatever it runs.
    public init(language: Binding<String?>, catalog: ModelCatalog) {
        _language = language
        self.catalog = catalog
    }

    /// What the list says, in order: Automatic, then each language by name, the stored one kept where no model covers it.
    public static func items(in catalog: ModelCatalog, keeping language: String?, locale: Locale = .current) -> [Item] {
        [Item(id: "", title: SettingsWords.automaticLanguage)]
            + TranscriptionLanguages.libraryChoices(in: catalog, keeping: language).map {
                Item(id: $0, title: SettingsWords.languageName($0, locale: locale))
            }
    }

    public var body: some View {
        let items = Self.items(in: catalog, keeping: language)
        let automatic = items[0], languages = items.dropFirst()
        Picker(SettingsWords.languageLabel, selection: selection) {
            if density == .touch {
                Section { Text(automatic.title).tag(automatic.id) }
                Section { ForEach(languages) { Text($0.title).tag($0.id) } }
            } else {
                Text(automatic.title).tag(automatic.id)
                Divider()
                ForEach(languages) { Text($0.title).tag($0.id) }
            }
        }
        #if os(iOS)
        .pickerStyle(.navigationLink)
        #endif
    }

    private var selection: Binding<String> {
        Binding(get: { language ?? "" }, set: { language = $0.isEmpty ? nil : $0 })
    }
}
