import DaybookCore
import Foundation

/// A person whose voice live captions can recognize: their name and voice embeddings, all in one
/// embedding space. Live speaker identification compares voices only within that space, so a Mac's
/// profiles name speakers on the iPhone when both run the same voice-profile model.
public struct KnownVoice: Equatable, Sendable {
    /// Stable across refreshes: the voice profile's ID, or one derived from the name.
    public var id: String
    public var name: String
    /// `capabilities.voiceEmbeddings.space` of the model that made `embeddings`.
    public var embeddingSpace: String
    /// One or more embeddings of this person's voice, newest first.
    public var embeddings: [[Float]]

    public init(id: String, name: String, embeddingSpace: String, embeddings: [[Float]]) {
        self.id = id; self.name = name; self.embeddingSpace = embeddingSpace; self.embeddings = embeddings
    }
}

/// Where live identification gets known voices. The seam synced voice profiles plug into
/// (feat/speaker-profiles): until they land, `KnownVoices.fromLibrary` stands in.
public protocol KnownVoiceSource: Sendable {
    /// Every known voice with embeddings in `space`.
    func knownVoices(in space: String) async -> [KnownVoice]
}

/// Known voices from a closure, for apps and tests.
public struct KnownVoiceProvider: KnownVoiceSource {
    private let provide: @Sendable (String) async -> [KnownVoice]
    public init(_ provide: @escaping @Sendable (String) async -> [KnownVoice]) { self.provide = provide }
    public func knownVoices(in space: String) async -> [KnownVoice] { await provide(space) }
}

public enum KnownVoices {
    /// The library's named speakers who have a voice embedding in `space`, grouped by name (case and
    /// surrounding spaces ignored), each with their newest `limit` embeddings. Speakers still called
    /// "Speaker 2" (never named), and embeddings from another space or of the wrong size, are left out.
    /// This is what live captions recognize until voice profiles sync on their own.
    public static func fromLibrary(_ meetings: [Meeting], space: String, dimensions: Int? = nil, limit: Int = 12) -> [KnownVoice] {
        var found: [String: (name: String, items: [(date: Date, vector: [Float])])] = [:]
        for meeting in meetings {
            for speaker in meeting.speakers {
                let name = speaker.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !isPlaceholder(name), speaker.embeddingModelID == space,
                      let vector = speaker.embedding, !vector.isEmpty, vector.allSatisfy(\.isFinite), vector.contains(where: { $0 != 0 }),
                      dimensions.map({ vector.count == $0 }) ?? true else { continue }
                let key = name.lowercased()
                found[key, default: (name, [])].items.append((meeting.date, vector))
            }
        }
        return found.keys.sorted().compactMap { key in
            guard let entry = found[key] else { return nil }
            let size = entry.items.first?.vector.count ?? 0
            let vectors = entry.items.filter { $0.vector.count == size }.sorted { $0.date > $1.date }.prefix(limit).map(\.vector)
            return KnownVoice(id: "name:\(key)", name: entry.name, embeddingSpace: space, embeddings: Array(vectors))
        }
    }

    /// "Speaker 3": the label speaker analysis gives a voice nobody has named.
    public static func isPlaceholder(_ name: String) -> Bool {
        let parts = name.split(separator: " ")
        return parts.count == 2 && parts[0] == "Speaker" && Int(parts[1]) != nil
    }
}
