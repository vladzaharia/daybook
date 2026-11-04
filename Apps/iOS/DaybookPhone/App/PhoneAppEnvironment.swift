import DaybookKit
import DaybookLink
import DaybookModelStore
import Foundation
import UserNotifications

/// What the app model reaches in the system: the keychain, this iPhone's preferences, the models' folder
/// and downloads, the network, recorders over Bluetooth, notifications, the system's background work, and
/// Spotlight. Injected, as `PhoneRecorderEnvironment` is for the microphone, so nothing a test or a test
/// host builds ever touches the real ones:
///
/// - `.live(_:)`: the app, built once by `DaybookPhoneApp`.
/// - `.inert`: a test host's own launch, and any model a test builds without saying (every service
///   inert, preferences in a scratch suite this process removes, models in its scratch folder).
/// - `.test(…)` (DaybookPhoneTests' TestSupport): the same, scoped to one test and removed after it.
@MainActor
struct PhoneAppEnvironment {
    /// This iPhone's own preferences: `PhoneSettings`, the models', the recorders', and Settings › Cloud's.
    var defaults: UserDefaults
    /// Where pairing keys are kept.
    var linkKeys: () -> any LinkKeyStore
    /// Where cloud summaries' keys are kept.
    var cloudKeys: () -> any CloudKeyStore
    /// The models' folder.
    var modelRoot: () -> URL
    /// How models download.
    var modelFetcher: () -> any ModelArtifactFetcher
    /// Whether this iPhone is on Wi‑Fi, for downloads that wait for it.
    var network: PhoneNetwork
    /// How recorders connect (the debug `--device-simulator` puts the simulated recorder in place of Bluetooth).
    var deviceMode: PhoneDevices.Mode
    /// The notifications Daybook posts.
    var notices: PhoneNotices
    /// This iPhone's calendars, for Use Calendar.
    var calendar: any MeetingCalendarReading
    /// The system's continued-processing task for transcribing in the background; nil runs without it.
    var continuedProcessing: () -> (any ContinuedProcessing.Scheduler)?
    /// Recordings and Listen Live may load a live captioner. Tests inject their own instead.
    var makesCaptioners: Bool
    /// The link to Macs starts at launch.
    var startsLink: Bool
    /// What Spotlight lists of the library (`ConversationIndex`).
    var spotlight: ConversationIndex.Indexer

    /// The app's: the keychain, `UserDefaults.standard`, Application Support's models with background
    /// downloads, the shared Wi‑Fi monitor, Bluetooth (or the simulated recorder), notifications, and Spotlight.
    static func live(_ options: DebugLaunch) -> PhoneAppEnvironment {
        PhoneAppEnvironment(
            defaults: .standard,
            linkKeys: { KeychainLinkKeyStore() },
            cloudKeys: { KeychainCloudKeyStore.system },
            modelRoot: { PhoneModels.defaultRoot },
            modelFetcher: { PhoneModels.downloads },
            network: .shared,
            deviceMode: options.deviceSimulator ? .simulator : .live,
            notices: .app,
            calendar: EventKitMeetingCalendar(),
            continuedProcessing: { SystemContinuedProcessingScheduler() },
            makesCaptioners: true,
            startsLink: true,
            spotlight: .system)
    }

    /// Nothing real: memory key stores, a scratch suite and models folder for this process, no downloads, no
    /// recorders, no notifications, no calendars, no Spotlight, no link at launch.
    static var inert: PhoneAppEnvironment {
        PhoneAppEnvironment(
            defaults: InertScratch.defaults,
            linkKeys: { MemoryLinkKeyStore() },
            cloudKeys: { MemoryCloudKeyStore() },
            modelRoot: { InertScratch.folder("Models-\(UUID().uuidString)") },
            // Never asked to download: tests don't, and nothing reaches the system's background sessions.
            modelFetcher: { HubSnapshotFetcher() },
            network: .unrestricted,
            deviceMode: .inert,
            notices: .silent,
            calendar: NoMeetingCalendar(),
            continuedProcessing: { nil },
            makesCaptioners: false,
            startsLink: false,
            spotlight: .none)
    }
}

/// The scratch space of `.inert`: one folder per process under the temporary directory, holding its
/// preferences and models. Whatever an earlier run left there goes when the first one is made, and the
/// tests remove this process's when they finish (TestSupport).
enum InertScratch {
    /// Every process's scratch folder.
    nonisolated static let root = FileManager.default.temporaryDirectory.appendingPathComponent("Daybook Test Host", isDirectory: true)

    /// This process's.
    nonisolated static let folder: URL = {
        let fileManager = FileManager.default
        let mine = root.appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        for earlier in (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where earlier != mine {
            try? fileManager.removeItem(at: earlier)
        }
        try? fileManager.createDirectory(at: mine, withIntermediateDirectories: true)
        return mine
    }()

    /// A folder inside this process's.
    nonisolated static func folder(_ name: String) -> URL {
        let url = folder.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// One preferences suite for the process, as a file in its folder rather than among the app's preferences.
    nonisolated(unsafe) static let defaults: UserDefaults = {
        let path = folder.appendingPathComponent("Preferences").path
        return UserDefaults(suiteName: path) ?? .standard
    }()

    /// Removes this process's folder (its preferences file with it).
    nonisolated static func removeAll() {
        try? FileManager.default.removeItem(at: folder)
    }
}

extension PhoneNetwork {
    /// The app's one Wi‑Fi monitor (`NetworkConditionMonitor.shared`), which sync's sealing hears too.
    static var shared: PhoneNetwork {
        let network = NetworkListeners.shared
        return PhoneNetwork(condition: { network.condition }, onChange: { handler in network.add { _ in handler() } })
    }

    /// Always on Wi‑Fi, and never changing: for tests and the test host.
    static let unrestricted = PhoneNetwork(condition: { .unrestricted }, onChange: { _ in })
}

/// Everything on this iPhone that follows the network, heard from the one monitor: it calls a single
/// handler, so this one passes each change to all of them (the models' downloads, sync's sealing).
final class NetworkListeners: @unchecked Sendable {
    static let shared = NetworkListeners(monitor: .shared)

    private let monitor: NetworkConditionMonitor
    private let lock = NSLock()
    private var listeners: [@Sendable (SyncNetworkCondition) -> Void] = []

    init(monitor: NetworkConditionMonitor) {
        self.monitor = monitor
        monitor.onChange { [weak self] condition in self?.changed(condition) }
    }

    /// The condition now.
    var condition: SyncNetworkCondition { monitor.condition }

    /// Calls `listener` (on a background queue) at every change from now on.
    func add(_ listener: @escaping @Sendable (SyncNetworkCondition) -> Void) {
        lock.withLock { listeners.append(listener) }
    }

    private func changed(_ condition: SyncNetworkCondition) {
        for listener in lock.withLock({ listeners }) { listener(condition) }
    }
}
