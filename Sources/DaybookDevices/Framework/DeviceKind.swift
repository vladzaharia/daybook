import DaybookCore
import Foundation

// The hardware-agnostic device model. A *device kind* (Soundcore Work, "Other recorder", and in
// future, Plaud NotePin) declares who it is and the ways its recordings can reach Daybook, in
// order of preference. A *configured device* is one the person added. Each of its connection
// methods is an independent `DeviceConnection`. See docs/devices.md.

/// How a recorder's recordings reach Daybook.
public enum ConnectionMethodKind: String, Codable, CaseIterable, Hashable, Comparable {
    /// Daybook talks to the recorder itself, over Bluetooth LE, USB, or the local network.
    case direct
    /// The person saves exported audio to a folder that Daybook watches.
    case files
    /// A vendor app or account. Declared so the architecture has a place for it, but Daybook
    /// implements none: it never sends audio off the Mac to be processed.
    case account

    public static func < (lhs: Self, rhs: Self) -> Bool { allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)! }
}

/// The link a direct method uses.
public enum DirectTransport: String, Codable, Hashable {
    case bluetoothLE, usb, localNetwork

    public var title: String {
        switch self {
        case .bluetoothLE: return "Bluetooth"
        case .usb: return "USB"
        case .localNetwork: return "Wi‑Fi"
        }
    }
}

/// One way a device kind's recordings can arrive, with the copy its setup card and settings use.
public struct ConnectionMethod: Hashable, Identifiable {
    public let kind: ConnectionMethodKind
    public var transport: DirectTransport?
    /// "Directly over Bluetooth", "From the Soundcore app".
    public let title: String
    /// One or two sentences for the setup card.
    public let summary: String
    public let systemImage: String
    /// The setup card's button: "Continue…", "Choose Folder…".
    public let setupAction: String
    /// A short fact shown under the summary in setup, such as what macOS will ask.
    public var note: String?
    /// False for methods declared for the architecture but not built (vendor accounts).
    public var isImplemented = true

    public var id: ConnectionMethodKind { kind }

    public init(kind: ConnectionMethodKind, transport: DirectTransport? = nil, title: String, summary: String, systemImage: String, setupAction: String, note: String? = nil, isImplemented: Bool = true) {
        self.kind = kind
        self.transport = transport
        self.title = title
        self.summary = summary
        self.systemImage = systemImage
        self.setupAction = setupAction
        self.note = note
        self.isImplemented = isImplemented
    }
}

/// A kind of recorder Daybook can bring recordings in from.
public struct DeviceKind: Identifiable, Hashable {
    /// Stable, stored on every imported recording: `soundcore.work`.
    public let id: String
    /// "Soundcore Work".
    public let name: String
    /// Used inside sentences after the first mention: "on your Soundcore".
    public let shortName: String
    public let vendor: String?
    public let systemImage: String
    /// One line in the Add Device chooser.
    public let summary: String
    /// Supported methods, most preferred first. Setup offers them in this order.
    public let methods: [ConnectionMethod]
    /// How imported audio is labelled in a conversation's recordings.
    public let audioSource: AudioSource
    /// Whether the person can add more than one of this kind.
    public let allowsMultiple: Bool
    /// Tips shown while looking for the recorder, when it doesn't appear.
    public var discoveryTips: [DeviceTip] = []
    /// Device Details › Technical Details: what is and isn't verified about this integration.
    public var technicalNotes: [String] = []
    /// The empty state when the recorder holds nothing yet.
    public var emptyHint: String?

    public var implementedMethods: [ConnectionMethod] { methods.filter(\.isImplemented) }
    public func method(_ kind: ConnectionMethodKind) -> ConnectionMethod? { methods.first { $0.kind == kind } }
    public var preferredMethod: ConnectionMethod? { implementedMethods.first }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public init(id: String, name: String, shortName: String, vendor: String?, systemImage: String, summary: String, methods: [ConnectionMethod], audioSource: AudioSource, allowsMultiple: Bool, discoveryTips: [DeviceTip] = [], technicalNotes: [String] = [], emptyHint: String? = nil) {
        self.id = id
        self.name = name
        self.shortName = shortName
        self.vendor = vendor
        self.systemImage = systemImage
        self.summary = summary
        self.methods = methods
        self.audioSource = audioSource
        self.allowsMultiple = allowsMultiple
        self.discoveryTips = discoveryTips
        self.technicalNotes = technicalNotes
        self.emptyHint = emptyHint
    }
}

/// One tip for finding a recorder that doesn't appear.
public struct DeviceTip: Hashable {
    public let symbol: String
    public let text: String

    public init(symbol: String, text: String) {
        self.symbol = symbol
        self.text = text
    }
}

/// Builds the connections for a kind's methods. The files method is shared by every kind, so an
/// integration only provides the methods that are its own (direct, and in future, account).
@MainActor
public protocol DeviceIntegration {
    var kind: DeviceKind { get }
    /// A connection for one of the kind's own methods, or nil when the kind doesn't implement it.
    func makeConnection(_ method: ConnectionMethodKind, for device: ConfiguredDevice,
                        environment: DeviceEnvironment) -> (any DeviceConnection)?
}

/// Every kind Daybook knows, in the order the Add Device chooser lists them.
@MainActor
public enum DeviceCatalog {
    public static var integrations: [any DeviceIntegration] = [SoundcoreWorkIntegration(), DaybookPhoneIntegration(), OtherRecorderIntegration()]
    public static var kinds: [DeviceKind] { integrations.map(\.kind) }
    public static func integration(_ id: String) -> (any DeviceIntegration)? { integrations.first { $0.kind.id == id } }
    public static func kind(_ id: String) -> DeviceKind? { integration(id)?.kind }
}

/// A device the person added, persisted in preferences. Each method's own configuration (the
/// remembered recorder, the watched folder) is stored by that method under the device's storage.
public struct ConfiguredDevice: Codable, Identifiable, Hashable {
    public var id: String
    public var kindID: String
    /// Shown in the sidebar; defaults to the kind's name.
    public var name: String
    public var addedAt: Date
    /// Methods the person turned off without forgetting them (Settings › Devices).
    public var disabledMethods: Set<ConnectionMethodKind> = []
    /// Import new recordings as soon as the recorder connects, then let it go.
    public var importsAutomatically = true
    /// Automatic imports bring in recordings made after this, so adding a recorder that already
    /// holds months of audio doesn't start a long transfer the person didn't ask for.
    public var automaticImportsSince: Date
    /// "Record along with this Mac" (on an iPhone, "Record Along with This iPhone"): when the device
    /// that manages it starts recording, a recorder with record control starts too, and its recording
    /// joins the same conversation; its button starts that device. Nil (the default) means on.
    public var alsoRecordsWithMac: Bool?
    public var recordsAlongsideMac: Bool { alsoRecordsWithMac ?? true }

    public init(id: String = UUID().uuidString, kind: DeviceKind, name: String? = nil, addedAt: Date = Date()) {
        self.id = id
        self.kindID = kind.id
        self.name = name ?? kind.name
        self.addedAt = addedAt
        self.automaticImportsSince = addedAt
    }

    public func isEnabled(_ method: ConnectionMethodKind) -> Bool { !disabledMethods.contains(method) }
}

/// What a connection needs from the app, injected so tests and demos never touch real hardware.
@MainActor
public struct DeviceEnvironment {
    public var defaults: UserDefaults
    /// Where transferred audio is written before the library copies it.
    public var stagingDirectory: URL
    /// Builds the Bluetooth link for Soundcore. Tests and the simulator replace it.
    public var soundcoreTransport: () -> any SoundcoreTransport = { CoreBluetoothSoundcoreTransport() }
    /// Live captions while listening live to a recorder (DaybookCaptions). The app can point them
    /// at its settings after launch; tests and demos script them.
    public var liveCaptions = LiveCaptionHooks()
    /// Timing for the Soundcore connection; tests shorten these.
    public var soundcoreTiming = SoundcoreTiming()
    /// What Daybook on iPhone's connections need from the app: its local link and whether the
    /// library syncs. Shared by reference, so the app can fill it in after the devices exist.
    public var phone = DaybookPhoneHooks()

    public func storage(for device: ConfiguredDevice, method: ConnectionMethodKind) -> DeviceStorage {
        DeviceStorage(defaults: defaults, prefix: "device.\(device.id).\(method.rawValue).")
    }

    /// The transport and live captions default to the real ones, made on the main actor.
    public init(defaults: UserDefaults, stagingDirectory: URL, soundcoreTransport: (() -> any SoundcoreTransport)? = nil,
                liveCaptions: LiveCaptionHooks? = nil, soundcoreTiming: SoundcoreTiming = SoundcoreTiming()) {
        self.defaults = defaults
        self.stagingDirectory = stagingDirectory
        if let soundcoreTransport { self.soundcoreTransport = soundcoreTransport }
        if let liveCaptions { self.liveCaptions = liveCaptions }
        self.soundcoreTiming = soundcoreTiming
    }
}

/// Preferences namespaced to one device's method.
public struct DeviceStorage {
    public let defaults: UserDefaults
    public let prefix: String

    public func data(_ key: String) -> Data? { defaults.data(forKey: prefix + key) }
    public func string(_ key: String) -> String? { defaults.string(forKey: prefix + key) }
    public func strings(_ key: String) -> [String] { defaults.stringArray(forKey: prefix + key) ?? [] }
    public func date(_ key: String) -> Date? { defaults.object(forKey: prefix + key) as? Date }
    public func set(_ value: Any?, _ key: String) {
        if let value { defaults.set(value, forKey: prefix + key) } else { defaults.removeObject(forKey: prefix + key) }
    }
    public func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? { data(key).flatMap { try? JSONDecoder().decode(type, from: $0) } }
    public func encode<T: Encodable>(_ value: T?, _ key: String) { set(value.flatMap { try? JSONEncoder().encode($0) }, key) }
    /// Removes everything this method stored.
    public func removeAll() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) { defaults.removeObject(forKey: key) }
    }

    public init(defaults: UserDefaults, prefix: String) {
        self.defaults = defaults
        self.prefix = prefix
    }
}
