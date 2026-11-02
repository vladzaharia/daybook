import Foundation

// Taking back a request (Cancel on a waiting line): the device that asked may withdraw what no device has started. A
// withdrawn request finishes like any other, so every device stops waiting for it and none claims it, and it stays in
// the conversation as provenance. Nothing goes to Version History: nothing the person wrote changed.

extension ProcessingRequest {
    /// What a withdrawn request's outcome says, so this version tells it from work that was done. Devices without this
    /// file read the outcome as completed: a finished request, never a failure.
    public static let withdrawnMessage = "Withdrawn"

    /// The request taken back by `device`, the one that asked for it, at `now`; nil when it isn't that device's, has
    /// finished, or another device is working on it (it can still be paused there).
    public func withdrawn(by device: Device, at now: Date, observations: ClaimObservations = .shared) -> ProcessingRequest? {
        guard isWithdrawable(by: device, at: now, observations: observations) else { return nil }
        var copy = self
        copy.outcome = Outcome(result: .completed, device: device, finishedAt: now, message: Self.withdrawnMessage)
        return copy
    }

    /// Whether `device` may take the request back now: it asked for it, it's open, and no device holds a live claim.
    public func isWithdrawable(by device: Device, at now: Date, observations: ClaimObservations = .shared) -> Bool {
        isOpen && requestedBy.id == device.id && activeClaim(at: now, observations: observations) == nil
    }

    /// The device that asked took it back before any device started it.
    public var isWithdrawn: Bool {
        guard let outcome, outcome.result == .completed else { return false }
        return outcome.device.id == requestedBy.id && outcome.message == Self.withdrawnMessage
    }
}

extension Meeting {
    /// Takes back the request `requestID` for `device` (`ProcessingRequest.withdrawn`). Returns whether it did.
    @discardableResult
    public mutating func withdrawProcessingRequest(_ requestID: UUID, by device: ProcessingRequest.Device, at now: Date,
                                                   observations: ClaimObservations = .shared) -> Bool {
        guard let request = processingRequests?.first(where: { $0.id == requestID }),
              let withdrawn = request.withdrawn(by: device, at: now, observations: observations) else { return false }
        upsertProcessingRequest(withdrawn)
        return true
    }
}
