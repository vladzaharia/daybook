import DaybookCore
import Foundation

/// The people search knows by voice profile, so a person token finds every conversation the person spoke in
/// however the speaker was labelled there: a speaker whose identity is a profile (named, confirmed, or
/// recognized, after merges) counts for that profile's name, and one with no profile counts by its own name.
public struct SearchPeople: Equatable, Sendable {
    /// Each active profile's name, once.
    public private(set) var names: [String] = []
    /// The active profiles a name (compared without case, accents, or extra spaces) stands for; a merged profile's
    /// name still finds the person it was merged into.
    private var profilesByName: [String: Set<UUID>] = [:]
    /// The active profile each profile ID stands for.
    private var active: [UUID: UUID] = [:]

    public static let none = SearchPeople()

    public init() {}

    public init(_ metadata: LibraryMetadata) {
        let merges = metadata.speakerProfileMerges
        for profile in (metadata.speakerProfiles ?? []).compactMap(\.value) {
            guard let target = merges.resolve(profile.id) else { continue }
            active[profile.id] = target
            profilesByName[SpeakerProfile.normalizedName(profile.name), default: []].insert(target)
        }
        names = metadata.activeSpeakerProfiles.map(\.name).filter { !SpeakerProfile.isPlaceholder($0) }
    }

    /// Whether `name` spoke in `meeting`.
    public func spoke(_ name: String, in meeting: Meeting) -> Bool {
        let wanted = profilesByName[SpeakerProfile.normalizedName(name)] ?? []
        return meeting.speakers.contains { speaker in
            if !wanted.isEmpty, let identity = meeting.speakerIdentity(speaker.id), identity.source != .suggested,
               let profile = identity.profileID, let target = active[profile], wanted.contains(target) { return true }
            return speaker.name.caseInsensitiveCompare(name) == .orderedSame
        }
    }
}

extension LibraryController {
    /// The people search finds by profile (`SearchPeople`).
    public var searchPeople: SearchPeople { SearchPeople(metadata) }
}
