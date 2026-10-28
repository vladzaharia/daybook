import DaybookCore
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Processing requests: the iPhone asks, a Mac claims and runs them (docs/iphone.md). Each change
/// is one of `ProcessingRequest`'s pure functions applied to the conversation and saved, so it
/// syncs like an edit. Nothing here runs processing; the Mac's queue calls these as it works.
extension LibraryController {
    /// This device as requests record it: the sync replica's ID and the device's name.
    public var thisDevice: ProcessingRequest.Device {
        ProcessingRequest.Device(id: sync?.deviceID ?? "local", name: ProcessingRequest.Device.currentName)
    }

    /// Asks for processing. An open request for the same work is returned instead of a second one.
    @discardableResult
    public func requestProcessing(_ id: UUID, mode: ProcessingRequest.Mode, templateID: String? = nil,
                                  by device: ProcessingRequest.Device? = nil, at now: Date = Date()) -> ProcessingRequest? {
        guard let meeting = meeting(id) else { return nil }
        if let open = meeting.openProcessingRequests.first(where: { $0.mode == mode && $0.templateID == templateID && !$0.isSatisfied(by: meeting) }) {
            return open
        }
        let request = ProcessingRequest(meetingID: id, mode: mode, templateID: templateID, requestedBy: device ?? thisDevice, createdAt: now)
        update(id) { $0.upsertProcessingRequest(request) }
        return request
    }

    /// Open requests this device may take, oldest first: unclaimed, its own, or with an expired claim.
    public func processingRequestsToRun(by device: ProcessingRequest.Device? = nil, at now: Date = Date()) -> [ProcessingRequest] {
        let device = device ?? thisDevice
        return meetings.flatMap { meeting in
            meeting.openProcessingRequests.filter { $0.isClaimable(by: device, at: now) && !$0.isSatisfied(by: meeting) }
        }.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    @discardableResult
    public func claimProcessingRequest(_ requestID: UUID, in meetingID: UUID, by device: ProcessingRequest.Device? = nil,
                                       at now: Date = Date(), lease: TimeInterval = ProcessingRequest.defaultLease) -> ProcessingRequest? {
        change(requestID, in: meetingID) { $0.claimed(by: device ?? thisDevice, at: now, lease: lease) }
    }

    /// The holder's heartbeat, with coarse progress for other devices.
    @discardableResult
    public func renewProcessingClaim(_ requestID: UUID, in meetingID: UUID, stage: ProcessingRequest.Stage? = nil, fraction: Double? = nil,
                                     by device: ProcessingRequest.Device? = nil, at now: Date = Date(),
                                     lease: TimeInterval = ProcessingRequest.defaultLease) -> ProcessingRequest? {
        change(requestID, in: meetingID) { $0.renewed(by: device ?? thisDevice, at: now, lease: lease, stage: stage, fraction: fraction) }
    }

    @discardableResult
    public func releaseProcessingRequest(_ requestID: UUID, in meetingID: UUID, by device: ProcessingRequest.Device? = nil,
                                         at now: Date = Date()) -> ProcessingRequest? {
        change(requestID, in: meetingID) { $0.released(by: device ?? thisDevice, at: now) }
    }

    @discardableResult
    public func completeProcessingRequest(_ requestID: UUID, in meetingID: UUID, by device: ProcessingRequest.Device? = nil,
                                          at now: Date = Date()) -> ProcessingRequest? {
        change(requestID, in: meetingID) { $0.completed(by: device ?? thisDevice, at: now) }
    }

    @discardableResult
    public func failProcessingRequest(_ requestID: UUID, in meetingID: UUID, reason: String, by device: ProcessingRequest.Device? = nil,
                                      at now: Date = Date()) -> ProcessingRequest? {
        change(requestID, in: meetingID) { $0.failed(by: device ?? thisDevice, at: now, reason: reason) }
    }

    /// Drops claims whose lease ran out, so their requests read as waiting. Returns how many.
    @discardableResult
    public func expireStaleClaims(at now: Date = Date()) -> Int {
        var count = 0
        for meeting in meetings {
            for request in meeting.processingRequests ?? [] {
                if change(request.id, in: meeting.id, { $0.expired(at: now) }) != nil { count += 1 }
            }
        }
        return count
    }

    /// A conversation's status, with this device's queue when it processes.
    public func processingStatus(for id: UUID, queue: ProcessingStatus.LocalQueue? = nil, at now: Date = Date()) -> ProcessingStatus? {
        meeting(id).map { ProcessingStatus($0, queue: queue, now: now) }
    }

    private func change(_ requestID: UUID, in meetingID: UUID, _ transition: (ProcessingRequest) -> ProcessingRequest?) -> ProcessingRequest? {
        guard let request = meeting(meetingID)?.processingRequests?.first(where: { $0.id == requestID }),
              let changed = transition(request) else { return nil }
        update(meetingID) { $0.upsertProcessingRequest(changed) }
        return changed
    }
}

extension ProcessingRequest.Device {
    /// This device's name: the Mac's computer name, or the iPhone's. Looked up once; a demo launch
    /// sets it before anything reads it, so captures never show the real name.
    @MainActor public static var currentName: String = {
        #if os(macOS)
        return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #elseif canImport(UIKit)
        return UIDevice.current.name
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }()
}
