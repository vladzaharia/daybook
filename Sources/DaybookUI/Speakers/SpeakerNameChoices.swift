import DaybookCore
import Foundation

/// One suggestion under a speaker's name field: a profile, or the name as typed to add as a new one.
struct SpeakerNameChoice: Equatable, Identifiable {
    enum Kind: Equatable { case profile(UUID), add }
    var kind: Kind
    var name: String
    /// The profile is the person's own.
    var isMe = false

    /// The row's profile; nil for Add “<name>”.
    var profileID: UUID? {
        if case .profile(let id) = kind { return id }
        return nil
    }

    var id: String {
        switch kind {
        case .profile(let id): return id.uuidString
        case .add: return "add"
        }
    }
}

/// The rows under a speaker's name field (`SpeakerNameField`): the library's profiles that fit what is typed, then
/// Add “<name>” when no profile has that name. Pure, so the order and the filter are tested without a view.
enum SpeakerNameChoices {
    /// - Parameters:
    ///   - profiles: The library's active profiles. Merged-away profiles and placeholder names are left out here too.
    ///   - me: The profile that is the person's own; it comes first.
    ///   - query: What is typed; empty lists every profile. Compared like `SpeakerProfile.normalizedName`.
    /// Matches that start with the query come before ones that only contain it, each in the profiles' own order
    /// (localized, case-insensitive), the person's own profile before them all.
    static func rows(profiles: [SpeakerProfile], me: UUID?, query: String) -> [SpeakerNameChoice] {
        let wanted = SpeakerProfile.normalizedName(query)
        let people = profiles.filter { $0.mergedInto == nil && !SpeakerProfile.isPlaceholder($0.name) }
        var ranked: [(rank: Int, profile: SpeakerProfile)] = []
        for profile in people {
            let name = SpeakerProfile.normalizedName(profile.name)
            if wanted.isEmpty || name.hasPrefix(wanted) { ranked.append((1, profile)) }
            else if name.contains(wanted) { ranked.append((2, profile)) }
        }
        ranked.sort { a, b in
            let (aMe, bMe) = (a.profile.id == me, b.profile.id == me)
            if aMe != bMe { return aMe }
            if a.rank != b.rank { return a.rank < b.rank }
            let order = a.profile.name.localizedCaseInsensitiveCompare(b.profile.name)
            return order == .orderedSame ? a.profile.id.uuidString < b.profile.id.uuidString : order == .orderedAscending
        }
        var rows = ranked.map { SpeakerNameChoice(kind: .profile($0.profile.id), name: $0.profile.name, isMe: $0.profile.id == me) }
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !SpeakerProfile.isPlaceholder(typed), !people.contains(where: { SpeakerProfile.normalizedName($0.name) == wanted }) {
            rows.append(SpeakerNameChoice(kind: .add, name: typed))
        }
        return rows
    }
}
