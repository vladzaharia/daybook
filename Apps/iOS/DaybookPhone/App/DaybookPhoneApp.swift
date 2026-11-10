import DaybookKit
import SwiftUI
import UIKit

@main
struct DaybookPhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var delegate
    @State private var model: PhoneAppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let options = DebugLaunch()
        // Hosting unit tests, the app reaches nothing real: the tests build their own models.
        let hostsTests = options.isRunningTests
        let environment: PhoneAppEnvironment = hostsTests ? .inert : .live(options)
        // Exports a share sheet never finished with (the app quit first).
        ExportFiles.clear()
        // Synthetic audio in tests and simulator demos, so nothing ever opens a real microphone there.
        let recorderEnvironment: PhoneRecorderEnvironment = options.syntheticAudio || hostsTests ? .synthetic() : .live()
        let root = options.libraryPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? (hostsTests ? InertScratch.folder("Library") : LibraryLocation.defaultRoot)
        let settings = PhoneSettings(defaults: environment.defaults)
        // The phone is an on-demand replica: conversations arrive at once, audio when it's played.
        let sync = LibrarySyncController(localRoot: root, defaults: hostsTests ? environment.defaults : .standard)
        sync.replica = PhoneSync.replica(displayName: ProcessingRequest.Device.currentName, budget: settings.audioCacheBudget)
        if !hostsTests {
            // An encrypted library's key, from iCloud Keychain.
            sync.replica.keyStore = KeychainLibraryKeyStore.system
            // Sealing an encrypted library's history downloads recordings only on Wi‑Fi, unless the person allows cellular.
            sync.replica.network = { [weak settings] in
                NetworkListeners.shared.condition.allowing(cellular: settings?.encryptsOverCellularNow ?? false)
            }
        }
        // The courier sends what each pass writes to the Mac through CloudKit, ahead of iCloud Drive
        // (docs/icloud-sync.md, "Courier (CloudKit)"). Never in tests or with a debug sync folder.
        if !hostsTests, options.syncFolder == nil {
            sync.courier = CloudKitCourier.ifEntitled(containerIdentifier: sync.environment.containerIdentifier,
                                                      directory: root.appendingPathComponent("Sync/Courier", isDirectory: true),
                                                      deviceID: sync.deviceID)
            sync.courierRole = .send
            // CKSyncEngine's subscription delivers through push, which needs the app registered for it.
            sync.onCourierAvailable = { UIApplication.shared.registerForRemoteNotifications() }
        }
        // Storage errors surface when loading, and retry the same durable location.
        let library = PhoneLibrary(rootURL: root, sync: sync)
        BackupExclusion.apply(to: library, BackupExclusion.library(
            includesLibrary: settings.includesLibraryInBackups, encrypted: LibrarySyncEngine.hasSyncedEncryptedLibrary(localRoot: root),
            includesEncryptedLibrary: settings.includesEncryptedLibraryInBackups))
        let model = PhoneAppModel(recorder: PhoneRecorder(environment: recorderEnvironment), library: library,
                                  posture: DevicePosture(arguments: CommandLine.arguments), options: options,
                                  environment: environment, settings: settings)
        model.demoAudioSession = recorderEnvironment.session as? ScriptedAudioSession
        if !hostsTests {
            // Back on Wi‑Fi, sealing that waited for it carries on.
            NetworkListeners.shared.add { condition in
                guard condition == .unrestricted else { return }
                Task { @MainActor in
                    guard case .on(let summary) = model.sync.encryption, summary.progress?.waitsForWiFi == true else { return }
                    await model.sync.synchronize(.manual)
                }
            }
            // Nothing records in a new process yet: a widget state or Live Activity saying so is left from
            // a run that ended, also when iOS relaunches the app in the background (which skips `launch`).
            RecordingActivityController.clearLeftoversAtLaunch()
        }
        // Intents run in this process (Live Activity buttons, the control, Siri, the Action button);
        // register before any scene exists, because an intent can launch the app in the background.
        RecordingCommands.handler = model
        // Notifications, Open Conversation, and New Note open Daybook through the model.
        AppDestinations.model = model
        // CoreBluetooth state restoration needs the central manager back before launch finishes, so
        // recorders start here rather than when the first view appears.
        if !hostsTests { model.devices.start() }
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
            .environment(\.debugLaunch, model.options)
            .environment(\.audioProvider, model.audio)
            .environment(\.summaryPlacement, model.placement)
            .environment(\.upgrades, model.upgrades)
            .task { await model.launch() }
            // Files shared to Daybook (Voice Memos, call recordings saved from Notes, Files' Share),
            // or a widget opening the library, a conversation, or a new note.
            .onOpenURL { url in
                if url.isFileURL {
                    Task { await model.importFiles([url]) }
                } else if let destination = AppDestination(widgetURL: url) {
                    AppDestinations.open(destination)
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(phase) }
        .backgroundTask(.appRefresh(PhoneSync.refreshIdentifier)) {
            // Recorders first: their timers didn't run while the app was suspended.
            await model.devices.backgroundRefresh()
            await model.sync.backgroundRefresh()
            // The next meetings' reminders, for whoever hasn't opened Daybook in a while.
            await model.remindMeetings()
        }
    }
}
