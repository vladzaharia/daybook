import DaybookCore
import DaybookIntelligence
import DaybookKit

// MARK: - Shared vocabulary

extension SummaryTemplate {
    /// Built-ins have their own symbol; the person's own templates are documents.
    var systemImage: String {
        switch id {
        case "planning": return "calendar"
        case "retrospective": return "arrow.uturn.backward.circle"
        case "customer-discovery": return "binoculars"
        case "design-review": return "paintbrush.pointed"
        case "decision-memo": return "checkmark.seal"
        default: return isBuiltIn ? kind.systemImage : "doc.text"
        }
    }
}

extension MeetingKind {
    var systemImage: String {
        switch self {
        case .auto: return "text.bubble"
        case .general: return "person.3"
        case .oneOnOne: return "person.2"
        case .scrum: return "sunrise"
        case .therapy: return "heart.text.square"
        case .personal: return "house"
        case .interview: return "person.crop.rectangle"
        case .lecture: return "graduationcap"
        }
    }
    /// Plain words for the Automatic template's guess: "looks like a 1:1".
    var looksLike: String {
        switch self {
        case .auto: return "Automatic"
        case .general: return "a meeting"
        case .oneOnOne: return "a 1:1"
        case .scrum: return "a standup"
        case .therapy: return "a therapy session"
        case .personal: return "a personal conversation"
        case .interview: return "an interview"
        case .lecture: return "a lecture"
        }
    }
}

extension AudioSource {
    var systemImage: String {
        switch self {
        case .microphone: return "mic"
        case .systemAudio: return "desktopcomputer"
        case .soundcore: return "recordingtape"
        case .imported: return "doc"
        }
    }
}
