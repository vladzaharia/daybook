import DaybookCore
import Foundation

/// Settings' words, written once for both apps in sentence case (docs/interface.md, "Words"): model roles, cloud
/// providers, tiers, effort and policy, where a voiceprint came from, how much is stored, and counts. A Mac shows
/// them as they are; the iPhone's Settings title-cases its labels once, where it draws them (`titleCased`), as each
/// platform's guidelines ask.
public enum SettingsWords {
    /// What Settings calls a model role: "Transcription", "Voice profiles". A role a newer catalog names reads as
    /// its identifier in words ("imageCaptions" → "Image captions").
    public static func role(_ role: ModelRole) -> String {
        switch role {
        case .transcription: return "Transcription"
        case .diarization: return "Speakers"
        case .speakerEmbedding: return "Voice profiles"
        case .summarization: return "Summaries"
        case .smallTasks: return "Titles and tags"
        case .imageDescription: return "Photos"
        case .liveTranscription: return "Live transcription"
        case .liveDiarization: return "Live speakers"
        default: return words(role.rawValue)
        }
    }

    /// The role as the subject of a sentence: "Speaker detection will use Sortformer 2.1."
    public static func roleSubject(_ role: ModelRole) -> String { role == .diarization ? "Speaker detection" : self.role(role) }

    /// "imageCaptions" or "image_captions" → "Image captions".
    public static func words(_ identifier: String) -> String {
        var result = ""
        for character in identifier {
            if character == "_" || character == "-" { result += " "; continue }
            if character.isUppercase, !result.isEmpty, result.last != " " { result += " " }
            result.append(contentsOf: result.isEmpty ? character.uppercased() : character.lowercased())
        }
        return result
    }

    // MARK: Cloud

    public static func provider(_ provider: CloudProvider) -> String { provider == .anthropic ? "Anthropic" : "OpenAI" }

    public static func tier(_ tier: CloudTier) -> String {
        switch tier {
        case .best: return "Best"
        case .balanced: return "Balanced"
        case .economy: return "Economy"
        }
    }

    public static func effort(_ effort: CloudEffort) -> String {
        switch effort {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    /// Use the cloud: "Offer first", "Always", "Never".
    public static func policy(_ policy: CloudSummaryPreferences.Policy) -> String {
        switch policy {
        case .ask: return "Offer first"
        case .always: return "Always"
        case .never: return "Never"
        }
    }

    /// A countdown's length: "15 seconds".
    public static func seconds(_ seconds: Int) -> String { seconds == 1 ? "1 second" : "\(seconds) seconds" }

    // MARK: Speaker profiles

    /// Where a voiceprint came from: "Named", "Confirmed", "Learned".
    public static func origin(_ origin: Voiceprint.Origin) -> String {
        switch origin {
        case .named: return "Named"
        case .confirmed: return "Confirmed"
        case .recognized: return "Learned"
        }
    }

    // MARK: Counts

    /// The vocabulary: every term, wherever it's used (a term from one conversation is used there), as both apps'
    /// Vocabulary lists them: "No terms yet", "1 term", "12 terms".
    public static func vocabulary(_ terms: [GlossaryTerm]) -> String { vocabulary(count: terms.count) }

    public static func vocabulary(count: Int) -> String {
        count == 0 ? "No terms yet" : count == 1 ? "1 term" : "\(count) terms"
    }

    /// Speaker profiles: "No profiles yet", "1 profile", "4 profiles".
    public static func profiles(_ count: Int) -> String {
        count == 0 ? "No profiles yet" : count == 1 ? "1 profile" : "\(count) profiles"
    }

    /// Summary templates: "12 built-in", "12 built-in, 2 yours".
    public static func templates(builtIn: Int, yours: Int) -> String {
        yours == 0 ? "\(builtIn) built-in" : "\(builtIn) built-in, \(yours) yours"
    }

    /// The same from the library's templates.
    public static func templates(_ templates: [SummaryTemplate]) -> String {
        let yours = templates.filter { !$0.isBuiltIn }.count
        return self.templates(builtIn: SummaryTemplate.builtIns.count, yours: yours)
    }

    // MARK: Devices

    /// A device's glyph in Settings and sync lists, by what it is: a MacBook's laptop, another Mac's desktop, an
    /// iPhone. `name` is the device's name or model ("Vlad's MacBook Pro", "MacBookPro18,3", "Mac mini").
    public static func deviceSymbol(_ deviceClass: SyncDeviceClass?, name: String? = nil) -> String {
        switch deviceClass {
        case .mac?: return isLaptop(name) ? "laptopcomputer" : "desktopcomputer"
        case .phone?: return "iphone"
        case .other?, nil: return "questionmark.app.dashed"
        }
    }

    /// This device's glyph from its model ("MacBook Pro (14-inch, M5 Pro)", "MacBookPro18,3", "iPhone17,1"): a MacBook's
    /// laptop, another Mac's desktop, an iPhone. A model that doesn't say ("Mac17,9") falls back to the name.
    public static func thisDeviceSymbol(model: String, name: String? = nil) -> String {
        if model.hasPrefix("iPhone") || model.hasPrefix("iPad") { return "iphone" }
        return isLaptop(model) || isLaptop(name) ? "laptopcomputer" : "desktopcomputer"
    }

    static func isLaptop(_ text: String?) -> Bool {
        guard let text else { return false }
        return text.range(of: "MacBook", options: .caseInsensitive) != nil
    }

    // MARK: Casing

    /// A sentence-case label as a title-case one, as the iPhone's Settings shows labels ("Use the cloud" → "Use the
    /// Cloud", "15 seconds" → "15 Seconds", "Third-party notices" → "Third-Party Notices"). Short words that aren't
    /// first stay lowercase; words with capitals of their own ("iCloud", "iPhone", "JSON") keep them.
    public static func titleCased(_ text: String) -> String {
        let minor: Set<String> = ["a", "an", "and", "as", "at", "but", "by", "for", "in", "nor", "of", "on", "or", "the", "to", "up", "via", "with"]
        var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        for index in words.indices {
            let word = words[index]
            // A word with its own capitals (iCloud) stays as it is.
            if word.dropFirst().contains(where: \.isUppercase) { continue }
            let last = index == words.count - 1
            if index > 0, !last, minor.contains(word.lowercased()) { continue }
            // Each part of a hyphenated word ("Third-party").
            words[index] = word.split(separator: "-", omittingEmptySubsequences: false)
                .map { part in part.first.map { $0.uppercased() + part.dropFirst() } ?? "" }
                .joined(separator: "-")
        }
        return words.joined(separator: " ")
    }
}

/// Summary Templates' words on both apps. Labels in sentence case, as `SettingsWords`; menu and button titles as
/// both platforms write them.
public enum TemplateWords {
    public static let title = "Summary Templates"
    public static let builtIn = "Built-in"
    public static let yours = "Yours"
    /// A template with no name, and the name a new one starts with.
    public static let untitled = "Untitled Template"
    public static let newTemplate = "New Template"
    public static let duplicate = "Duplicate"
    public static let restoreOriginal = "Restore Original"
    public static let deleteTemplate = "Delete Template…"
    public static let more = "More"
    /// A built-in that differs from its original.
    public static let edited = "Edited"
    public static let youEdited = "You edited this template."
    public static let name = "Name"
    public static let usedFor = "Used for"
    public static let usedForHelp = "Chosen automatically for this kind of conversation."
    public static let instructions = "Instructions"
    public static let instructionsHelp = "Describe the purpose, the sections you want, and the tone."
    public static let noneSelected = "No Template Selected"
    public static let removed = "Template Removed"

    /// Deleting one of your own: "Delete “Board update”?", and what happens to the conversations that used it.
    public static func deleteTitle(_ template: SummaryTemplate) -> String { "Delete “\(template.displayName)”?" }
    public static let deleteConsequence = "Conversations that used it switch to Automatic."
    public static let delete = "Delete"
}

/// Vocabulary's words on both apps.
public enum VocabularyWords {
    public static let title = "Vocabulary"
    public static let term = "Term"
    public static let alsoHeardAs = "Also heard as"
    public static let meaning = "Meaning"
    public static let usedIn = "Used in"
    public static let addTerm = "Add Term"
    public static let editTerm = "Edit Term"
    public static let searchPrompt = "Search Terms"
    public static let emptyTitle = "No Terms Yet"
    public static let emptyMessage = "Add names, products, and words to spell your way."
    /// The term field's placeholder: how it's spelled.
    public static let spelledAs = "Spelled as"
    /// The other spellings field's placeholder, short enough for a page of the open iPhone Duo.
    public static let otherSpellings = "Other spellings"
    public static let otherSpellingsFooter = "Spellings the transcript might use, separated by commas, such as “day book” for Daybook."
    public static let optional = "Optional"
    /// A new row's prompts in the Mac's table, and a meaning's on hover.
    public static let newTerm = "New Term"
    public static let addMeaning = "Add meaning"
    public static let addSpellings = "Add spellings"
    public static let showConversation = "Show Conversation"

    public static let allConversations = "All conversations"
    /// "Only “Weekly product sync”".
    public static func only(_ title: String) -> String { "Only “\(title)”" }
    /// A term from a conversation that's gone, in warning ink.
    public static let noConversations = "No conversations"
    public static let noConversationsHelp = "Not used in any conversation. Choose All Conversations to use it everywhere."

    /// Delete for a term used everywhere; confirmed (with the ellipsis) for one limited to a conversation.
    public static let deleteTerm = "Delete Term"
    public static let deleteTermConfirming = "Delete Term…"
    public static func deleteTerms(_ count: Int) -> String { count == 1 ? deleteTerm : "Delete \(count) Terms" }
    public static func deleteTitle(_ terms: [GlossaryTerm]) -> String {
        terms.count == 1 ? "Delete “\(terms[0].term)”?" : "Delete \(terms.count) Terms?"
    }

    /// What deleting terms limited to a conversation does there: "“Weekly product sync” won’t use it when it’s
    /// transcribed again.", "them" for several terms from that conversation. Nil for terms from conversations
    /// that are gone.
    public static func deleteConsequence(_ scopes: [TermScope]) -> String? {
        let limited = scopes.filter { $0.conversationID != nil }
        guard case .conversation(_, let title)? = limited.first else { return nil }
        if Set(limited.compactMap(\.conversationID)).count == 1 {
            return "“\(title)” won’t use \(limited.count == 1 ? "it" : "them") when it’s transcribed again."
        }
        return "Their conversations won’t use them when they’re transcribed again."
    }

    // The undo menu's action names.
    public static let undoAdd = "Add Term"
    public static let undoRename = "Rename Term"
    public static let undoMeaning = "Change Meaning"
    public static let undoSpellings = "Change Other Spellings"
    public static let undoScope = "Change Where Term Is Used"
    public static let undoEdit = "Edit Term"
    public static func undoDelete(_ count: Int) -> String { count == 1 ? "Delete Term" : "Delete Terms" }
}

/// The privacy statement, the same on both apps (docs/interface.md, principle 6): Settings › Library on the Mac,
/// Settings › About on the iPhone.
public enum PrivacyWords {
    public static let statement = "Recordings, notes, and transcripts stay on your devices, and in your own iCloud when sync is on. A summary goes to a cloud model only when you choose one."
}

/// About's words on both apps.
public enum AboutWords {
    public static let title = "About"
    public static let appName = "Daybook"
    public static let privacy = "Privacy"
    public static let acknowledgements = "Acknowledgements"
    public static let models = "Models"
    public static let software = "Software"
    public static let thirdPartyNotices = "Third-party notices"
    public static let license = "License"
    public static let notice = "Notice"
    public static let use = "Use"

    /// "Version 0.1.0 (1)", as the Mac's About panel says it; nil for a development build without a version.
    public static func version(_ info: [String: Any]?) -> String? {
        guard let short = info?["CFBundleShortVersionString"] as? String, !short.isEmpty else { return nil }
        guard let build = info?["CFBundleVersion"] as? String, !build.isEmpty, build != short else { return "Version \(short)" }
        return "Version \(short) (\(build))"
    }
}

/// A size on disk or to download, the same on both apps: "632 MB", "1.6 GB". Whole megabytes under a gigabyte, one
/// decimal above; decimal units, as Finder counts them.
public enum ByteSize {
    public static func format(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0 MB" }
        return bytes >= 1_000_000_000 ? String(format: "%.1f GB", Double(bytes) / 1e9) : "\(max(1, Int((Double(bytes) / 1e6).rounded()))) MB"
    }

    /// Downloaded so far: "120 of 632 MB", "0.4 of 1.6 GB".
    public static func progress(_ done: Int64, of total: Int64) -> String {
        guard total >= 1_000_000_000 else { return "\(format(max(0, done)).replacingOccurrences(of: " MB", with: "")) of \(format(total))" }
        return String(format: "%.1f of %.1f GB", Double(max(0, done)) / 1e9, Double(total) / 1e9)
    }
}

extension ModelRole {
    /// What Settings calls the role, on both apps (`SettingsWords.role`).
    public var displayName: String { SettingsWords.role(self) }
}

extension KnownSyncDevice {
    /// Its glyph in sync and encryption lists (`SettingsWords.deviceSymbol`).
    public var systemImage: String { SettingsWords.deviceSymbol(deviceClass, name: displayName) }
}
