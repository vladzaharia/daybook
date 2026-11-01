import DaybookKit
import SwiftUI
import UIKit

@main
struct DaybookPhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var delegate
    @State private var model: PhoneAppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let options = LaunchOptions()
        // Exports a share sheet never finished with (the app quit first).
        ExportFiles.clear()
        // Synthetic audio in tests and simulator demos, so nothing ever opens a real microphone there.
        let environment: PhoneRecorderEnvironment = options.syntheticAudio || options.isRunningTests ? .synthetic() : .live()
        let root = options.libraryPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? (options.isRunningTests ? FileManager.default.temporaryDirectory.appendingPathComponent("DaybookTestHost", isDirectory: true)
                                       : LibraryLocation.defaultRoot)
        let settings = PhoneSettings(defaults: LaunchOptions.isTestHost
            ? UserDefaults(suiteName: "DaybookTestHost") ?? .standard : .standard)
        // The phone is an on-demand replica: conversations arrive at once, audio when it's played.
        let sync = LibrarySyncController(localRoot: root, defaults: .standard)
        sync.replica = PhoneSync.replica(displayName: ProcessingRequest.Device.currentName, budget: settings.audioCacheBudget)
        // An encrypted library's key, from iCloud Keychain (never in tests).
        if !options.isRunningTests, !LaunchOptions.isTestHost { sync.replica.keyStore = KeychainLibraryKeyStore.system }
        // Sealing an encrypted library's history downloads recordings only on Wi‑Fi, unless the person allows cellular
        // (never limited in tests).
        if !options.isRunningTests, !LaunchOptions.isTestHost {
            sync.replica.network = {
                NetworkConditionMonitor.shared.condition.allowing(cellular: UserDefaults.standard.bool(forKey: PhoneSettings.Keys.encryptsOverCellular))
            }
        }
        // The courier sends what each pass writes to the Mac through CloudKit, ahead of iCloud Drive
        // (docs/icloud-sync.md, "Courier (CloudKit)"). Never in tests or with a debug sync folder.
        if !options.isRunningTests, !LaunchOptions.isTestHost, options.syncFolder == nil {
            sync.courier = CloudKitCourier.ifEntitled(containerIdentifier: sync.environment.containerIdentifier,
                                                      directory: root.appendingPathComponent("Sync/Courier", isDirectory: true),
                                                      deviceID: sync.deviceID)
            sync.courierRole = .send
            // CKSyncEngine's subscription delivers through push, which needs the app registered for it.
            sync.onCourierAvailable = { UIApplication.shared.registerForRemoteNotifications() }
        }
        // Storage errors surface when loading, and retry the same durable location.
        let library = PhoneLibrary(rootURL: root, sync: sync)
        BackupExclusion.apply(libraryRoot: root, inbox: library.inboxURL, library: BackupExclusion.library(
            includesLibrary: settings.includesLibraryInBackups, encrypted: LibrarySyncEngine.hasSyncedEncryptedLibrary(localRoot: root),
            includesEncryptedLibrary: settings.includesEncryptedLibraryInBackups))
        let model = PhoneAppModel(recorder: PhoneRecorder(environment: environment), library: library,
                                  posture: DevicePosture(arguments: CommandLine.arguments), options: options, settings: settings)
        model.demoAudioSession = environment.session as? ScriptedAudioSession
        // Back on Wi‑Fi, sealing that waited for it carries on.
        if !options.isRunningTests, !LaunchOptions.isTestHost {
            NetworkConditionMonitor.shared.onChange { condition in
                guard condition == .unrestricted else { return }
                Task { @MainActor in
                    guard case .on(let summary) = model.sync.encryption, summary.progress?.waitsForWiFi == true else { return }
                    await model.sync.synchronize(.manual)
                }
            }
        }
        // Nothing records in a new process yet: a widget state or Live Activity saying so is left from
        // a run that ended, also when iOS relaunches the app in the background (which skips `launch`).
        if !options.isRunningTests, !LaunchOptions.isTestHost { RecordingActivityController.clearLeftoversAtLaunch() }
        // Intents run in this process (Live Activity buttons, the control, Siri, the Action button);
        // register before any scene exists, because an intent can launch the app in the background.
        RecordingCommands.handler = model
        // CoreBluetooth state restoration needs the central manager back before launch finishes, so
        // recorders start here rather than when the first view appears.
        if !options.isRunningTests { model.devices.start() }
        _model = State(initialValue: model)
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { model.prepareForTermination() }
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if model.options.isRunningTests {
                    Color.clear
                } else {
                    RootView()
                }
            }
            .environment(model)
            .environment(model.posture)
            .environment(\.audioProvider, model.audio)
            .environment(\.summaryPlacement, model.placement)
            .environment(\.upgrades, model.upgrades)
            .task { await model.launch() }
            // Files shared to Daybook (Voice Memos, call recordings saved from Notes, Files' Share).
            .onOpenURL { url in
                guard url.isFileURL else { return }
                Task { await model.importFiles([url]) }
            }
        }
        .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(phase) }
        .backgroundTask(.appRefresh(PhoneSync.refreshIdentifier)) {
            // Recorders first: their timers didn't run while the app was suspended.
            await model.devices.backgroundRefresh()
            await model.sync.backgroundRefresh()
        }
    }
}
