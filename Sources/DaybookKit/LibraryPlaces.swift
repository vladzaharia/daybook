import DaybookCore
import Foundation

/// The library's sections: everything, Work, and Personal.
public enum LibrarySection: String, CaseIterable, Identifiable, Sendable {
    case all = "All Conversations", work = "Work", personal = "Personal"
    public var id: String { rawValue }
    public var systemImage: String {
        switch self {
        case .all: return "tray.full"
        case .work: return "briefcase"
        case .personal: return "house"
        }
    }
    /// The person's placement wins. Otherwise the detected kind decides, and a conversation whose
    /// kind isn't known yet appears only in All, so a private conversation is never filed under Work by guess.
    public func contains(_ meeting: Meeting) -> Bool {
        switch self {
        case .all: return true
        case .work: return meeting.effectivePlacement == .work
        case .personal: return meeting.effectivePlacement == .personal
        }
    }
}

extension Meeting {
    /// Work or Personal: the person's placement, else what the detected kind suggests.
    public var effectivePlacement: LibraryPlacement? {
        if let placement { return placement }
        switch displayKind {
        case .auto: return nil
        case .therapy, .personal: return .personal
        default: return .work
        }
    }

    /// Automatic classification remains separate from the person's template selection.
    public var displayKind: MeetingKind { kind == .auto ? summary?.kind ?? .auto : kind }
}

/// Where the library is looking: a section, a folder, or a recorder's page.
public enum LibraryPlace: Hashable, Sendable {
    /// `device` is a configured device's ID.
    case section(LibrarySection), folder(UUID), device(String)

    public var isDevice: Bool { if case .device = self { return true } else { return false } }
    public var deviceID: String? { if case .device(let id) = self { return id } else { return nil } }

    /// The conversations this place lists, newest first. A device's page lists its recordings instead.
    public func meetings(in meetings: [Meeting]) -> [Meeting] {
        meetings.filter { meeting in
            switch self {
            case .section(let section): return section.contains(meeting)
            case .folder(let id): return meeting.folderID == id
            case .device: return false
            }
        }.sorted { $0.date > $1.date }
    }
}

/// A search refinement chosen from suggestions.
public enum SearchToken: Hashable, Identifiable, Sendable {
    case tag(String), speaker(String)
    public var id: String { switch self { case .tag(let tag): return "tag:" + tag; case .speaker(let name): return "speaker:" + name } }
}

/// Where a search looks.
public enum SearchScope: Hashable, Sendable { case all, work, personal, folder(UUID) }
