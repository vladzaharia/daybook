import DaybookCore
import DaybookLink
import Foundation

// An encrypted library's key between paired devices over the local link (LinkLibraryKey.swift, docs/link.md): what the
// apps send and keep. A device waiting for the key asks a paired device; one holding it sends it only to a paired
// device whose library is its own, and says so.

/// A library key this device asked paired devices for: only a grant answering one is kept, and only for
/// `LibrarySyncController.keyRequestLifetime` after it was asked.
struct LibraryKeyRequestRecord: Equatable {
    var libraryID: UUID
    /// The keys asked for, by ID (hex).
    var keyIDs: Set<String>
    /// The paired devices it went to (`noteKeyRequested(from:)`); empty when the app didn't say.
    var peers: Set<UUID> = []
    var at: Date
}

extension LibrarySyncController {
    /// How long a request for a library key stays open: a paired device answers within seconds.
    static let keyRequestLifetime: TimeInterval = 10 * 60

    /// What to ask a paired device for while this device waits for its library's key; nil when it isn't waiting. Asking
    /// opens the request: a grant is kept only while one is open (`acceptKey`).
    public func libraryKeyRequest() async -> LinkLibraryKeyRequest? {
        guard let waiting = await keyRequest() else { return nil }
        let request = LinkLibraryKeyRequest(libraryID: waiting.libraryID, keyIDs: [waiting.keyID])
        let now = Date()
        keyRequests.removeAll { now.timeIntervalSince($0.at) >= Self.keyRequestLifetime || $0.libraryID != request.libraryID }
        if let index = keyRequests.firstIndex(where: { $0.keyIDs == Set(request.keyIDs) }) {
            keyRequests[index].at = now
        } else {
            keyRequests.append(LibraryKeyRequestRecord(libraryID: request.libraryID, keyIDs: Set(request.keyIDs), at: now))
        }
        return request
    }

    /// The request `libraryKeyRequest()` just made went to `peer`: from now on a grant for it is kept only from a paired
    /// device it went to (`accept(_:from:)`).
    public func noteKeyRequested(from peer: UUID) {
        guard let index = keyRequests.indices.max(by: { keyRequests[$0].at < keyRequests[$1].at }) else { return }
        keyRequests[index].peers.insert(peer)
    }

    /// Whether a grant of `keyID` for `libraryID` (from `peer`, when the app says) answers a request still open.
    func answersKeyRequest(keyID: Data, libraryID: UUID, from peer: UUID?) -> Bool {
        let now = Date(), hex = keyID.lowercaseHex
        keyRequests.removeAll { now.timeIntervalSince($0.at) >= Self.keyRequestLifetime }
        return keyRequests.contains { request in
            request.libraryID == libraryID && request.keyIDs.contains(hex)
                && (request.peers.isEmpty || peer.map(request.peers.contains) == true)
        }
    }

    /// The keys to send a paired device that asked: none unless its library (`peerLibraryID`, from its capabilities)
    /// is this one's.
    public func libraryKeyGrants(for request: LinkLibraryKeyRequest, peerLibraryID: UUID?) async -> [LinkLibraryKeyGrant] {
        guard let libraryID = await libraryID() else { return [] }
        let held = await keysToGrant(libraryID: libraryID).map { (id: $0.idHex, key: $0.materialBytes) }
        return request.grants(toPeerOf: peerLibraryID, libraryID: libraryID, held: held)
    }

    /// Keeps a key a paired device (`peer`, when the app knows it) sent, when it answers a request this device made and
    /// the library lists it (`acceptKey`). True when kept (a pass follows).
    @discardableResult
    public func accept(_ grant: LinkLibraryKeyGrant, from peer: UUID? = nil) async -> Bool {
        guard let id = LibraryKey.id(hex: grant.keyID) else { return false }
        return await acceptKey(grant.key, keyID: id, libraryID: grant.libraryID, from: peer)
    }
}
