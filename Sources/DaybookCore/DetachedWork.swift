import Foundation

/// Long work run off the caller's actor (fusion, echo removal, comparing recordings' sound) that is
/// cancelled when the caller is. A plain `Task.detached` keeps running after the job that awaited it
/// was paused or the app began quitting; this passes the cancellation on, and the work stops at its
/// next check.
public func detachedWork<T: Sendable>(priority: TaskPriority? = nil, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let task = Task.detached(priority: priority, operation: operation)
    return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
}

/// The same, for work that can't fail: cancelled with the caller, it still returns what it made.
public func detachedWork<T: Sendable>(priority: TaskPriority? = nil, _ operation: @escaping @Sendable () async -> T) async -> T {
    let task = Task.detached(priority: priority, operation: operation)
    return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
}
