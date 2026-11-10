import Foundation

/// Which microphone a recording uses, one rule for both apps (docs/capture.md, "Choosing the microphone";
/// docs/iphone.md, "The input").
///
/// **Automatic** (the default) records the system's default input, except a Bluetooth headset that no other app is
/// recording from: then it records the built-in microphone, because opening a headset's microphone switches it to
/// its hands-free (call) profile, narrowband both ways, for as long as the recording runs. When a call app already
/// uses the headset's microphone it's in that profile anyway, and the headset is what hears the person, so it's
/// recorded. The iPhone can't see other apps' audio, so there Automatic means the built-in microphone unless the
/// person picks the headset.
///
/// A chosen input is used whenever it's there. It's remembered by its device and by its kind: chosen AirPods stand
/// for a Bluetooth headset, so another headset is used while those are away; a chosen USB microphone, for a wired one.
/// With nothing of its kind there, Automatic decides.
public enum MicrophoneChoice {
    /// An input a recording can use.
    public struct Device: Equatable, Hashable, Codable, Sendable, Identifiable {
        public enum Kind: String, Equatable, Hashable, Codable, Sendable {
            /// The Mac's or the iPhone's own microphone.
            case builtIn
            /// AirPods and other Bluetooth headsets: opening their microphone switches them to hands-free.
            case bluetoothHeadset
            /// A USB or Thunderbolt microphone or interface, a wired headset.
            case wired
            /// Anything else: a virtual or aggregate device, Continuity Camera, a car.
            case other
        }

        /// Core Audio's device UID on the Mac; the port's UID on the iPhone.
        public var id: String
        /// "MacBook Pro Microphone", "AirPods Pro", "iPhone Microphone".
        public var name: String
        public var kind: Kind

        public init(id: String, name: String, kind: Kind) {
            self.id = id
            self.name = name
            self.kind = kind
        }
    }

    /// What the person chose, kept between recordings.
    public enum Preference: Equatable, Hashable, Codable, Sendable {
        case automatic
        /// This input whenever it's there; one of its kind when it isn't.
        case device(Device)

        /// The chosen input, if one was.
        public var device: Device? {
            if case .device(let device) = self { return device }
            return nil
        }
    }

    /// The inputs at a moment, with what the choice needs to know about them.
    public struct Snapshot: Equatable, Sendable {
        public var devices: [Device]
        /// The system's default input; nil where there's no such thing to read (an iPhone's inactive session).
        public var systemDefault: Device.ID?
        /// Inputs another app is recording from now (a call app on the AirPods' microphone).
        public var runningElsewhere: Set<Device.ID>
        public var preference: Preference

        public init(devices: [Device], systemDefault: Device.ID?, runningElsewhere: Set<Device.ID> = [], preference: Preference) {
            self.devices = devices
            self.systemDefault = systemDefault
            self.runningElsewhere = runningElsewhere
            self.preference = preference
        }

        /// The input a recording uses now.
        public var resolved: Device? {
            MicrophoneChoice.resolve(devices: devices, systemDefault: systemDefault, runningElsewhere: runningElsewhere, preference: preference)
        }

        /// The built-in microphone, the last resort when an input won't start.
        public var builtIn: Device? { devices.first { $0.kind == .builtIn } }
    }

    /// The input to record: the chosen one when it's there (or, when it isn't, one of its kind), else Automatic's.
    /// Nil only when there's no input at all.
    public static func resolve(devices: [Device], systemDefault: Device.ID?, runningElsewhere: Set<Device.ID> = [],
                               preference: Preference) -> Device? {
        if let chosen = preference.device {
            if let exact = devices.first(where: { $0.id == chosen.id }) { return exact }
            if chosen.kind == .bluetoothHeadset || chosen.kind == .wired, let alike = devices.first(where: { $0.kind == chosen.kind }) {
                return alike
            }
        }
        let builtIn = devices.first { $0.kind == .builtIn }
        guard let preferred = devices.first(where: { $0.id == systemDefault }) ?? builtIn ?? devices.first else { return nil }
        // Opening an idle headset's microphone would put it into call mode for the whole recording.
        if preferred.kind == .bluetoothHeadset, !runningElsewhere.contains(preferred.id), let builtIn { return builtIn }
        return preferred
    }

    /// What a menu of inputs calls Automatic.
    public static let automaticTitle = "Automatic"

    /// The menu's inputs: each one there now, then a chosen one that isn't (so the choice still shows).
    public static func menuDevices(_ devices: [Device], preference: Preference) -> [Device] {
        guard let chosen = preference.device, !devices.contains(where: { $0.id == chosen.id }) else { return devices }
        return devices + [chosen]
    }
}
