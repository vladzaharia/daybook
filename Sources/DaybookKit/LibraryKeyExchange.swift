import DaybookCore
import DaybookLink
import Foundation

// An encrypted library's key between paired devices over the local link (LinkLibraryKey.swift, docs/link.md): what the
// apps send and keep. A device waiting for the key asks a paired device; one holding it sends it only to a paired
// device whose library is its own, and says so.

extension LibrarySyncController {
    /// What to ask a paired device for while this device waits for its library's key; nil when it isn't waiting.
    public func libraryKeyRequest() async -> LinkLibraryKeyRequest? {
        guard let waiting = await keyRequest() else { return nil }
        return LinkLibraryKeyRequest(libraryID: waiting.libraryID, keyIDs: [waiting.keyID])
    }

    /// The keys to send a paired device that asked: none unless its library (`peerLibraryID`, from its capabilities)
    /// is this one's.
    public func libraryKeyGrants(for request: LinkLibraryKeyRequest, peerLibraryID: UUID?) async -> [LinkLibraryKeyGrant] {
        guard let libraryID = await libraryID() else { return [] }
        let held = await keysToGrant(libraryID: libraryID).map { (id: $0.idHex, key: $0.materialBytes) }
        return request.grants(toPeerOf: peerLibraryID, libraryID: libraryID, held: held)
    }

    /// Keeps a key a paired device sent, when it's one of this library's. True when kept (a pass follows).
    @discardableResult
    public func accept(_ grant: LinkLibraryKeyGrant) async -> Bool {
        guard let id = LibraryKey.id(hex: grant.keyID) else { return false }
        return await acceptKey(grant.key, keyID: id, libraryID: grant.libraryID)
    }
}
