import XCTest
@testable import DaybookKit

/// Which microphone a recording uses (`MicrophoneChoice`): Automatic never opens an idle headset's microphone, a call
/// app's headset is recorded, and a chosen input is used whenever it (or one of its kind) is there.
final class MicrophoneChoiceTests: XCTestCase {
    private typealias Device = MicrophoneChoice.Device
    private let macBook = Device(id: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", kind: .builtIn)
    private let airPods = Device(id: "AC-90-85:input", name: "AirPods Pro", kind: .bluetoothHeadset)
    private let otherHeadset = Device(id: "F4-2B-11:input", name: "Jabra Evolve2", kind: .bluetoothHeadset)
    private let usb = Device(id: "AppleUSBAudioEngine:Shure:MV7", name: "Shure MV7", kind: .wired)
    private let virtual = Device(id: "BlackHole2ch_UID", name: "BlackHole 2ch", kind: .other)
    private let loopback = Device(id: "Loopback_UID", name: "Loopback Audio", kind: .other)

    private func resolve(_ devices: [Device], default systemDefault: Device?, runningElsewhere: Set<String> = [],
                         _ preference: MicrophoneChoice.Preference = .automatic) -> Device? {
        MicrophoneChoice.resolve(devices: devices, systemDefault: systemDefault?.id, runningElsewhere: runningElsewhere, preference: preference)
    }

    // MARK: Automatic

    /// AirPods are the default input, and Zoom is on the built-in microphone: Daybook records the built-in microphone, so
    /// the AirPods stay in their high-quality profile.
    func testBehaviorAutomaticLeavesIdleAirPodsAloneForTheBuiltInMicrophone() {
        XCTAssertEqual(resolve([macBook, airPods], default: airPods), macBook)
    }

    /// Zoom already records from the AirPods: they're in call mode anyway and they hear the person, so they're recorded.
    func testBehaviorAutomaticRecordsAirPodsACallAppIsUsing() {
        XCTAssertEqual(resolve([macBook, airPods], default: airPods, runningElsewhere: [airPods.id]), airPods)
    }

    /// Any other default input is used as it is: a USB microphone, the built-in one, a virtual device.
    func testBehaviorAutomaticFollowsADefaultThatIsntAHeadset() {
        XCTAssertEqual(resolve([macBook, airPods, usb], default: usb), usb)
        XCTAssertEqual(resolve([macBook], default: macBook), macBook)
        XCTAssertEqual(resolve([macBook, virtual], default: virtual), virtual)
    }

    /// With only the built-in microphone, or no default to read, it's the built-in one; with nothing, nothing.
    func testBehaviorBuiltInOnlyAndNoDefault() {
        XCTAssertEqual(resolve([macBook], default: nil), macBook)
        XCTAssertEqual(resolve([airPods, macBook], default: nil), macBook, "an iPhone's session before it's active")
        XCTAssertNil(resolve([], default: nil))
    }

    /// A Mac with no microphone of its own (a Mac mini) records the headset rather than nothing.
    func testBehaviorAHeadsetIsRecordedWhenThereIsNoBuiltInMicrophone() {
        XCTAssertEqual(resolve([airPods], default: airPods), airPods)
    }

    // MARK: A chosen input

    func testBehaviorAChosenInputIsUsedWhenItsThere() {
        XCTAssertEqual(resolve([macBook, airPods, usb], default: usb, .device(airPods)), airPods, "chosen, so opened even though idle")
        XCTAssertEqual(resolve([macBook, airPods], default: airPods, .device(macBook)), macBook)
    }

    /// Chosen AirPods stand for a Bluetooth headset, a chosen USB microphone for a wired one; without one of its kind,
    /// Automatic decides.
    func testBehaviorAnAbsentChoiceFallsToOneOfItsKindThenToAutomatic() {
        XCTAssertEqual(resolve([macBook, otherHeadset], default: otherHeadset, .device(airPods)), otherHeadset)
        let otherUSB = Device(id: "AppleUSBAudioEngine:Blue:Yeti", name: "Yeti", kind: .wired)
        XCTAssertEqual(resolve([macBook, otherUSB], default: macBook, .device(usb)), otherUSB)
        XCTAssertEqual(resolve([macBook, airPods], default: airPods, .device(usb)), macBook, "no wired input: Automatic, which leaves AirPods idle")
        XCTAssertEqual(resolve([macBook, loopback], default: macBook, .device(virtual)), macBook, "another virtual device is no stand-in")
    }

    // MARK: Snapshot and menu

    func testBehaviorTheSnapshotResolvesAndNamesTheBuiltInMicrophone() {
        let snapshot = MicrophoneChoice.Snapshot(devices: [airPods, macBook], systemDefault: airPods.id, preference: .automatic)
        XCTAssertEqual(snapshot.resolved, macBook)
        XCTAssertEqual(snapshot.builtIn, macBook)
    }

    /// The menu lists what's there and keeps a chosen input that's away, so the choice still shows.
    func testBehaviorTheMenuKeepsAChosenInputThatIsAway() {
        XCTAssertEqual(MicrophoneChoice.menuDevices([macBook], preference: .device(airPods)), [macBook, airPods])
        XCTAssertEqual(MicrophoneChoice.menuDevices([macBook, airPods], preference: .device(airPods)), [macBook, airPods])
        XCTAssertEqual(MicrophoneChoice.menuDevices([macBook], preference: .automatic), [macBook])
        XCTAssertEqual(MicrophoneChoice.automaticTitle, "Automatic")
    }

    /// The choice is stored between recordings: it reads back as it was written.
    func testBehaviorThePreferenceRoundTrips() throws {
        for preference in [MicrophoneChoice.Preference.automatic, .device(airPods)] {
            let data = try JSONEncoder().encode(preference)
            XCTAssertEqual(try JSONDecoder().decode(MicrophoneChoice.Preference.self, from: data), preference)
        }
    }
}
