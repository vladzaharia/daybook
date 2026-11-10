import Foundation

/// A metadata-only projection written after the library loads. The extension never opens the library.
struct SharedRecentConversations: Codable, Equatable, Sendable {
  struct Conversation: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let date: Date
  }

  static let limit = 6
  static let cache = SharedWidgetCache(fileName: "snapshot.json")
  static let widgetKind = "local.daybook.phone.recent-conversations"
  static let legacyDefaultsKey = "recent-conversations"

  /// Clears the title-bearing app-group preference used by earlier widget builds.
  @discardableResult
  static func removeLegacySnapshot(from defaults: UserDefaults = SharedRecordingState.defaults)
    -> Bool
  {
    let existed = defaults.object(forKey: legacyDefaultsKey) != nil
    defaults.removeObject(forKey: legacyDefaultsKey)
    return existed
  }

  private(set) var conversations: [Conversation]

  init(_ conversations: [Conversation] = []) {
    self.conversations = Array(conversations.prefix(Self.limit))
  }

  /// Nil means the app hasn't published a loaded library yet (or the stored snapshot is unreadable).
  static func load(from container: URL? = SharedWidgetCache.groupContainer) -> Self? {
    guard let snapshot = cache.load(Self.self, from: container) else { return nil }
    return Self(snapshot.conversations)
  }

  /// The snapshot as the widget reads it: there, not there, or there but locked away until the iPhone is unlocked.
  static func read(from container: URL? = SharedWidgetCache.groupContainer) -> SharedWidgetCache.Read<Self> {
    switch cache.read(Self.self, from: container) {
    case .value(let snapshot): return .value(Self(snapshot.conversations))
    case .missing: return .missing
    case .locked: return .locked
    }
  }

  /// `protects`: "Protect while iPhone is locked" (`SharedWidgetCache.save`).
  @discardableResult
  func save(to container: URL? = SharedWidgetCache.groupContainer, protects: Bool = false) -> Bool {
    Self.cache.save(Self(conversations), to: container, protects: protects)
  }

}

/// A widget opens the library, an exact conversation, or a new note, without private text in the URL.
enum WidgetLink: Equatable {
  case library
  case conversation(UUID)
  case newNote

  var url: URL {
    switch self {
    case .library: return URL(string: "daybook://library")!
    case .conversation(let id): return URL(string: "daybook://conversation/\(id.uuidString)")!
    case .newNote: return URL(string: "daybook://new-note")!
    }
  }

  init?(url: URL) {
    guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
      parts.scheme?.lowercased() == "daybook", parts.user == nil, parts.password == nil,
      parts.port == nil, parts.query == nil, parts.fragment == nil
    else { return nil }
    switch parts.host?.lowercased() {
    case "library" where parts.path.isEmpty:
      self = .library
    case "new-note" where parts.path.isEmpty:
      self = .newNote
    case "conversation":
      guard parts.path.hasPrefix("/"), let id = UUID(uuidString: String(parts.path.dropFirst()))
      else { return nil }
      self = .conversation(id)
    default:
      return nil
    }
  }
}
