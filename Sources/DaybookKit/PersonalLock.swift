import DaybookCore
import Foundation
import Observation
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if os(macOS)
import AppKit
#endif

// The lock for Personal conversations (docs/architecture.md, "The Personal lock"). Off by default; with Settings'
// "Require Touch ID for Personal" (the iPhone's "Require Face ID for Personal") on, Personal conversations stay in
// every list with their titles hidden, and their pages stay shut until the person proves it's them: Touch ID, Face ID,
// or, as the system falls back, the login password or passcode, so nobody is locked out. It's a lock on what Daybook
// shows, not encryption: processing, sync, fusion, and the Live Activity never ask it. Each app keeps one, and every
// view that shows a conversation asks it (`hides`), as the library's lists ask it what a Focus leaves out (`lists`).

/// How this device proves its owner: what Settings and the prompt name.
public enum PersonalLockMethod: String, Equatable, Sendable {
    case touchID, faceID, opticID
    /// No biometrics: the Mac's login password.
    case password
    /// No biometrics: the iPhone's passcode.
    case passcode
}

/// Asks the device's owner to prove it's them: the system's (`SystemPersonalLockAuthenticator`), or a test's.
public protocol PersonalLockAuthenticating: Sendable {
    /// What it unlocks with, for Settings' words.
    var method: PersonalLockMethod { get }
    /// True once the owner proved it's them; false when they cancelled or couldn't.
    func authenticate(reason: String) async -> Bool
}

#if canImport(LocalAuthentication)
/// `LAContext` with `.deviceOwnerAuthentication`: Touch ID, Face ID, or Optic ID, falling back to the login password or
/// the passcode. A device with neither can't be asked, so it lets the person in rather than lock them out.
public struct SystemPersonalLockAuthenticator: PersonalLockAuthenticating {
    public init() {}

    public var method: PersonalLockMethod {
        let context = LAContext()
        // The biometry type is known once the context has been asked about biometrics.
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .touchID: return .touchID
        case .faceID: return .faceID
        case .opticID: return .opticID
        default:
            #if os(macOS)
            return .password
            #else
            return .passcode
            #endif
        }
    }

    public func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No password or passcode to ask for: nothing to prove, and nobody locked out.
            return (error as? LAError)?.code == .passcodeNotSet
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}
#endif

/// What a Focus asks of Daybook (each app's `DaybookFocusFilter`): whether Personal conversations show in the library's
/// lists, and whether Daybook asks to record a meeting. Both on outside a Focus. Kept in the app's preferences, the one
/// place both apps' locks read it.
public struct PersonalFocus: Codable, Equatable, Sendable {
    public var showsPersonal: Bool
    public var asksToRecord: Bool

    public init(showsPersonal: Bool = true, asksToRecord: Bool = true) {
        self.showsPersonal = showsPersonal
        self.asksToRecord = asksToRecord
    }

    public static let key = "personalFocus"
    /// Posted when a Focus filter runs, with the new value under `key`: a lock already running follows it.
    public static let changed = Notification.Name("local.daybook.personalFocus.changed")

    public static func load(from defaults: UserDefaults) -> PersonalFocus {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(PersonalFocus.self, from: $0) } ?? PersonalFocus()
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }

    /// A Focus filter ran (or the Focus ended): kept where the app's lock reads it at launch, and told to a lock that's
    /// running now, which keeps it in its own preferences too.
    @MainActor
    public static func set(_ focus: PersonalFocus, in defaults: UserDefaults = .standard) {
        focus.save(to: defaults)
        NotificationCenter.default.post(name: changed, object: nil, userInfo: [key: focus])
    }
}

/// The app's lock for Personal conversations, and the Focus's word on them: the one object every list, page, search
/// result, and Floating Notes asks. Settings turns it on; unlocking asks the authenticator, once at a time; it locks
/// again when the Mac's screen locks or it sleeps, after 10 minutes with no input (`watchSystem`), and when the iPhone's
/// app goes to the background (the app calls `lock()`).
@MainActor
@Observable
public final class PersonalLock {
    /// What changed, for what follows it: a page showing a Personal conversation closes when it locks; the Personal
    /// place gives way when a Focus leaves it out.
    public enum Event: Equatable, Sendable { case locked, focusChanged }

    /// Settings' switch. Off by default.
    public private(set) var isRequired: Bool
    /// The person unlocked Personal since it last locked.
    public private(set) var isUnlocked = false
    /// What the Focus asks for now.
    public private(set) var focus: PersonalFocus
    /// Personal conversations are hidden now.
    public var isLocked: Bool { isRequired && !isUnlocked }

    /// Who's asked to prove it's them. Tests and demos give their own.
    @ObservationIgnored public var authenticator: any PersonalLockAuthenticating
    /// Finds a conversation by its ID, for `hides(_:)` by ID: the app's library.
    @ObservationIgnored public var lookup: (UUID) -> Meeting? = { _ in nil }
    /// With no input for this long, it locks again (the Mac's `watchSystem`).
    public static let idleLimit: TimeInterval = 600
    /// The distributed notification macOS posts as the screen locks.
    public static let screenLocked = Notification.Name("com.apple.screenIsLocked")
    public static let requiredKey = "personalLock.required"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let platform: ConversationAction.Platform
    @ObservationIgnored private var asking: Task<Bool, Never>?
    /// Bumped by every lock, so a prompt answered after the lock came back doesn't unlock it.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var handlers: [(Event) -> Void] = []
    @ObservationIgnored private var idleWatch: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []

    public init(defaults: UserDefaults, platform: ConversationAction.Platform, authenticator: any PersonalLockAuthenticating) {
        self.defaults = defaults
        self.platform = platform
        self.authenticator = authenticator
        isRequired = defaults.bool(forKey: Self.requiredKey)
        focus = PersonalFocus.load(from: defaults)
        let token = NotificationCenter.default.addObserver(forName: PersonalFocus.changed, object: nil, queue: .main) { [weak self] note in
            guard let focus = note.userInfo?[PersonalFocus.key] as? PersonalFocus else { return }
            MainActor.assumeIsolated { self?.apply(focus) }
        }
        observers.append((NotificationCenter.default, token))
    }

    deinit {
        for observer in observers { observer.center.removeObserver(observer.token) }
        idleWatch?.cancel()
    }

    /// What the device unlocks with, for Settings' label.
    public var method: PersonalLockMethod { authenticator.method }

    // MARK: What's shown

    /// Whether `meeting` is shown only as "Personal conversation" now, its page shut until the person unlocks.
    public func hides(_ meeting: Meeting) -> Bool { isLocked && meeting.effectivePlacement == .personal }

    /// The same, for a conversation by its ID (`lookup`); one it can't find isn't hidden here (the Trash's pages ask
    /// with the conversation itself).
    public func hides(_ id: UUID) -> Bool { isLocked && lookup(id)?.effectivePlacement == .personal }

    /// Whether the library's lists show `meeting` now: everything, unless a Focus leaves Personal out.
    public func lists(_ meeting: Meeting) -> Bool { focus.showsPersonal || meeting.effectivePlacement != .personal }

    /// The conversations the lists show now, in their order.
    public func listed(_ meetings: [Meeting]) -> [Meeting] { focus.showsPersonal ? meetings : meetings.filter(lists) }

    /// The first of `meetings` whose page can open without asking: what a list selects by itself.
    public func firstShown(in meetings: [Meeting]) -> Meeting? { meetings.first { !hides($0) } }

    /// The places the sidebar and the place menu offer: Personal leaves while a Focus hides it.
    public var sections: [LibrarySection] { LibrarySection.shown(showingPersonal: focus.showsPersonal) }

    /// A section's symbol: Personal's is the lock while it's locked.
    public func symbol(_ section: LibrarySection) -> String {
        section == .personal && isLocked ? PersonalLockWords.symbol : section.systemImage
    }

    // MARK: Locking and unlocking

    /// Asks the person to prove it's them, once however many ask together. True at once when nothing is locked.
    @discardableResult
    public func unlock() async -> Bool {
        guard isLocked else { return true }
        if let asking { return await asking.value }
        let started = generation
        let authenticator = authenticator
        let reason = PersonalLockWords.reason(platform)
        // The answer is taken here, on the main actor, so everyone waiting on this prompt hears the same one.
        let task = Task { [weak self] () -> Bool in
            let proved = await authenticator.authenticate(reason: reason)
            guard let self else { return false }
            self.asking = nil
            guard proved, self.generation == started, self.isRequired else { return !self.isLocked }
            self.isUnlocked = true
            return true
        }
        asking = task
        return await task.value
    }

    /// Hides Personal again: the screen locked, the Mac slept or sat idle, or the iPhone's app left the screen. What
    /// shows a Personal conversation closes (`observe`).
    public func lock() {
        generation += 1
        guard isUnlocked else { return }
        isUnlocked = false
        notify(.locked)
    }

    /// Settings' switch. On hides Personal at once; off asks first, as unlocking does. False when the person didn't
    /// prove it's them, and the switch stays on.
    @discardableResult
    public func setRequired(_ on: Bool) async -> Bool {
        guard on != isRequired else { return true }
        if on {
            generation += 1
            isRequired = true
            isUnlocked = false
            defaults.set(true, forKey: Self.requiredKey)
            notify(.locked)
            return true
        }
        guard await authenticator.authenticate(reason: PersonalLockWords.reason(platform)) else { return false }
        isRequired = false
        isUnlocked = false
        defaults.set(false, forKey: Self.requiredKey)
        return true
    }

    /// What a Focus filter asks for, kept in this app's preferences (a demo's isn't).
    public func apply(_ focus: PersonalFocus) { apply(focus, saving: true) }

    func apply(_ focus: PersonalFocus, saving: Bool) {
        guard focus != self.focus else { return }
        self.focus = focus
        if saving { focus.save(to: defaults) }
        notify(.focusChanged)
    }

    /// `handler` hears each lock and Focus change, for as long as the lock lives.
    public func observe(_ handler: @escaping (Event) -> Void) {
        handlers.append(handler)
    }

    private func notify(_ event: Event) {
        for handler in handlers { handler(event) }
    }

    /// For demos (`PersonalLockDemo`): on, and locked or not, without asking anyone.
    func demo(required: Bool, unlocked: Bool) {
        isRequired = required
        isUnlocked = required && unlocked
    }

    // MARK: The Mac

    #if os(macOS)
    /// Locks again when the screen locks (`com.apple.screenIsLocked`), the Mac goes to sleep, another user takes the
    /// screen, or after `idleLimit` with no keyboard or pointer input anywhere. The centers and the idle reading are
    /// the system's; tests give their own.
    public func watchSystem(distributed: NotificationCenter = DistributedNotificationCenter.default(),
                            workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
                            idle: @escaping @MainActor () -> TimeInterval = PersonalLock.systemIdle,
                            every interval: Duration = .seconds(30)) {
        let names: [(NotificationCenter, Notification.Name)] = [
            (distributed, Self.screenLocked),
            (workspace, NSWorkspace.willSleepNotification),
            (workspace, NSWorkspace.sessionDidResignActiveNotification)
        ]
        for (center, name) in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lock() }
            }
            observers.append((center, token))
        }
        idleWatch?.cancel()
        idleWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                self.lockIfIdle(for: idle())
            }
        }
    }

    /// Seconds since the last keyboard, pointer, or trackpad input in this login session.
    public static func systemIdle() -> TimeInterval {
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }
    #endif

    /// Locks once nobody has touched the Mac for `idleLimit`.
    public func lockIfIdle(for seconds: TimeInterval) {
        if isUnlocked, seconds >= Self.idleLimit { lock() }
    }
}

extension LibrarySection {
    /// The sections offered: all three, or All and Work while a Focus leaves Personal out (`PersonalFocus`).
    public static func shown(showingPersonal: Bool) -> [LibrarySection] {
        showingPersonal ? allCases : allCases.filter { $0 != .personal }
    }
}

/// `--lock-demo locked|unlocked|focus` (debug launches on both apps): the lock on with Personal locked or unlocked, or
/// a Focus that leaves Personal out. Nothing asks the system: Unlock is refused, so a snapshot stays as launched.
public enum PersonalLockDemo {
    public enum State: String, Sendable { case locked, unlocked, focus }

    public static func state(arguments: [String] = CommandLine.arguments) -> State? {
        guard let index = arguments.firstIndex(of: "--lock-demo"), arguments.indices.contains(index + 1) else { return nil }
        return State(rawValue: arguments[index + 1])
    }

    @MainActor
    public static func apply(_ state: State, to lock: PersonalLock, platform: ConversationAction.Platform) {
        lock.authenticator = Refusing(method: platform == .mac ? .touchID : .faceID)
        switch state {
        case .locked: lock.demo(required: true, unlocked: false)
        case .unlocked: lock.demo(required: true, unlocked: true)
        case .focus: lock.apply(PersonalFocus(showsPersonal: false, asksToRecord: false), saving: false)
        }
    }

    struct Refusing: PersonalLockAuthenticating {
        let method: PersonalLockMethod
        func authenticate(reason: String) async -> Bool { false }
    }
}
