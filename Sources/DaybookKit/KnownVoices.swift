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

/// Where live identification gets known voices: the library's voice profiles
/// (`KnownVoices.fromProfiles`), or a closure in tests.
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
    /// Each voice profile (`SpeakerProfiles.swift`) with voiceprints in `space`: the person's names
    /// and what Daybook learned since, synced with the library, newest `limit` first. Voiceprints
    /// from another space, unusable ones, and ones of another size are left out.
    public static func fromProfiles(_ metadata: LibraryMetadata, space: String, dimensions: Int? = nil, limit: Int = 16) -> [KnownVoice] {
        metadata.activeSpeakerProfiles.compactMap { profile in
            let prints = metadata.voiceprints(of: profile.id).map(\.vector)
                .filter { vector in vector.space == space && vector.isUsable && dimensions.map { vector.values.count == $0 } ?? true }
            guard let size = prints.first?.values.count else { return nil }
            let vectors = prints.filter { $0.values.count == size }.prefix(limit).map(\.values)
            return KnownVoice(id: "profile:\(profile.id.uuidString)", name: profile.name, embeddingSpace: space, embeddings: Array(vectors))
        }
    }
}
