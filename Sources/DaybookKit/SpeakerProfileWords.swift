import DaybookCore
import Foundation

/// Speaker Profiles' words, the same on the Mac and the iPhone: counts, where a voiceprint came from, the merge a
/// taken name offers, and what each destructive action costs, said in its confirmation.
public enum SpeakerProfileWords {
    /// Under a profile's name: "No voiceprints", "1 voiceprint", "3 voiceprints".
    public static func voiceprints(_ count: Int) -> String {
        switch count {
        case 0: return "No voiceprints"
        case 1: return "1 voiceprint"
        default: return "\(count) voiceprints"
        }
    }

    /// Settings' row: "No profiles yet", "1 profile", "3 profiles".
    public static func profiles(_ count: Int) -> String {
        switch count {
        case 0: return "No profiles yet"
        case 1: return "1 profile"
        default: return "\(count) profiles"
        }
    }

    /// Where a voiceprint came from: a name the person gave, one they confirmed, or one Daybook learned.
    public static func origin(_ print: Voiceprint) -> String {
        switch print.origin {
        case .named: return "Named"
        case .confirmed: return "Confirmed"
        case .recognized: return "Learned"
        }
    }

    /// How a profile is given to a speaker in a conversation: by voice, or by the person.
    public static func appearance(_ identity: SpeakerIdentity) -> String {
        identity.source == .recognized ? "Recognized" : "Named"
    }

    /// A conversation a voiceprint came from that isn't in the library any more.
    public static let deletedConversation = "Deleted conversation"

    /// Beside a name another profile has: "Another profile is called Vlad.", with "Merge Into Vlad".
    public static func nameTaken(by name: String) -> String { "Another profile is called \(name)." }
    public static func mergeInto(_ name: String) -> String { "Merge Into \(name)" }
    public static let mergeMenu = "Merge Into"

    public static func mergeTitle(_ profile: String, into target: String) -> String { "Merge \(profile) into \(target)?" }
    public static func mergeMessage(_ profile: String, into target: String) -> String {
        "\(profile)’s voiceprints and conversations move to \(target)."
    }

    // Destructive actions: each is confirmed with what it costs, Cancel the default, and can be undone.

    public static let deleteProfile = "Delete Profile"
    public static func deleteTitle(_ name: String) -> String { "Delete “\(name)”?" }
    public static let deleteMessage = "Daybook stops recognizing this voice on your devices. Conversations keep the name."

    public static let removeVoiceprint = "Remove Voiceprint"
    public static let removeVoiceprintTitle = "Remove this voiceprint?"
    public static func removeVoiceprintMessage(_ name: String, from conversation: String) -> String {
        "Daybook won’t learn \(name)’s voice from “\(conversation)” again."
    }

    public static let forgetLearned = "Forget Learned Voiceprints"
    public static func forgetTitle(_ name: String) -> String { "Forget the voiceprints Daybook learned for \(name)?" }
    public static let forgetMessage = "The ones from names you gave or confirmed stay."
}
