import DaybookCore
import Foundation
import Network

/// The network this device is on, for sync work that should wait for Wi‑Fi (an iPhone sealing an encrypted library's
/// history downloads recordings only then: `SyncReplicaConfiguration.network`). Restricted until the first path update,
/// so nothing large starts before it's known.
public final class NetworkConditionMonitor: @unchecked Sendable {
    public static let shared = NetworkConditionMonitor()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var current = SyncNetworkCondition.restricted
    private var handler: (@Sendable (SyncNetworkCondition) -> Void)?

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update(SyncNetworkCondition(satisfied: path.status == .satisfied, expensive: path.isExpensive, constrained: path.isConstrained))
        }
        monitor.start(queue: DispatchQueue(label: "local.daybook.network-condition", qos: .utility))
    }

    deinit { monitor.cancel() }

    /// The condition now.
    public var condition: SyncNetworkCondition { lock.withLock { current } }

    /// Called (on a background queue) when the condition changes.
    public func onChange(_ handler: (@Sendable (SyncNetworkCondition) -> Void)?) { lock.withLock { self.handler = handler } }

    private func update(_ condition: SyncNetworkCondition) {
        let changed: (@Sendable (SyncNetworkCondition) -> Void)? = lock.withLock {
            guard current != condition else { return nil }
            current = condition
            return handler
        }
        changed?(condition)
    }
}
