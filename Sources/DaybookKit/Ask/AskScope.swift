import DaybookCore
import Foundation

/// Where a question looks: the search field's scope and tokens, a date range, or one conversation, and what the
/// Personal lock and a Focus allow.
public struct AskScope: Equatable, Sendable {
    /// What may be read of Personal conversations. A locked place is never read: not indexed, not in any scope.
    public enum Personal: Equatable, Sendable {
        /// The lock is off or unlocked: Personal is in All and Personal, as search has it.
        case included
        /// The lock is on and locked.
        case locked
        /// A Focus leaves Personal out of the library's places, so out of every scope.
        case hiddenByFocus

        /// What `lock` allows now.
        @MainActor public init(_ lock: PersonalLock) {
            self = !lock.focus.showsPersonal ? .hiddenByFocus : lock.isLocked ? .locked : .included
        }

        /// Whether a Personal conversation may be asked about.
        public var allowsPersonal: Bool { self == .included }
    }

    public var search: SearchScope
    public var tokens: [SearchToken]
    /// Only this conversation; nil asks the scope.
    public var conversation: UUID?
    /// Conversations from these dates. A question that names dates narrows it further.
    public var dates: AskDateRange?
    public var personal: Personal

    public init(search: SearchScope = .all, tokens: [SearchToken] = [], conversation: UUID? = nil, dates: AskDateRange? = nil,
                personal: Personal = .included) {
        self.search = search; self.tokens = tokens; self.conversation = conversation; self.dates = dates; self.personal = personal
    }

    /// The conversations of `meetings` this scope reads, before any date a question names. Personal ones are out
    /// when the lock or a Focus says so, whatever the scope.
    public func conversations(in meetings: [Meeting]) -> [Meeting] {
        meetings.filter { meeting in
            if meeting.effectivePlacement == .personal, !personal.allowsPersonal { return false }
            if let conversation, meeting.id != conversation { return false }
            if let dates, !dates.contains(meeting.date) { return false }
            switch search {
            case .all: break
            case .work: guard LibrarySection.work.contains(meeting) else { return false }
            case .personal: guard LibrarySection.personal.contains(meeting) else { return false }
            case .folder(let id): guard meeting.folderID == id else { return false }
            }
            return tokens.allSatisfy { token in
                switch token {
                case .tag(let tag): return (meeting.tags ?? []).contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
                case .speaker(let name): return meeting.speakers.contains { AskWords.sameName($0.name, name) }
                }
            }
        }
    }
}
