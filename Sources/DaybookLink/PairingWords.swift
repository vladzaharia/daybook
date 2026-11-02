import Foundation

/// What pairing and a paired device's page say, written once for the Mac and the iPhone (docs/link.md,
/// "Pairing"): the same title, each instruction naming the other device's exact control, one way to
/// say what unpairing does, the problems a paired device can have, and why a device turned a record
/// request away. Sentence case, as Settings' words are; the iPhone title-cases its labels where it
/// draws them.
public enum PairingWords {
    // MARK: Controls

    /// The Mac's button: Settings › Devices (beside Add Recorder…, and in its empty state) and Add Device.
    public static let pairWithIPhone = "Pair with iPhone…"
    /// The iPhone's button: Settings › Macs and the status sheet's Macs card.
    public static let pairWithMac = "Pair with Your Mac…"
    public static let unpair = "Unpair…"
    /// On a paired device's page when its pairing no longer works: pair it again, replacing the old one.
    public static let pairAgain = "Pair Again…"
    /// The toggle on a paired device's page: whether that device may start a recording here (and stop one
    /// from its page).
    public static let canStartRecording = "Can start recording"

    // MARK: The pairing screen

    /// "Pair with Your iPhone" on the Mac, "Pair with Your Mac" on the iPhone: the screen's title on a
    /// device of `deviceClass`.
    public static func title(on deviceClass: LinkDeviceClass) -> String {
        deviceClass == .mac ? "Pair with Your iPhone" : "Pair with Your Mac"
    }

    /// "Paired with Studio Mac", once the code is accepted.
    public static func paired(with name: String) -> String { "Paired with \(name)" }

    /// Under the Mac's code: where the iPhone's control is, and which Mac to choose there. The name keeps
    /// to one line ("Vlad’s MacBook Pro (755)"), never split across two.
    public static func onTheIPhone(macName: String) -> String {
        "On your iPhone, open Daybook › Settings › \(control(pairWithMac)), choose “\(macName.replacingOccurrences(of: " ", with: "\u{00A0}"))”, and enter this code."
    }

    /// Under the iPhone's title: where the Mac's control is.
    public static let onTheMac = "On your Mac, open Daybook › Settings › Devices and click \(control(pairWithIPhone))."

    /// While the Mac opens pairing.
    public static let gettingACode = "Getting a code…"
    /// Pairing closed (expired, too many tries): a new code.
    public static let showNewCode = "Show New Code"

    /// "Expires in 4 minutes", under the Mac's code.
    public static func expiry(_ code: LinkPairingCode, now: Date = Date()) -> String {
        let minutes = Int((code.expiresAt.timeIntervalSince(now) / 60).rounded(.up))
        return minutes <= 1 ? "Expires in about a minute" : "Expires in \(minutes) minutes"
    }

    /// "Pairing code 4 8 2 9 1 3", for VoiceOver.
    public static func spoken(_ code: LinkPairingCode) -> String {
        "Pairing code \(code.digits.map(String.init).joined(separator: " "))"
    }

    /// The Mac's list of the iPhones it's paired with.
    public static let pairedIPhones = "Paired iPhones"

    /// The iPhone's list of Macs, and what each row says.
    public static let macsOnThisNetwork = "Macs on this Wi‑Fi"
    public static let lookingForMacs = "Looking for Macs…"
    public static let showingACode = "Showing a code"
    public static let notShowingACode = "Not showing a code"
    public static let alreadyPaired = "Paired"
    /// A Mac with another library open: shown dimmed, never offered.
    public static let usesAnotherLibrary = "Uses another library"
    /// The code's heading on the iPhone, once a Mac is chosen.
    public static func code(on macName: String) -> String { "Code on \(macName)" }
    public static let pairing = "Pairing…"

    /// The iPhone can't look for Macs: Local Network is off for Daybook. With Open Settings.
    public static let allowLocalNetwork = "Allow Daybook to find your Mac on this network."
    /// A paired Mac's row then, while it isn't connected; its page says `allowLocalNetwork`.
    public static let localNetworkOff = "Local Network is off"
    public static let openSettings = "Open Settings"
    /// Nothing found after a while of looking.
    public static let noMacFound = "No Mac found. Open Daybook › Settings › Devices on your Mac, on this Wi‑Fi."
    /// How long the iPhone looks before it says `noMacFound`.
    public static let noMacFoundAfter: Duration = .seconds(15)

    // MARK: Unpairing

    public static func unpairQuestion(_ name: String) -> String { "Unpair \(name)?" }
    /// What unpairing does, the same on both devices.
    public static let unpairConsequence = "Recording together stops until you pair again. Recordings stay in your library."
    /// The alert's title when unpairing didn't work; `AppState.report`'s message says why.
    public static func couldntUnpair(_ name: String) -> String { "Couldn’t Unpair \(name)" }
    public static let couldntUnpairMessage = "The pairing is still there. Try again."

    // MARK: A paired device's page

    /// The other device's name when its pairing can't be read and its item has no label.
    public static func unnamed(_ deviceClass: LinkDeviceClass) -> String { deviceClass == .mac ? "Mac" : "iPhone" }

    /// "Recording now · since 10:02 AM", or "Paused · since 10:02 AM".
    public static func recordingNow(since start: Date?, paused: Bool) -> String {
        (paused ? "Paused" : "Recording now") + (start.map { " · since \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
    }

    /// "Stop on Studio Mac": stops what the other device is recording.
    public static func stop(on name: String) -> String { "Stop on \(name)" }
    public static let recordersItManages = "Recorders it manages"
    public static let transcribes = "Transcribes"
    public static let transcribesYes = "Yes"
    public static let transcribesNotSetUp = "Not set up"
    /// Its Daybook version.
    public static let daybook = "Daybook"
    public static let pairedOn = "Paired"

    // MARK: A paired device's problems

    /// Its pairing is there but can't be read (`LinkPairedDevice.isDamaged`), or the other side doesn't
    /// know this device any more: the row's short line.
    public static let needsPairingAgain = "Needs pairing again"
    /// The page's sentence for a pairing this device can't read.
    public static func cantRead(_ name: String) -> String { "The pairing with \(name) can’t be read. Pair again to connect." }
    /// This device has no pairing for it any more (removed while it was away): "This Mac isn’t paired with Alex’s iPhone."
    public static func notPaired(_ name: String, here: String) -> String {
        "\(here.prefix(1).uppercased() + here.dropFirst()) isn’t paired with \(name)."
    }
    /// The other side no longer knows this device, or this device's key is gone.
    public static func doesntRecognize(_ name: String, here: String) -> String {
        "\(name) doesn’t recognize \(here) anymore. Pair again to connect."
    }

    /// No protocol version in common: which side to update, when the other's versions say so.
    public static func update(_ name: String, here: String, peerVersions: ClosedRange<Int>?,
                              ours: ClosedRange<Int> = LinkProtocol.supportedVersions) -> String {
        switch LinkProtocol.olderSide(peer: peerVersions, ours: ours) {
        case .peer?: return "Update Daybook on \(name) to connect."
        case .this?: return "Update Daybook on \(here) to connect."
        case nil: return "Update Daybook on \(here) or \(name) to connect."
        }
    }

    // MARK: Record requests turned away

    /// A start refused because the asker may not start recording on the device that refused (`declined`),
    /// worded for the asker, who reads it: "It isn’t set to let this Mac start recording. Turn on Can Start
    /// Recording for this Mac on the iPhone." Each names the toggle as the refusing device draws it.
    public static func notAllowedToStart(asker: LinkDeviceClass) -> String {
        "It isn’t set to let \(here(asker)) start recording. Turn on \(toggle(on: other(asker))) for \(here(asker)) on the \(name(other(asker)))."
    }

    /// A stop from another device's page refused for the same reason.
    public static func notAllowedToStop(asker: LinkDeviceClass) -> String {
        "It isn’t set to let \(here(asker)) stop its recording. Turn on \(toggle(on: other(asker))) for \(here(asker)) on the \(name(other(asker)))."
    }

    /// A refusal that came without words: "Studio Mac isn’t set to record with this iPhone."
    public static func declined(_ name: String, here: String) -> String { "\(name) isn’t set to record with \(here)." }

    // MARK: Helpers

    /// "this Mac", "this iPhone".
    public static func here(_ deviceClass: LinkDeviceClass) -> String { "this \(name(deviceClass))" }

    private static func name(_ deviceClass: LinkDeviceClass) -> String { deviceClass == .mac ? "Mac" : "iPhone" }

    private static func other(_ deviceClass: LinkDeviceClass) -> LinkDeviceClass { deviceClass == .mac ? .iPhone : .mac }

    /// The toggle as `deviceClass` draws it: the iPhone title-cases its Settings labels.
    private static func toggle(on deviceClass: LinkDeviceClass) -> String {
        deviceClass == .mac ? canStartRecording : "Can Start Recording"
    }

    /// A control named in a sentence: without its ellipsis.
    private static func control(_ title: String) -> String {
        title.hasSuffix("…") ? String(title.dropLast()) : title
    }
}

extension LinkProtocol {
    /// Which side of a pair runs the older Daybook.
    public enum Side: Sendable, Equatable {
        /// This device.
        case this
        /// The other device.
        case peer
    }

    /// The side that's older when two version ranges don't meet; nil when that can't be told (no
    /// range from the other side, or ranges that overlap).
    public static func olderSide(peer: ClosedRange<Int>?, ours: ClosedRange<Int> = supportedVersions) -> Side? {
        guard let peer else { return nil }
        if peer.upperBound < ours.lowerBound { return .peer }
        if peer.lowerBound > ours.upperBound { return .this }
        return nil
    }
}
