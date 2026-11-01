import Foundation

/// An "Upgrade" offer the person dismissed on one conversation (docs/multipoint.md, "Upgrade"): the step, the model it
/// offered, and how good the catalog said that model was. The same model, or one no better, isn't offered again for that
/// step; a later, better one may be. Synced with the conversation.
public struct UpgradeDismissal: Codable, Equatable, Identifiable, Sendable {
    /// The step (`ModelRole.rawValue`): "transcription", "diarization", or "summarization".
    public var role: String
    /// The model offered: a catalog key ("parakeet/ultra") or a cloud one ("anthropic/claude-sonnet-5-5").
    public var model: String
    /// Its rank for the role when it was offered (0–100).
    public var quality: Int
    public var dismissedAt: Date

    public init(role: String, model: String, quality: Int, dismissedAt: Date = Date()) {
        self.role = role; self.model = model; self.quality = quality; self.dismissedAt = dismissedAt
    }

    /// One per step and model.
    public var id: String { "\(role)|\(model)" }

    /// Two devices' dismissals: every one either has, once per step and model, the earlier one when both dismissed the
    /// same offer. Dismissals are never taken back, so the union is the merge, whatever the ancestor; two devices
    /// dismissing at once agree.
    public static func merged(_ lhs: [UpgradeDismissal]?, _ rhs: [UpgradeDismissal]?) -> [UpgradeDismissal]? {
        guard lhs != nil || rhs != nil else { return nil }
        var byID: [String: UpgradeDismissal] = [:]
        for dismissal in (lhs ?? []) + (rhs ?? []) {
            guard let kept = byID[dismissal.id] else { byID[dismissal.id] = dismissal; continue }
            let a = (kept.dismissedAt, SyncEncoding.string(kept)), b = (dismissal.dismissedAt, SyncEncoding.string(dismissal))
            if b < a { byID[dismissal.id] = dismissal }
        }
        let merged = byID.values.sorted { $0.id < $1.id }
        return merged.isEmpty ? nil : merged
    }
}

extension Meeting {
    /// Records that the person dismissed the offer of `model` for `role`, once.
    public mutating func dismissUpgrade(role: String, model: String, quality: Int, at now: Date = Date()) {
        let dismissal = UpgradeDismissal(role: role, model: model, quality: quality, dismissedAt: now)
        guard !(upgradeDismissals ?? []).contains(where: { $0.id == dismissal.id }) else { return }
        upgradeDismissals = UpgradeDismissal.merged(upgradeDismissals, [dismissal])
        updatedAt = max(updatedAt, now)
    }

    /// Whether an offer of `model` at `quality` for `role` stays dismissed: that model was dismissed, or one at least as good.
    public func dismissedUpgrade(role: String, model: String, quality: Int) -> Bool {
        (upgradeDismissals ?? []).contains { $0.role == role && ($0.model == model || $0.quality >= quality) }
    }
}
