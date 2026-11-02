import DaybookCaptions
import DaybookDesign
import DaybookKit
import DaybookLink
import SwiftUI

// A recorder's screens, the same on the Mac and the iPhone (docs/devices.md, "Interface"): its page, its
// recordings, Listen Live, its handoff, its options, and adding one. They read the device session and the
// handoff themselves; what only an app can do (open a conversation, choose a folder, show Settings, push a
// screen) reaches it through `RecorderServices`, which each app sets once where it shows them.

/// What a recorder's screens need from the app they're in.
public struct RecorderServices {
    /// Which device the words are for ("this Mac", "this iPhone").
    public var place: RecorderStatusWords.Place
    /// Moving recorders between this device and the others.
    public var handoff: RecorderHandoff
    /// This device's recorders.
    public var devices: DeviceHub
    /// Conversations, for the titles of what was imported and the ones to add a recording to.
    public var library: LibraryController
    /// The glyph this device draws for itself: a MacBook's laptop, another Mac's desktop, an iPhone
    /// (`SettingsWords.thisDeviceSymbol`).
    public var thisDeviceSymbol: String
    /// What's happening to an imported conversation, when something is ("Transcribing", "Waiting to transcribe").
    public var processingLabel: @MainActor (Meeting.ID) -> String?
    /// Opens a conversation's page.
    public var showConversation: @MainActor (Meeting.ID) -> Void
    /// What the device managing a recorder last said about it over the link.
    public var linkState: @MainActor (DeviceSession) -> LinkRecorderState?
    /// Opens the system's Bluetooth or privacy settings for a problem's action.
    public var openSystemSettings: @MainActor (DeviceProblemAction) -> Void
    /// Stops importing: the current recording, or all of them. The Mac asks first once a minute has arrived.
    public var stopImporting: @MainActor (DeviceSession, _ all: Bool) -> Void
    /// Device Details (with Technical Details open when asked).
    public var showDetails: @MainActor (DeviceSession) -> Void
    /// Removes the recorder from this device, after the person confirmed it.
    public var remove: @MainActor (DeviceSession) -> Void
    /// What a live captioner is doing, in a sentence ("Getting captions ready…"), or nil to show its lines.
    public var captionStatus: @MainActor (LiveCaptionState) -> String?
    /// Choose Folder… for a recorder's folder method, where this device picks folders from a page (the Mac's open
    /// panel). Returns whether one was chosen. Nil where a folder is chosen only while adding the recorder.
    public var chooseFolder: (@MainActor (DeviceSession) -> Bool)?
    /// Show in Finder for a watched folder (the Mac's).
    public var revealFolder: (@MainActor (URL) -> Void)?
    /// Show in Finder for an imported recording's audio (the Mac's).
    public var revealAudio: (@MainActor (Meeting.ID, String) -> Void)?
    /// Sets up one of a recorder's methods (Add Device for that method), where a page can.
    public var setUpMethod: (@MainActor (DeviceSession, ConnectionMethodKind) -> Void)?
    /// Opens Listen Live's page when listening starts somewhere it isn't shown (the iPhone pushes it).
    public var showListenLive: (@MainActor (DeviceSession) -> Void)?
    /// Opens every recording on the recorder, where it isn't beside the page already (the iPhone pushes it).
    public var showRecordings: (@MainActor (DeviceSession) -> Void)?
    /// "Hand back to your Mac" (the iPhone's): a recorder taken from a Mac goes back when that Mac is near.
    public var handsBack: Binding<Bool>?
    /// Device Details as a popover beside what opened it (the Mac's); nil shows them with `showDetails`.
    public var detailsPopover: (@MainActor (DeviceSession) -> AnyView)?

    public init(place: RecorderStatusWords.Place, handoff: RecorderHandoff, devices: DeviceHub, library: LibraryController, thisDeviceSymbol: String,
                processingLabel: @escaping @MainActor (Meeting.ID) -> String?,
                showConversation: @escaping @MainActor (Meeting.ID) -> Void,
                linkState: @escaping @MainActor (DeviceSession) -> LinkRecorderState?,
                openSystemSettings: @escaping @MainActor (DeviceProblemAction) -> Void,
                stopImporting: @escaping @MainActor (DeviceSession, _ all: Bool) -> Void,
                showDetails: @escaping @MainActor (DeviceSession) -> Void,
                remove: @escaping @MainActor (DeviceSession) -> Void,
                captionStatus: @escaping @MainActor (LiveCaptionState) -> String?,
                chooseFolder: (@MainActor (DeviceSession) -> Bool)? = nil,
                revealFolder: (@MainActor (URL) -> Void)? = nil,
                revealAudio: (@MainActor (Meeting.ID, String) -> Void)? = nil,
                setUpMethod: (@MainActor (DeviceSession, ConnectionMethodKind) -> Void)? = nil,
                showListenLive: (@MainActor (DeviceSession) -> Void)? = nil,
                showRecordings: (@MainActor (DeviceSession) -> Void)? = nil,
                handsBack: Binding<Bool>? = nil,
                detailsPopover: (@MainActor (DeviceSession) -> AnyView)? = nil) {
        self.place = place
        self.handoff = handoff
        self.devices = devices
        self.library = library
        self.thisDeviceSymbol = thisDeviceSymbol
        self.processingLabel = processingLabel
        self.showConversation = showConversation
        self.linkState = linkState
        self.openSystemSettings = openSystemSettings
        self.stopImporting = stopImporting
        self.showDetails = showDetails
        self.remove = remove
        self.captionStatus = captionStatus
        self.chooseFolder = chooseFolder
        self.revealFolder = revealFolder
        self.revealAudio = revealAudio
        self.setUpMethod = setUpMethod
        self.showListenLive = showListenLive
        self.showRecordings = showRecordings
        self.handsBack = handsBack
        self.detailsPopover = detailsPopover
    }

    /// Everything the recorder's status is worded from, now.
    @MainActor
    public func facts(_ session: DeviceSession, now: Date = Date()) -> RecorderFacts {
        RecorderFacts(session: session, handoff: handoff.state(of: session), link: linkState(session),
                      problemTitle: { RecorderStatusWords.problem($0, on: place).title }, now: now)
    }
}

extension EnvironmentValues {
    /// The app's services for a recorder's screens (`RecorderServices`). Nil shows them without actions that need
    /// the app.
    @Entry public var recorderServices: RecorderServices? = nil
}

extension DeviceSession {
    /// Problem actions that don't apply to this recorder now: Set Up Folder… once its folder is set up.
    public var inapplicableProblemActions: Set<DeviceProblemAction> {
        files?.isSetUp == true ? [.setUpFolder] : []
    }

    /// Whether this device imports from the recorder: not from one another device manages over its link, which
    /// imports there (its recordings arrive through sync).
    public var importsHere: Bool { managedElsewhere == nil || primary?.method != .direct }

    /// New recordings this device can import, for the sidebar's count and the menus.
    public var importableCount: Int { importsHere ? newRecordings.count : 0 }
}
