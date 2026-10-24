import DaybookKit
import SwiftUI

/// Where playback (and Share › Audio) gets a recording's audio on this iPhone.
///
/// Sync on the phone uses an on-demand audio policy (docs/iphone.md): conversations, transcripts,
/// and summaries arrive at once, but a recording's audio downloads only when it's played, and can
/// be evicted again. Reading therefore never opens a track's file directly; it asks a provider.
///
/// Contract:
/// - `availability(of:in:)` answers quickly, without downloading, so the page can say before
///   anything is tapped whether the audio is here, can be fetched, or can't be reached now.
/// - `localAudio(for:in:progress:)` returns a readable local file URL, downloading first when it
///   must. It reports progress from 0 to 1 on any thread, as often as it likes (the player
///   throttles it), and may report nothing when the size is unknown. It honours task
///   cancellation (closing the player cancels the download) and throws
///   `AudioProvidingError.offline` when the audio isn't on this iPhone and can't be fetched now,
///   or `.missing` when no copy exists anywhere it can see.
/// - Both are called on the main actor; implementations do their work wherever they like.
///
/// The default, `LocalAudioProvider`, reads only the library's own files
/// (`PhoneLibrary.audioURL(for:in:)`): recordings made on this iPhone, or audio already
/// downloaded. The sync-backed implementation is injected at the app root:
///
///     RootView().environment(\.audioProvider, SyncedAudioProvider(…))
///
/// `RootView` binds the default to the app's library only when nothing else was injected.
protocol AudioProviding: Sendable {
    @MainActor func availability(of track: RecordingTrack, in meetingID: UUID) async -> AudioAvailability
    @MainActor func localAudio(for track: RecordingTrack, in meetingID: UUID,
                               progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}

/// Whether a recording can play right now.
enum AudioAvailability: Equatable, Sendable {
    /// On this iPhone; plays at once.
    case local
    /// In iCloud; plays after a download of about this many bytes (nil when unknown).
    case downloadable(bytes: Int64?)
    /// Not here, and can't be fetched now (offline, or iCloud is off).
    case offline
    /// No copy anywhere this iPhone can see.
    case missing
}

enum AudioProvidingError: LocalizedError, Equatable {
    case offline
    case missing
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .offline: return "The audio isn’t on this iPhone yet. It downloads when you’re online."
        case .missing: return "This recording’s audio isn’t in the library on this iPhone."
        case .notConfigured: return "Playback isn’t set up yet."
        }
    }
}

/// The default provider: the library's own files only, no network.
struct LocalAudioProvider: AudioProviding {
    /// The library to read; nil until `RootView` binds the environment's default to the app's library.
    let library: PhoneLibrary?

    init(library: PhoneLibrary? = nil) { self.library = library }

    @MainActor
    func availability(of track: RecordingTrack, in meetingID: UUID) async -> AudioAvailability {
        guard let url = try? await library?.audioURL(for: track, in: meetingID) else { return .missing }
        return FileManager.default.isReadableFile(atPath: url.path) ? .local : .offline
    }

    @MainActor
    func localAudio(for track: RecordingTrack, in meetingID: UUID, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let library else { throw AudioProvidingError.notConfigured }
        let url: URL
        do { url = try await library.audioURL(for: track, in: meetingID) } catch { throw AudioProvidingError.missing }
        // A file sync knows about but hasn't downloaded yet isn't here, which this provider can't fix.
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw AudioProvidingError.offline }
        progress(1)
        return url
    }
}

extension EnvironmentValues {
    /// Where reading gets audio. Defaults to the library's local files; see `AudioProviding`.
    @Entry var audioProvider: any AudioProviding = LocalAudioProvider()
    /// When a Mac was last heard from, if something knows better than the library (the local
    /// link). Nil derives it from the library: see `MacSighting.latest(in:excluding:)`.
    @Entry var macSighting: MacSighting? = nil
}

#if DEBUG
/// Debug screenshots of on-demand audio without iCloud: `--simulate-download` pretends each
/// recording takes half a minute to download (pausing near 40% for a while); `--simulate-offline`
/// pretends the audio isn't on this iPhone and can't be fetched.
struct SimulatedAudioProvider: AudioProviding {
    let base: LocalAudioProvider
    let offline: Bool

    static func fromArguments(_ arguments: [String] = CommandLine.arguments, base: LocalAudioProvider) -> SimulatedAudioProvider? {
        if arguments.contains("--simulate-offline") { return SimulatedAudioProvider(base: base, offline: true) }
        if arguments.contains("--simulate-download") { return SimulatedAudioProvider(base: base, offline: false) }
        return nil
    }

    @MainActor
    func availability(of track: RecordingTrack, in meetingID: UUID) async -> AudioAvailability {
        offline ? .offline : .downloadable(bytes: 1_840_000)
    }

    @MainActor
    func localAudio(for track: RecordingTrack, in meetingID: UUID, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if offline { throw AudioProvidingError.offline }
        let start = Date()
        while Date().timeIntervalSince(start) < 30 {
            try await Task.sleep(for: .milliseconds(200))
            progress(min(0.42, Date().timeIntervalSince(start) / 10))
        }
        progress(1)
        return try await base.localAudio(for: track, in: meetingID, progress: { _ in })
    }
}
#endif
