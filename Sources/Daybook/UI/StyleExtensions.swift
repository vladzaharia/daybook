import DaybookCore
import DaybookIntelligence
import DaybookKit

// MARK: - Shared vocabulary

// A template's and a conversation kind's symbols are DaybookKit's (`SummaryTemplate.systemImage`,
// `MeetingKind.systemImage`), the same on the iPhone.

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
