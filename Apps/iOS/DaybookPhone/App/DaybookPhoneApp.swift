import DaybookIntelligence
import DaybookKit
import DaybookUI
import SwiftUI
import UIKit

@main
struct DaybookPhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var delegate
    @State private var model: PhoneAppModel
    /// The lock for Personal conversations (Settings › Require Face ID for Personal; `PersonalLock`).
    @State private var personalLock: PersonalLock
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let options = DebugLaunch()
        // Hosting unit tests, the app reaches nothing real: the tests build their own models.
        let hostsTests = options.isRunningTests
        let environment: PhoneAppEnvironment = hostsTests ? .inert : .live(options)
        // Exports a share sheet never finished with (the app quit first), and audio copies processing left when it crashed.
        ExportFiles.clear()
        ProcessingScratch.clear()
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
        // The lock reads this iPhone's preferences and finds conversations in the library; every reading session asks it,
        // so it's there before the first one is made.
        let personalLock = PersonalLock(defaults: environment.defaults, platform: .iPhone, authenticator: SystemPersonalLockAuthenticator())
        personalLock.lookup = { [weak controller = library.controller] id in controller?.meeting(id) }
        #if DEBUG
        if let demo = PersonalLockDemo.state() { PersonalLockDemo.apply(demo, to: personalLock, platform: .iPhone) }
        #endif
        ReadingSession.appLock = personalLock
        _personalLock = State(initialValue: personalLock)
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
            .environment(personalLock)
            .environment(model.posture)
            .environment(\.debugLaunch, model.options)
            .environment(\.audioProvider, model.audio)
            .environment(\.summaryPlacement, model.placement)
            .environment(\.upgrades, model.upgrades)
            .task { await model.launch() }
            // The Focus that's on now, in case it changed while Daybook wasn't running.
            .task {
                guard !model.options.isRunningTests, PersonalLockDemo.state() == nil else { return }
                await DaybookFocusFilter.catchUp(personalLock)
            }
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
        .onChange(of: scenePhase) { _, phase in
            // While the app isn't in front and Personal is unlocked, the app switcher's picture shows none of it.
            PersonalLockCoverWindow.show(PersonalLockCover.shows(personalLock, isActive: phase == .active))
            model.scenePhaseChanged(phase)
            // Unlocked lasts until the app leaves the screen.
            if phase == .background { personalLock.lock() }
        }
        .backgroundTask(.appRefresh(PhoneSync.refreshIdentifier)) {
            // Recorders first: their timers didn't run while the app was suspended.
            await model.devices.backgroundRefresh()
            await model.sync.backgroundRefresh()
            // The next meetings' reminders, for whoever hasn't opened Daybook in a while.
            await model.remindMeetings()
        }
    }
}

/// The cover over everything the app shows, sheets included, while it isn't in front and Personal is unlocked
/// (`PersonalLockCover`): a window of its own above the app's, so the app switcher's picture is paper and the mark.
@MainActor
enum PersonalLockCoverWindow {
    private static var window: UIWindow?

    static func show(_ shows: Bool) {
        guard shows else {
            window?.isHidden = true
            window = nil
            return
        }
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let cover = UIWindow(windowScene: scene)
        cover.windowLevel = .alert + 1
        cover.rootViewController = UIHostingController(rootView: PersonalLockCover())
        cover.isHidden = false
        window = cover
    }
}
