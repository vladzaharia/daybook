import Foundation

// An encrypted library's key over the local link (docs/link.md, "Library keys"): the fallback when iCloud Keychain is
// off on a device, or slow to bring the key. A device waiting for the key asks a paired device; one holding it sends it
// only when the asker is paired (every link session is) and its library is the holder's own. The link is end-to-end
// encrypted with the pairing's key. Additive within protocol version 1: an older build ignores both types, and the
// asker keeps waiting for iCloud Keychain.
//
//   waiting device                 holder
//   libraryKey.request  →
//                       ←          libraryKey.grant   (one per key it holds of those asked for)

/// "Send me this library's key."
public struct LinkLibraryKeyRequest: Codable, Sendable, Equatable {
    public var libraryID: UUID
    /// The keys it needs, by ID (32 hex digits), the current one first.
    public var keyIDs: [String]

    public init(libraryID: UUID, keyIDs: [String]) {
        self.libraryID = libraryID
        self.keyIDs = keyIDs
    }
}

/// A library key.
public struct LinkLibraryKeyGrant: Codable, Sendable, Equatable {
    public var libraryID: UUID
    /// The key's ID (32 hex digits).
    public var keyID: String
    /// The key's 32 bytes.
    public var key: Data

    public init(libraryID: UUID, keyID: String, key: Data) {
        self.libraryID = libraryID
        self.keyID = keyID
        self.key = key
    }
}

extension LinkLibraryKeyRequest {
    /// What to send back to a paired peer for this request: nothing unless the peer's library (`peerLibraryID`, from its
    /// capabilities) is this device's, and only keys asked for. `held` are the keys this device holds for its library
    /// (ID in hex, bytes).
    public func grants(toPeerOf peerLibraryID: UUID?, libraryID ownLibraryID: UUID?,
                       held: [(id: String, key: Data)]) -> [LinkLibraryKeyGrant] {
        guard let ownLibraryID, libraryID == ownLibraryID, peerLibraryID == ownLibraryID else { return [] }
        let wanted = Set(keyIDs)
        return held.filter { wanted.contains($0.id) && $0.key.count == 32 }
            .map { LinkLibraryKeyGrant(libraryID: ownLibraryID, keyID: $0.id, key: $0.key) }
    }
}
