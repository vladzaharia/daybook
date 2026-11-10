import AVFAudio
import DaybookDesign
import DaybookKit
import DaybookUI
import SwiftUI
import UIKit

/// The iPhone's first run, over the whole screen: what Daybook is, the microphone, pairing with a Mac, this iPhone's
/// own models, and Record. The pages and their words are the Mac's Welcome window's (DaybookUI's `WelcomePager`,
/// `WelcomeWords`); every page can be left with Not Now or a swipe, and closing it from the last page finishes it.
struct PhoneWelcome: View {
    enum Page: Int, CaseIterable, Hashable {
        case intro, allow, pair, models, ready
    }

    @Environment(PhoneAppModel.self) private var model
    /// Welcome is done: the cover goes, and it doesn't come back.
    let finish: () -> Void
    @State private var page: Page = PhoneWelcome.initialPage
    @State private var microphone = PhoneWelcome.microphoneState()
    @State private var showingPairing = false
    /// The Models page's rows the person left checked; nil until they change one (`PhoneWelcomeOffer.initialChoice`).
    @State private var chosenModels: Set<PhoneWelcomeOffer.Part>?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        WelcomePager(pages: pages, selection: $page) { page in
            switch page {
            case .intro:
                WelcomeIntroPage(device: .iPhone, summaries: promisesSummaries) { go(from: .intro) }
            case .allow:
                PhoneWelcomeAllow(state: microphone, allow: allowMicrophone, openSettings: openSettings) { go(from: .allow) }
            case .pair:
                PhoneWelcomePair(paired: model.link.macs.first?.name, pair: { showingPairing = true }) { go(from: .pair) }
            case .models:
                PhoneWelcomeModels(models: model.models, freeBytes: PhoneWelcome.freeBytes(), chosen: $chosenModels,
                                   download: downloadModels) {
                    go(from: .models)
                }
            case .ready:
                PhoneWelcomeReady(message: readyMessage, record: record, finish: finish)
            }
        }
        .background(DaybookPalette.paper.ignoresSafeArea())
        .pairingSheet(isPresented: $showingPairing)
        // Back from Settings, the Allow page says what's allowed now.
        .onChange(of: scenePhase) { _, phase in if phase == .active { microphone = Self.microphoneState() } }
        .task { await model.models.refresh() }
    }

    /// The models page is offered only where this iPhone can transcribe its own recordings.
    private var pages: [Page] {
        Page.allCases.filter { $0 != .models || PhoneWelcomeModels.offered(model.models) }
    }

    private func go(from current: Page) {
        guard let index = pages.firstIndex(of: current), pages.indices.contains(index + 1) else { return finish() }
        page = pages[index + 1]
    }

    private var readyMessage: String {
        let models = model.models
        // What the transcript waits for: the models transcribing needs (the summary model lands after them).
        let statuses = PhoneModels.transcribingRoles.compactMap(models.choice(for:)).map { models.status(of: $0) }
        let arriving = statuses.contains { $0.isTransferring && $0 != .waitingForWiFi }
        // Asked for and waiting for Wi‑Fi: the transcript waits for it too, and the line says so.
        let waitsForWiFi = !arriving && statuses.contains(.waitingForWiFi)
        let mac = Self.macTranscribes(model.macPresence)
        return WelcomeWords.readyMessage(downloading: (arriving || waitsForWiFi) && model.settings.processesOnThisIPhone,
                                         canTranscribe: model.processingCapabilities.transcribes,
                                         transcribesElsewhere: mac, waitsForWiFi: waitsForWiFi,
                                         summarizesElsewhere: mac && !Self.summarizesHere(models, processesHere: model.settings.processesOnThisIPhone))
    }

    /// The intro promises a short summary only where one will be made: this iPhone could run a summary model, or a Mac
    /// known to this library makes them.
    private var promisesSummaries: Bool {
        model.models.summaryModel != nil || Self.macTranscribes(model.macPresence)
    }

    /// This iPhone summarizes its own recordings: its summary model is here or on its way, and processing here is on.
    static func summarizesHere(_ models: PhoneModels, processesHere: Bool) -> Bool {
        guard processesHere, let summary = models.summaryModel else { return false }
        let status = models.status(of: summary)
        return status.isReady || status.isTransferring
    }

    /// A Mac that transcribes this library is known: connected now, or by its last sync. Pairing alone doesn't say;
    /// a Mac transcribes this iPhone's recordings through the library it syncs.
    static func macTranscribes(_ presence: MacPresence) -> Bool {
        switch presence {
        case .connected, .seen: return true
        default: return false
        }
    }

    private func allowMicrophone() {
        Task { @MainActor in
            _ = await AVAudioApplication.requestRecordPermission()
            microphone = Self.microphoneState()
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    /// Downloads the rows left checked: what transcribing needs first, then the summary model, which waits its turn
    /// behind them (`PhoneModels.download`), so it never delays a transcript.
    private func downloadModels(_ parts: Set<PhoneWelcomeOffer.Part>) {
        model.settings.processesOnThisIPhone = true
        model.processingChanged()
        let models = model.models
        if parts.contains(.transcription) { for missing in models.processingMissing { models.download(missing) } }
        if parts.contains(.summaries), let summary = models.summaryModel, models.status(of: summary).canDownload { models.download(summary) }
        go(from: .models)
    }

    private func record() {
        finish()
        Task { try? await model.startRecording() }
    }

    static func microphoneState() -> WelcomePermissionState {
        state(AVAudioApplication.shared.recordPermission)
    }

    static func state(_ permission: AVAudioApplication.recordPermission) -> WelcomePermissionState {
        switch permission {
        case .granted: return .allowed
        case .undetermined: return .askable
        default: return .openSettings
        }
    }

    /// Free space for this iPhone's models.
    static func freeBytes() -> Int64? {
        #if DEBUG
        // `--welcome-free-space <bytes>` stands in for the disk, so the page can be seen with too little room.
        if let bytes = LaunchOptions.value(after: "--welcome-free-space", in: CommandLine.arguments).flatMap(Int64.init) { return bytes }
        #endif
        return (try? URL.homeDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    /// `--welcome-page 1…4` opens a later page, so every page can be captured without tapping.
    private static var initialPage: Page {
        #if DEBUG
        return LaunchOptions.value(after: "--welcome-page", in: CommandLine.arguments).flatMap(Int.init).flatMap(Page.init(rawValue:)) ?? .intro
        #else
        return .intro
        #endif
    }

    // MARK: When it shows

    /// Where Welcome's being done is kept.
    static let completedKey = "phone.welcomeCompleted"

    /// Whether Welcome opens over the app: once, on a first launch. Someone who has used Daybook on this iPhone already
    /// (conversations here, or a paired Mac) isn't welcomed again. Hosted tests never see it, and a debug launch with
    /// options (a demo, a screenshot) sees it only when it asks with `--welcome`.
    static func shouldPresent(completed: Bool, arguments: [String], isTestHost: Bool,
                              hasConversations: Bool, hasPairedMac: Bool) -> Bool {
        guard !completed, !isTestHost else { return false }
        #if DEBUG
        if arguments.contains("--welcome") { return true }
        if arguments.dropFirst().contains(where: { $0.hasPrefix("--") }) { return false }
        #endif
        return !hasConversations && !hasPairedMac
    }

    /// Whether Welcome opens once the library has loaded, and whether this person is at home here already, so it never
    /// opens for them. A paired Mac counts from the stored pairings: the link lists them only once it starts, after
    /// the library and sync. A library that didn't open decides nothing: the app shows, with why, and Welcome is
    /// offered on the next launch.
    static func presentation(completed: Bool, arguments: [String], isTestHost: Bool,
                             library: LibraryController, link: PhoneLink) -> (show: Bool, atHome: Bool) {
        guard library.isLoaded else { return (false, false) }
        let conversations = !library.meetings.isEmpty, paired = link.hasPairedMac
        let show = shouldPresent(completed: completed, arguments: arguments, isTestHost: isTestHost,
                                 hasConversations: conversations, hasPairedMac: paired)
        return (show, !show && (conversations || paired))
    }

    /// Waits for launch to open the library, or to fail to, then decides (`presentation`).
    static func decision(for model: PhoneAppModel, completed: Bool, arguments: [String],
                         isTestHost: Bool) async -> (show: Bool, atHome: Bool) {
        let controller = model.library.controller
        await ObservationWatch.until { controller.isLoaded || model.libraryFailedToOpen }
        return presentation(completed: completed, arguments: arguments, isTestHost: isTestHost,
                            library: controller, link: model.link)
    }
}

extension View {
    /// Welcome over the whole screen on a first launch (`PhoneWelcome.shouldPresent`), in place of the app until it's
    /// done. It takes the screen rather than opening as a cover over it: the library's status sheet is always presented,
    /// and SwiftUI presents one sheet at a time.
    func phoneWelcome() -> some View {
        modifier(PhoneWelcomePresentation())
    }
}

private struct PhoneWelcomePresentation: ViewModifier {
    @Environment(PhoneAppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(PhoneWelcome.completedKey) private var completed = false
    /// Whether Welcome shows; nil while that waits for the library to open, or to fail to. Known at once when it can't
    /// show (Welcome done, a test host, a debug launch with options), so the app appears without a pause.
    @State private var showing: Bool? = PhoneWelcomePresentation.knownAtLaunch()

    func body(content: Content) -> some View {
        ZStack {
            if completed || showing == false {
                content
            } else if showing == true {
                PhoneWelcome { complete() }
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom))
                    .zIndex(1)
            } else {
                // A moment while the library loads: paper, as Welcome begins.
                DaybookPalette.paper.ignoresSafeArea()
            }
        }
        .task {
            guard showing == nil, !completed else { return }
            let decision = await PhoneWelcome.decision(for: model, completed: completed, arguments: CommandLine.arguments,
                                                       isTestHost: LaunchOptions.isTestHost)
            // Someone already at home here: nothing to welcome them to, now or later.
            if decision.atHome { completed = true }
            showing = decision.show
        }
    }

    /// False when Welcome can't show whatever the library holds; nil when that's for the library to say.
    private static func knownAtLaunch() -> Bool? {
        let completed = UserDefaults.standard.bool(forKey: PhoneWelcome.completedKey)
        let possible = PhoneWelcome.shouldPresent(completed: completed, arguments: CommandLine.arguments,
                                                  isTestHost: LaunchOptions.isTestHost, hasConversations: false, hasPairedMac: false)
        return possible ? nil : false
    }

    private func complete() {
        withAnimation(DaybookMotion.resolved(DaybookMotion.page, reduceMotion: reduceMotion)) {
            completed = true
            showing = false
        }
    }
}

// MARK: - Allow

private struct PhoneWelcomeAllow: View {
    let state: WelcomePermissionState
    let allow: () -> Void
    let openSettings: () -> Void
    let next: () -> Void

    var body: some View {
        WelcomeStepPage(title: WelcomeWords.allowTitle, message: WelcomeWords.allowMessage(.iPhone)) {
            WelcomeCard {
                WelcomePermissionRow(WelcomeWords.microphone, symbol: "mic", state: state, device: .iPhone,
                                     allow: allow, openSettings: openSettings)
            }
            .padding(.top, DaybookSpacing.s6)
        } actions: {
            WelcomePrimaryButton(WelcomeWords.next, action: next)
        }
    }
}

// MARK: - Pair

private struct PhoneWelcomePair: View {
    /// The paired Mac's name, once there is one.
    let paired: String?
    let pair: () -> Void
    let next: () -> Void

    var body: some View {
        WelcomeStepPage(title: WelcomeWords.pairTitle, message: WelcomeWords.pairMessage) {
            if let paired {
                Label {
                    Text(WelcomeWords.paired(with: paired)).foregroundStyle(DaybookPalette.Ink.body)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(DaybookPalette.Ink.link)
                }
                .padding(.top, DaybookSpacing.s6)
            } else {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 56, weight: .regular))
                    .foregroundStyle(DaybookPalette.brandGradient(.mark))
                    .padding(.top, DaybookSpacing.s6)
                    .accessibilityHidden(true)
            }
        } actions: {
            if paired == nil {
                WelcomePrimaryButton(WelcomeWords.pair, action: pair)
                WelcomeNotNowButton(action: next)
            } else {
                WelcomePrimaryButton(WelcomeWords.next, action: next)
            }
        }
    }
}

// MARK: - Models

/// What Welcome's Models page offers this iPhone (docs/iphone.md, "Welcome"): what transcribing here still needs and,
/// where this iPhone can run a summary model, that model, each a row. Never a summary the iPhone can't make.
struct PhoneWelcomeOffer: Equatable {
    enum Part: Hashable { case transcription, summaries }

    struct Row: Equatable {
        var part: Part
        var bytes: Int64
    }

    var rows: [Row]

    init(rows: [Row]) { self.rows = rows }

    /// "Transcription and speakers", then "Summaries" where a summary model fits this iPhone and isn't here yet.
    @MainActor init(models: PhoneModels) {
        var rows: [Row] = []
        let transcribing = models.processingMissingBytes
        if transcribing > 0 { rows.append(Row(part: .transcription, bytes: transcribing)) }
        let summary = models.summaryModelBytes
        if summary > 0 { rows.append(Row(part: .summaries, bytes: summary)) }
        self.rows = rows
    }

    /// Each row can be left out only where there are two: one alone is the page's whole offer.
    var choosesRows: Bool { rows.count > 1 }

    /// What the rows in `chosen` download together.
    func bytes(_ chosen: Set<Part>) -> Int64 { rows.filter { chosen.contains($0.part) }.reduce(0) { $0 + $1.bytes } }

    /// Every row checked at first, each that fits beside the ones before it in `free` (unknown: all of them).
    func initialChoice(free: Int64?) -> Set<Part> {
        var chosen = Set<Part>()
        for row in rows where free.map({ bytes(chosen) + row.bytes <= $0 }) ?? true { chosen.insert(row.part) }
        return chosen
    }

    /// What checking `row` would need beside the rest of `chosen`, when that's more than `free`; nil when it fits.
    func shortfall(_ row: Row, chosen: Set<Part>, free: Int64?) -> Int64? {
        guard let free else { return nil }
        let needed = bytes(chosen.subtracting([row.part])) + row.bytes
        return needed > free ? needed : nil
    }
}

/// This iPhone's own models: what transcribing what it records needs and, where it can run one, the summary model,
/// each with its size and checked; the total on Download and Continue, or Not Now.
private struct PhoneWelcomeModels: View {
    let models: PhoneModels
    let freeBytes: Int64?
    @Binding var chosen: Set<PhoneWelcomeOffer.Part>?
    let download: (Set<PhoneWelcomeOffer.Part>) -> Void
    let skip: () -> Void

    /// Whether this iPhone can transcribe its own recordings at all.
    static func offered(_ models: PhoneModels) -> Bool {
        guard let transcription = models.choice(for: .transcription) else { return false }
        if case .unavailable = models.status(of: transcription) { return false }
        return true
    }

    private var offer: PhoneWelcomeOffer { PhoneWelcomeOffer(models: models) }
    /// Only rows still offered: one that finished downloading meanwhile goes.
    private var parts: Set<PhoneWelcomeOffer.Part> {
        (chosen ?? offer.initialChoice(free: freeBytes)).intersection(offer.rows.map(\.part))
    }
    private var total: Int64 { offer.bytes(parts) }
    private var fits: Bool { freeBytes.map { total <= $0 } ?? true }
    /// The whole set's figure while what transcribing needs arrives, as every surface says it.
    private var downloading: Double? {
        guard models.transcribingDownload != nil, case .downloading? = models.processingDownloadState else { return nil }
        return models.processingDownloadState?.fraction
    }

    var body: some View {
        let offer = self.offer
        WelcomeStepPage(title: WelcomeWords.phoneModelsTitle, message: WelcomeWords.phoneModelsMessage) {
            if let downloading {
                WelcomeDownloadProgress(WelcomeWords.downloading(nil), fraction: downloading)
                    .padding(.top, DaybookSpacing.s6)
            } else if !offer.rows.isEmpty {
                WelcomeCard {
                    ForEach(offer.rows, id: \.part) { row in
                        PhoneWelcomeModelRow(row: row, chooses: offer.choosesRows, isChosen: parts.contains(row.part),
                                             shortfall: offer.shortfall(row, chosen: parts, free: freeBytes), freeBytes: freeBytes) {
                            var next = parts
                            if next.contains(row.part) { next.remove(row.part) } else { next.insert(row.part) }
                            chosen = next
                        }
                    }
                }
                .padding(.top, DaybookSpacing.s6)
            }
            Text(WelcomeWords.changeLater)
                .font(.subheadline)
                .foregroundStyle(DaybookPalette.Ink.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, DaybookSpacing.s4)
        } actions: {
            if !parts.isEmpty && downloading == nil {
                WelcomePrimaryButton(offer.choosesRows ? WelcomeWords.downloadAndContinue(ByteSize.format(total)) : WelcomeWords.downloadAndContinue) {
                    download(parts)
                }
                .disabled(!fits)
                WelcomeNotNowButton(action: skip)
            } else {
                WelcomePrimaryButton(WelcomeWords.next, action: skip)
            }
        }
    }
}

/// One row of the Models page's card: what it holds, its size (or the room it needs, in the warning ink), and, where
/// the page offers two, whether it's checked. A row that can't fit beside the rest can't be checked.
private struct PhoneWelcomeModelRow: View {
    let row: PhoneWelcomeOffer.Row
    let chooses: Bool
    let isChosen: Bool
    let shortfall: Int64?
    let freeBytes: Int64?
    let toggle: () -> Void

    var body: some View {
        if chooses {
            Button(action: toggle) { content }
                .buttonStyle(.plain)
                .disabled(shortfall != nil && !isChosen)
                .accessibilityAddTraits(isChosen ? .isSelected : [])
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: DaybookSpacing.s3) {
            DaybookTile(symbol: row.part == .transcription ? "text.bubble" : "text.alignleft", size: .row)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.part == .transcription ? WelcomeWords.phoneModelsRow : WelcomeWords.phoneSummariesRow)
                    .foregroundStyle(DaybookPalette.Ink.title)
                // Its size, or what it needs when the iPhone can't hold it beside the rest.
                if let shortfall, let freeBytes {
                    Text(WelcomeWords.needsSpace(ByteSize.format(shortfall), free: ByteSize.format(freeBytes)))
                        .font(.subheadline)
                        .foregroundStyle(DaybookPalette.Ink.warning)
                } else {
                    Text(ByteSize.format(row.bytes))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(DaybookPalette.Ink.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if chooses {
                Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isChosen ? DaybookPalette.Ink.link : DaybookPalette.Ink.meta)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, DaybookSpacing.s4)
        .padding(.vertical, DaybookSpacing.s3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Ready

private struct PhoneWelcomeReady: View {
    let message: String
    let record: () -> Void
    let finish: () -> Void

    var body: some View {
        WelcomeStepPage(title: WelcomeWords.readyTitle, message: message, showsMark: true) {
            EmptyView()
        } actions: {
            Button(action: record) {
                RecordControlLabel(title: WelcomeWords.record)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .contentShape(Capsule())
            }
            .daybookControl(.standard, shape: .capsule)
            WelcomeNotNowButton(action: finish)
        }
    }
}
