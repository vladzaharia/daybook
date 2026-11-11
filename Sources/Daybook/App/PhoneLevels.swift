import DaybookLink
import Foundation

/// The input levels paired iPhones send while they record a conversation with this Mac (`LinkLevels`,
/// a few readings a few times a second), kept for Floating Notes' meters to play back at their own
/// pace, a reading a tick (`LevelPlayback`); and this Mac's own level on its way to those iPhones
/// (`LevelShare`). Not observable: only the meters read it, fifteen times a second.
@MainActor
final class PhoneLevels {
    /// How long a phone's level counts as current after its last message.
    static let lifetime = LevelPlayback.lifetime
    /// The most readings waiting per phone, about a second's: older ones go first, so the meter keeps up.
    static let backlog = LevelPlayback.backlog

    private var playback = LevelPlayback()
    /// This Mac's readings, for the recording they're shared from.
    private var share = LevelShare()
    private var sharing: UUID?

    func receive(_ message: LinkLevels, from phone: UUID, at now: Date = Date()) {
        playback.receive(message, from: phone, at: now)
    }

    /// The phone's next reading for `conversation`; nil when it hasn't sent one lately (an iPhone that
    /// doesn't send levels, or one that stopped). Between messages the last reading fades.
    func next(_ phone: UUID, conversation: UUID, at now: Date = Date()) -> Double? {
        playback.next(phone, conversation: conversation, at: now)
    }

    /// The phone's newest reading for `conversation`, leaving the meter's queue as it is; nil when it hasn't
    /// sent one lately. Live captions compare it with other sources' (`LiveCaptionMixer`).
    func last(_ phone: UUID, conversation: UUID, at now: Date = Date()) -> Double? {
        playback.last(phone, conversation: conversation, at: now)
    }

    /// Adds this Mac's reading while it records `conversation`; returns the readings to send when it's time. A new
    /// recording starts a new batch.
    func share(_ value: Double, for conversation: UUID, at now: Date) -> [Double]? {
        if sharing != conversation {
            sharing = conversation
            share = LevelShare()
        }
        return share.add(value, at: now)
    }

    func reset() {
        playback.reset()
        share = LevelShare()
        sharing = nil
    }
}

extension AppState {
    /// A paired iPhone recording this conversation too sent its input level: Floating Notes draws it.
    func phoneLevelled(_ message: LinkLevels, from phone: UUID) {
        guard let id = recordingID, message.conversationID == id else { return }
        phoneLevels.receive(message, from: phone)
    }

    /// This Mac's meter read its levels (fifteen times a second while it records): an iPhone recording this
    /// conversation too that draws other devices' levels gets them, the louder of the microphone and computer audio
    /// each tick, a few readings at a time about five times a second (`LevelShare`), so the iPhone's recorder meters
    /// this Mac beside its own microphone. Never queued behind other messages (`PhoneLink.sendLevels`).
    func shareLevel(microphone: Double, call: Double?, at now: Date = Date()) {
        guard let id = recordingID, phoneLink.hasConnectedPhones,
              let values = phoneLevels.share(max(microphone, call ?? 0), for: id, at: now) else { return }
        let phones = phonesShowingLevels(of: id)
        guard !phones.isEmpty else { return }
        phoneLink.sendLevels(LinkLevels(conversationID: id, values: values, interval: RecordingController.levelInterval, sentAt: now),
                             to: phones)
    }

    /// The iPhones recording conversation `id` with this Mac that draw other devices' levels (`liveLevels`): an
    /// older iPhone, which doesn't list it, is never sent this Mac's.
    func phonesShowingLevels(of id: UUID) -> [UUID] {
        guard recordingID == id else { return [] }
        return phoneLink.peers.values.filter { $0.capabilities.showsLevels && isRecording(id, with: $0.deviceID.uuidString) }
            .map(\.deviceID)
    }
}
