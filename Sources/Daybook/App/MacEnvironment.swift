import Foundation

/// What `AppState` reaches in this Mac's system on its own, beyond the microphone and call audio (`CaptureEnvironment`):
/// the call monitor's look at the audio server, the Personal lock's watch on the screen, sleep, idleness, and the Focus,
/// Use Calendar's look every 30 seconds, and the live captioners recordings and Listen Live load. Injected, as the
/// iPhone injects `PhoneAppEnvironment`, so nothing a test builds ever touches the real ones:
///
/// - `.live`: the app, built once by `DaybookApp`.
/// - `.inert`: any state a test builds without saying. Its tests drive the monitor with scripted looks, lock and unlock
///   the lock, call `checkCalendar(at:)`, and inject their own captioners.
struct MacEnvironment: Sendable {
    /// The call monitor looks at this Mac's audio for calls while When a call starts isn't Off (`MeetingMonitor`).
    var watchesCalls: Bool
    /// The Personal lock locks with the screen, sleep, and idleness, and starts from the Focus that's on
    /// (`PersonalLock.watchSystem`, `DaybookFocusFilter.catchUp`).
    var watchesPersonalLock: Bool
    /// Use Calendar looks at the calendar every 30 seconds while it's on (`watchCalendar`).
    var watchesCalendar: Bool
    /// Recordings and Listen Live may load a live captioner: the live models, or the Speech framework
    /// (`MacCaptioners.recordingFactory`, `recorderFactory`).
    var makesCaptioners: Bool

    /// The app's: everything real.
    static let live = MacEnvironment(watchesCalls: true, watchesPersonalLock: true, watchesCalendar: true, makesCaptioners: true)

    /// Nothing real: no look at calls, the system's lock, or the calendar, and no captioner.
    static let inert = MacEnvironment(watchesCalls: false, watchesPersonalLock: false, watchesCalendar: false, makesCaptioners: false)
}
