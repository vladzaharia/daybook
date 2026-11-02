import DaybookDesign
import DaybookKit
import SwiftUI

/// What iCloud Sync's controls do. Each app fills them from its sync controller; a nil one leaves its control out.
public struct ICloudSyncActions {
    /// Sync Now: another pass after any running one.
    public var syncNow: @MainActor () -> Void
    /// Try Again, where iCloud couldn't be reached or the previous sync folder couldn't be found.
    public var tryAgain: @MainActor () -> Void
    /// Sync with This Account, once the person has confirmed it (`LibrarySyncController.useCurrentICloudAccount`).
    public var useCurrentAccount: @MainActor () -> Void
    /// Get Key from a device that holds the library's key.
    public var requestKey: @MainActor (UUID) -> Void
    /// Where the person signs in or turns iCloud Drive on: the Mac's System Settings, the iPhone's Settings.
    public var openSettings: (@MainActor () -> Void)?
    /// Where iCloud storage is managed, when it's full (the Mac's Apple Account settings).
    public var manageStorage: (@MainActor () -> Void)?
    /// Starts a new library in iCloud, for one that was removed there.
    public var startNewLibrary: (@MainActor () async throws -> Void)?
    /// Turns sync back on (the Mac's).
    public var turnOn: (@MainActor () -> Void)?
    /// Turns sync off on this device, once the person has confirmed it (the Mac's).
    public var turnOff: (@MainActor () -> Void)?
    /// The folder this Mac synced through before: choose it again, or sync without it (once confirmed).
    public var choosePreviousFolderAgain: (@MainActor (URL?) -> Void)?
    public var continueWithoutPreviousFolder: (@MainActor () -> Void)?
    /// Deletes the copy of the previous sync folder's journal kept after a move to iCloud.
    public var deleteRetiredFolderJournal: (@MainActor () throws -> Void)?

    public init(syncNow: @escaping @MainActor () -> Void, tryAgain: @escaping @MainActor () -> Void,
                useCurrentAccount: @escaping @MainActor () -> Void, requestKey: @escaping @MainActor (UUID) -> Void,
                openSettings: (@MainActor () -> Void)? = nil, manageStorage: (@MainActor () -> Void)? = nil,
                startNewLibrary: (@MainActor () async throws -> Void)? = nil, turnOn: (@MainActor () -> Void)? = nil,
                turnOff: (@MainActor () -> Void)? = nil, choosePreviousFolderAgain: (@MainActor (URL?) -> Void)? = nil,
                continueWithoutPreviousFolder: (@MainActor () -> Void)? = nil,
                deleteRetiredFolderJournal: (@MainActor () throws -> Void)? = nil) {
        self.syncNow = syncNow
        self.tryAgain = tryAgain
        self.useCurrentAccount = useCurrentAccount
        self.requestKey = requestKey
        self.openSettings = openSettings
        self.manageStorage = manageStorage
        self.startNewLibrary = startNewLibrary
        self.turnOn = turnOn
        self.turnOff = turnOff
        self.choosePreviousFolderAgain = choosePreviousFolderAgain
        self.continueWithoutPreviousFolder = continueWithoutPreviousFolder
        self.deleteRetiredFolderJournal = deleteRetiredFolderJournal
    }
}

/// Settings' iCloud Sync, the same on both apps (docs/interface.md, "Settings"): one row saying where sync stands with
/// its one action ("Up to date · 11:42 AM", Sync Now); a problem in place with its fix (ProblemLine); the library's
/// devices; encryption; and the app's own rows (`extras`: the Mac's Transcribe synced recordings). Erasing deleted
/// conversations and turning sync off sit under the group: as System Settings places such buttons on the Mac, in a
/// group of their own on the iPhone.
///
/// The Mac shows it as a section of Settings › Library, headed "iCloud Sync"; the iPhone as Settings › iCloud.
public struct ICloudSyncSection<DevicesRow: View, Extras: View>: View {
    private let shown: ICloudSyncShown
    private let actions: ICloudSyncActions
    private let controller: LibrarySyncController?
    @Binding private var sheet: ICloudSyncSheet?
    private let cellular: Binding<Bool>?
    private let devicesRow: DevicesRow
    private let extras: Extras
    @State private var confirming: ICloudSyncConfirmation?
    /// Something asked for here that couldn't be done.
    @State private var problem: SyncSettingsProblem?
    @Environment(\.daybookDensity) private var density

    /// - Parameters:
    ///   - sheet: The sheet open, which the app presents (`ICloudSyncSheetContent`).
    ///   - cellular: Use Cellular Data while this device encrypts the library's history (the iPhone's).
    ///   - devicesRow: The app's way to the library's devices around `LibraryDevicesRowLabel`.
    ///   - extras: The app's own rows, after the rest, in whatever state sync is.
    public init(shown: ICloudSyncShown, actions: ICloudSyncActions, controller: LibrarySyncController?, sheet: Binding<ICloudSyncSheet?>,
                cellular: Binding<Bool>? = nil, @ViewBuilder devicesRow: () -> DevicesRow, @ViewBuilder extras: () -> Extras) {
        self.shown = shown
        self.actions = actions
        self.controller = controller
        _sheet = sheet
        self.cellular = cellular
        self.devicesRow = devicesRow()
        self.extras = extras()
    }

    private var touch: Bool { density == .touch }

    public var body: some View {
        Section {
            if shown.isFolderTransport, shown.folder != nil {
                folderRows
            } else {
                statusRow
                stateRows
            }
            extras
            if let problem { ProblemLine(text: problem.message, details: problem.details) }
        } header: {
            if !touch { Text("iCloud Sync") }
        } footer: {
            footer
        }
        .iCloudSyncConfirmation($confirming) { confirmed($0) }
        if touch, showsGroupActions {
            // The iPhone's "under the group": the destructive action in a group of its own, at the end.
            Section {
                Button(ICloudSyncConfirmation.erase.action + "…", role: .destructive) { confirming = .erase }
                    .disabled(shown.isSyncing)
            }
        }
    }

    // MARK: The status row

    /// One row: where sync stands, and the one action that moves it on. The iPhone draws the row as its list does, with
    /// the symbol on a tile and the actions as rows under it.
    @ViewBuilder private var statusRow: some View {
        if touch {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                HStack(spacing: SettingsMetrics.gap) {
                    SettingsTile(systemImage: shown.symbol, tone: shown.needsAttention ? .attention : .neutral)
                    Text(shown.headline(now: context.date).keepingSeparators)
                        .foregroundStyle(DaybookPalette.Ink.title)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if shown.isBusy { ProgressView() }
                }
                .padding(.vertical, 1)
                .accessibilityElement(children: .combine)
            }
            ForEach(Array(primaryActions.enumerated()), id: \.offset) { _, action in
                Button(action: action.perform) { SettingsActionLabel(title: action.title, systemImage: action.symbol) }
                    .disabled(!action.isEnabled)
            }
        } else {
            LabeledContent("iCloud") {
                HStack(spacing: DaybookSpacing.s3) {
                    if shown.isBusy { ProgressView().controlSize(.small) }
                    Text(shown.headline()).foregroundStyle(.secondary).monospacedDigit()
                    if case .containerUnavailable(let reason) = shown.iCloud, !reason.isEmpty { DetailsButton(details: reason) }
                    ForEach(Array(primaryActions.enumerated()), id: \.offset) { _, action in
                        Button(action.title, action: action.perform).disabled(!action.isEnabled)
                    }
                }
            }
        }
    }

    private struct RowAction {
        var title: String
        var symbol: String
        var isEnabled = true
        var perform: @MainActor () -> Void
    }

    /// The status row's action: what moves sync on from where it stands.
    private var primaryActions: [RowAction] {
        switch shown.iCloud {
        case .connected, .waitingForKey:
            guard shown.folder != nil else { return [] }
            return [RowAction(title: "Sync Now", symbol: "arrow.triangle.2.circlepath", isEnabled: !shown.isSyncing, perform: actions.syncNow)]
        case .iCloudDriveOff, .signedOut:
            var list: [RowAction] = []
            if let open = actions.openSettings {
                #if os(macOS)
                list.append(RowAction(title: "Open System Settings…", symbol: "gearshape", perform: open))
                #else
                list.append(RowAction(title: "Open Settings", symbol: "gearshape", perform: open))
                #endif
            }
            // The iPhone checks again once the person is back from Settings; the Mac follows the account itself.
            if touch { list.append(RowAction(title: "Try Again", symbol: "arrow.clockwise", perform: actions.tryAgain)) }
            return list
        case .turnedOff:
            return actions.turnOn.map { [RowAction(title: "Turn On", symbol: "icloud", perform: $0)] } ?? []
        case .containerUnavailable:
            return [RowAction(title: "Try Again", symbol: "arrow.clockwise", perform: actions.tryAgain)]
        default:
            return []
        }
    }

    // MARK: Each state's rows

    @ViewBuilder private var stateRows: some View {
        switch shown.iCloud {
        case .migrating(let progress):
            if progress.total > 0 {
                ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                    .progressViewStyle(.brand(width: nil))
                    .accessibilityLabel("Moving your library to iCloud")
            }
            // A move that stopped on an error says so in place; it tries again on its own.
            if let problem = shown.problem { ProblemLine(text: problem.text, details: problem.details) }
        case .connected, .waitingForKey:
            attachedRows
        case .accountChanged:
            ProblemLine(text: SyncProblem.accountChanged.text) {
                Button(ICloudSyncConfirmation.useAccount.action + "…") { confirming = .useAccount }
            }
        case .previousFolderAccessLost(let location):
            ProblemLine(text: SyncProblem.previousFolderAccessLost.text) {
                if let choose = actions.choosePreviousFolderAgain { Button("Choose Folder Again…") { choose(location) } }
                if actions.continueWithoutPreviousFolder != nil { Button(ICloudSyncConfirmation.skipFolder.action + "…") { confirming = .skipFolder } }
            }
        case .previousFolderMissing:
            ProblemLine(text: SyncProblem.previousFolderMissing.text) {
                Button("Try Again", action: actions.tryAgain)
                if actions.continueWithoutPreviousFolder != nil { Button(ICloudSyncConfirmation.skipFolder.action + "…") { confirming = .skipFolder } }
            }
        default:
            EmptyView()
        }
    }

    /// Attached to the library: a paused or failed pass and the warnings, in place, with their fixes; encryption (with
    /// how to get the library's key while waiting for it); and the library's devices.
    @ViewBuilder private var attachedRows: some View {
        if let problem = shown.problem { problemLine(problem) }
        if shown.otherInstallation { ProblemLine(text: ICloudSyncShown.otherInstallationLine) }
        if let remaining = shown.remainingMigration { Text(remaining).foregroundStyle(DaybookPalette.Ink.secondary) }
        ForEach(Array(shown.warnings.enumerated()), id: \.offset) { _, warning in
            let words = SyncWarningWords.split(warning)
            ProblemLine(text: words.text, details: words.details)
        }
        // A library removed from iCloud has nothing to encrypt: the new one starts encrypted.
        if !shown.isLibraryRemoved { encryptionRows }
        if shown.folder != nil { devicesRow }
    }

    /// A pass's problem with its one fix: Manage Storage… when iCloud is full (or, where nothing here opens iCloud's
    /// storage, where to free some), Start a New Library in iCloud when the library there was removed.
    @ViewBuilder private func problemLine(_ problem: SyncProblem) -> some View {
        switch problem {
        case .storageFull:
            if let manageStorage = actions.manageStorage {
                ProblemLine(text: problem.text, details: problem.details) {
                    Button("Manage Storage…") { manageStorage() }
                }
            } else {
                ProblemLine(text: ICloudSyncShown.problemText(problem, managesStorage: false), details: problem.details)
            }
        case .libraryRemoved where shown.offersNewLibrary(canStart: actions.startNewLibrary != nil):
            ProblemLine(text: problem.text, details: problem.details) {
                Button(ICloudSyncShown.startNewLibraryTitle) { startNewLibrary() }
                    .disabled(shown.isSyncing)
            }
        default:
            ProblemLine(text: problem.text, details: problem.details)
        }
    }

    // MARK: Encryption

    @ViewBuilder private var encryptionRows: some View {
        switch shown.encryption {
        case .unavailable:
            EmptyView()
        case .off:
            LabeledContent(SyncSettingsCase.label("Encryption", density)) {
                HStack(spacing: DaybookSpacing.s3) {
                    Text("Off").foregroundStyle(.secondary)
                    Button("Turn On…") { sheet = .encrypt }
                        .disabled(shown.isSyncing || shown.folder == nil)
                        #if os(iOS)
                        .buttonStyle(.daybookLink)
                        #endif
                }
            }
        case .waitingForKey:
            ProblemLine(text: ICloudSyncShown.waitingForKeyLine, symbol: "lock.icloud.fill") {
                ForEach(shown.keyPeers) { peer in
                    Button("Get Key from \(peer.name)") { actions.requestKey(peer.id) }
                }
                Button("Enter Recovery Key…") { sheet = .enterRecoveryKey }
                if shown.mayStartOverEncryption {
                    Button(ICloudSyncConfirmation.startOver.action + "…") { confirming = .startOver }
                }
            }
        case .on(let status, let hasRecoveryKey, let encryptsHere):
            LabeledContent(SyncSettingsCase.label("Encryption", density)) {
                Text(status).foregroundStyle(.secondary).monospacedDigit()
            }
            // While this device encrypts the history it downloads recordings on Wi‑Fi unless cellular is allowed.
            if encryptsHere, let cellular {
                Toggle(SyncSettingsCase.label("Use cellular data", density), isOn: cellular)
            }
            LabeledContent(SyncSettingsCase.label("Recovery key", density)) {
                if hasRecoveryKey {
                    Text("Saved").foregroundStyle(.secondary)
                } else {
                    Button("Create Recovery Key…") { createRecoveryKey() }
                        #if os(iOS)
                        .buttonStyle(.daybookLink)
                        #endif
                }
            }
            if shown.hasRetiredFolderJournal, actions.deleteRetiredFolderJournal != nil {
                LabeledContent(SyncSettingsCase.label("Previous sync folder", density)) {
                    Button(ICloudSyncConfirmation.deleteFolderCopy.action + "…") { confirming = .deleteFolderCopy }
                }
            }
        }
    }

    // MARK: Under the group

    /// Erasing (with an encrypted library) and turning sync off, while attached; nothing to erase in a library that
    /// was removed.
    private var showsGroupActions: Bool { shown.isConnected && shown.encryption.isOn && !shown.isLibraryRemoved }

    @ViewBuilder private var footer: some View {
        if let footer = shown.footer {
            SettingsFooter(footer)
        } else if !touch, shown.isConnected, showsGroupActions || actions.turnOff != nil {
            HStack(spacing: DaybookSpacing.s2) {
                Spacer()
                if showsGroupActions {
                    Button(ICloudSyncConfirmation.erase.action + "…") { confirming = .erase }
                        .disabled(shown.isSyncing)
                }
                if actions.turnOff != nil {
                    Button(ICloudSyncConfirmation.turnOff.action + "…") { confirming = .turnOff }
                        .disabled(shown.isSyncing)
                }
            }
            .padding(.top, DaybookSpacing.s1)
        }
    }

    // MARK: Development folder

    /// The folder transport, for development builds without iCloud (and libraries connected in tests).
    @ViewBuilder private var folderRows: some View {
        if let folder = shown.folder {
            LabeledContent("Folder") {
                Text((folder.path as NSString).abbreviatingWithTildeInPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(folder.path)
            }
            LabeledContent("Status") {
                HStack(spacing: DaybookSpacing.s3) {
                    if shown.isSyncing { ProgressView().controlSize(.small) }
                    Text(shown.headline()).foregroundStyle(.secondary).monospacedDigit()
                    Button("Sync Now", action: actions.syncNow).disabled(shown.isSyncing)
                }
            }
            attachedRows
        }
    }

    // MARK: Acting

    private func createRecoveryKey() {
        guard let controller else { return }
        problem = nil
        Task {
            do { sheet = .recoveryKey(try await controller.createRecoveryKey()) } catch {
                problem = SyncSettingsProblem(error: error, fallback: "A recovery key couldn’t be created. Try again.")
            }
        }
    }

    private func startNewLibrary() {
        guard let start = actions.startNewLibrary else { return }
        problem = nil
        Task {
            do { try await start() } catch {
                problem = SyncSettingsProblem(error: error, fallback: "A new library couldn’t be started in iCloud. Try again.")
            }
        }
    }

    private func confirmed(_ confirmation: ICloudSyncConfirmation) {
        switch confirmation {
        case .turnOff: actions.turnOff?()
        case .useAccount: actions.useCurrentAccount()
        case .skipFolder: actions.continueWithoutPreviousFolder?()
        case .erase:
            problem = nil
            Task {
                do { try await controller?.rotateEncryptionKey() } catch {
                    problem = SyncSettingsProblem(error: error, fallback: "Deleted conversations couldn’t be erased from iCloud. Try again once sync is up to date.")
                }
            }
        case .startOver:
            problem = nil
            Task {
                do { try await controller?.startOverEncryption() } catch {
                    problem = SyncSettingsProblem(error: error, fallback: "The library couldn’t start over. Try again.")
                }
            }
        case .deleteFolderCopy:
            problem = nil
            do { try actions.deleteRetiredFolderJournal?() } catch {
                problem = SyncSettingsProblem(error: error, fallback: "The previous sync folder’s copy couldn’t be deleted. Try again.")
            }
        }
    }
}

/// What iCloud Sync asks before it acts: the question, what follows, and the button that does it.
enum ICloudSyncConfirmation: String, Identifiable, CaseIterable {
    case turnOff, useAccount, skipFolder, erase, startOver, deleteFolderCopy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .turnOff: return "Stop syncing this \(ICloudSyncShown.device)?"
        case .useAccount: return "Sync with this iCloud account?"
        case .skipFolder: return "Sync without the previous folder?"
        case .erase: return "Erase deleted conversations from iCloud?"
        case .startOver: return "Start over with a new key?"
        case .deleteFolderCopy: return "Delete the previous sync folder’s copy?"
        }
    }

    var message: String {
        switch self {
        case .turnOff: return "Your library stays on this \(ICloudSyncShown.device) and in iCloud. Nothing is deleted."
        case .useAccount: return "Its conversations are added to the iCloud account you’re signed in to."
        case .skipFolder:
            return "Everything in this Mac’s library still syncs. History and deleted conversations kept only in that folder stay there."
        case .erase, .deleteFolderCopy: return "This can’t be undone."
        case .startOver: return LibraryWords.startOverConsequence
        }
    }

    /// The button that does it; with "…" where it opens the question.
    var action: String {
        switch self {
        case .turnOff: return "Turn Off Sync"
        case .useAccount: return "Sync with This Account"
        case .skipFolder: return "Sync Without It"
        case .erase: return "Erase Deleted Conversations from iCloud"
        case .startOver: return "Start Over"
        case .deleteFolderCopy: return "Delete Its Copy"
        }
    }

    /// The question's own button.
    var confirm: String {
        switch self {
        case .turnOff: return "Turn Off"
        case .useAccount: return "Sync"
        case .skipFolder: return "Sync Without It"
        case .erase: return "Erase"
        case .startOver: return "Start Over"
        case .deleteFolderCopy: return "Delete"
        }
    }

    var isDestructive: Bool { [.turnOff, .erase, .startOver, .deleteFolderCopy].contains(self) }
}

extension View {
    /// Asks before an iCloud Sync action: an alert on the Mac, a confirmation dialog on the iPhone.
    fileprivate func iCloudSyncConfirmation(_ item: Binding<ICloudSyncConfirmation?>,
                                            perform: @escaping (ICloudSyncConfirmation) -> Void) -> some View {
        let shown = Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
        let presenting = item.wrappedValue
        #if os(macOS)
        return alert(presenting?.title ?? "", isPresented: shown, presenting: presenting) { value in
            Button(value.confirm, role: value.isDestructive ? .destructive : nil) { perform(value) }
            Button("Cancel", role: .cancel) {}
        } message: { value in
            Text(value.message)
        }
        #else
        return confirmationDialog(presenting?.title ?? "", isPresented: shown, titleVisibility: .visible, presenting: presenting) { value in
            Button(value.confirm, role: value.isDestructive ? .destructive : nil) { perform(value) }
        } message: { value in
            Text(value.message)
        }
        #endif
    }
}
