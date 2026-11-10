import DaybookCore
import Foundation
import Synchronization

/// Keys kept in memory. Share one between replicas to play iCloud Keychain carrying a key everywhere; give each its own
/// to play a device the key hasn't reached.
public final class MemoryLibraryKeyStore: LibraryKeyStore, Sendable {
    private struct State {
        var held: [UUID: [Data: LibraryKey]] = [:]
        var failure: LibraryKeyStoreError?
    }
    private let state: Mutex<State>

    public init(_ keys: [LibraryKey] = []) {
        var initial = State()
        for key in keys { initial.held[key.libraryID, default: [:]][key.id] = key }
        state = Mutex(initial)
    }

    public func keys(for libraryID: UUID) throws -> [LibraryKey] {
        try state.withLock { state in
            if let failure = state.failure { throw failure }
            return state.held[libraryID].map { Array($0.values).sorted { $0.idHex < $1.idHex } } ?? []
        }
    }

    public func store(_ key: LibraryKey) throws {
        try state.withLock { state in
            if let failure = state.failure { throw failure }
            state.held[key.libraryID, default: [:]][key.id] = key
        }
    }

    public func remove(keyID: Data, libraryID: UUID) throws {
        state.withLock { _ = $0.held[libraryID]?.removeValue(forKey: keyID) }
    }

    /// Makes every call fail as a keychain that refuses would (nil: work again). Tests.
    public func fail(with error: LibraryKeyStoreError?) { state.withLock { $0.failure = error } }

    /// Every key held, for any library. Tests.
    public var allKeys: [LibraryKey] { state.withLock { $0.held.values.flatMap(\.values) } }
}
