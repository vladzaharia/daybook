import DaybookCaptions
import DaybookCore
import DaybookKit
import DaybookLive
import DaybookModelStore
import Foundation

/// Live transcription on this Mac from local models (docs/capture.md, "Live captions";
/// docs/model-runtime.md, "Live"): when the live models are downloaded (Settings › Models, Live
/// transcription and Live speakers), recordings and a recorder's Listen Live are captioned by them,
/// with speakers named from the library's voice profiles; otherwise by the Speech framework, as
/// before. Either way captions stay tentative, and the transcript comes from the processing models.
///
/// Which models a capture gets is resolved ahead of time (`refresh`), because captioners are made
/// synchronously as a recording starts.
@MainActor
final class MacLiveModels {
    let captioners: LiveCaptioners
    /// The installed live models a capture would use now.
    private(set) var models = LiveModelSet()
    private var refreshing: Task<Void, Never>?

    /// Models stay loaded two minutes after the last capture, as the runtime's do, so back-to-back
    /// recordings don't reload them.
    static let idleRelease: Duration = .seconds(120)

    /// The voices live captions recognize: the library's named speakers (`LibraryVoices`).
    let voices = LibraryVoices()

    init(store: ModelStore) {
        captioners = LiveCaptioners(host: LiveModelHost(idleRelease: Self.idleRelease, store: store), policy: .mac,
                                    voices: voices, conditions: { .system() })
    }

    /// Re-reads which live models are chosen and installed. Call after downloads and removals, and
    /// when the choices or the captions' language change.
    func refresh(selections: ModelSelections, catalog: ModelCatalog, engines: [ModelEngineDescriptor], locale: Locale,
                 store: ModelStore) {
        refreshing?.cancel()
        let choices = Self.choices(selections: selections, catalog: catalog, engines: engines)
        let alternatives = LiveModelChoices.defaults(for: .liveTranscription, platform: .macOS, catalog: catalog, engines: engines)
        refreshing = Task { [weak self] in
            let inventory = await store.inventory()
            guard !Task.isCancelled else { return }
            self?.models = LiveModelSet.resolve(choices, inventory: inventory, locale: locale, alternatives: alternatives)
        }
        Task { await captioners.host.releaseIdle() }
    }

    /// Each live role's model on this Mac: the person's choice, else the catalog's default.
    static func choices(selections: ModelSelections, catalog: ModelCatalog, engines: [ModelEngineDescriptor]) -> [ModelRole: String] {
        var choices: [ModelRole: String] = [:]
        for role in ModelRole.live {
            choices[role] = LiveModelChoices.choice(for: role, selections: selections, platform: .macOS, catalog: catalog, engines: engines)
        }
        return choices
    }

    /// A capture's captioner: the live models' when they're installed, else `fallback` (the Speech
    /// framework's). Nil when neither can run.
    func captioner(locale: Locale, backlog: Int, timelineOrigin: TimeInterval?,
                   fallback: () -> (any LiveCaptioning)?) -> (any LiveCaptioning)? {
        captioners.captioner(models: models, locale: locale, backlog: backlog, timelineOrigin: timelineOrigin, fallback: fallback)
    }

}

/// The library's named speakers with voice profiles, read when a capture starts: what live captions
/// recognize until voice profiles sync on their own (the `KnownVoiceSource` seam).
@MainActor
final class LibraryVoices: KnownVoiceSource {
    var meetings: () -> [Meeting] = { [] }

    nonisolated func knownVoices(in space: String) async -> [KnownVoice] {
        let current = await MainActor.run { self.meetings() }
        return KnownVoices.fromLibrary(current, space: space)
    }
}
