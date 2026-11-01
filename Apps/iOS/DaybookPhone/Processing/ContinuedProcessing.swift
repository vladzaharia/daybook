import BackgroundTasks
import Foundation

/// The system's continued-processing task (iOS 26, `BGContinuedProcessingTask`) for work the person
/// started: a recording they stopped, an import, Transcribe. Submitted while Daybook is on the screen,
/// it lets the work go on in the background, with its progress in the system's own Live Activity,
/// until the work is done or the system ends it (`onExpire`). Where the system doesn't allow one (the
/// simulator, background launches turned off, too much load), nothing is shown and the work pauses
/// when Daybook leaves the screen and resumes when it's back (`PhoneProcessor`).
///
/// One task per job, each submission under an identifier of its own (`<prefix>.<UUID>`, never the
/// job's: a job paused and resumed asks again): the system ends an app that registers one identifier
/// twice.
@MainActor
final class ContinuedProcessing {
    /// A task the system started, as the processor uses it (a test's fake, or `BGContinuedProcessingTask`).
    protocol Task: AnyObject {
        var progress: Progress { get }
        func update(title: String, subtitle: String)
        var expirationHandler: (() -> Void)? { get set }
        func complete(success: Bool)
    }

    /// Submits a request and starts its task (the system's scheduler, or a test's).
    protocol Scheduler {
        /// Throws when the system won't run it now; `launch` gets the task once the system starts it.
        func submit(identifier: String, title: String, subtitle: String, launch: @escaping @MainActor (any Task) -> Void) throws
    }

    /// The identifiers' common start, listed (with ".*") in Info.plist's `BGTaskSchedulerPermittedIdentifiers`.
    static let prefix = "local.daybook.phone.processing"
    /// Progress is reported in thousandths.
    static let units: Int64 = 1000

    /// Called on the main actor when the system ends the task before the work is done.
    var onExpire: (() -> Void)?
    /// The task running now, once the system has started it.
    private(set) var task: (any Task)?
    /// The job a request was submitted for, until it ends.
    private var job: UUID?
    private var title = "", subtitle = ""
    private var fraction = 0.0
    private let scheduler: (any Scheduler)?

    /// `scheduler` nil: never submits (tests that don't exercise it, demos).
    init(scheduler: (any Scheduler)?) { self.scheduler = scheduler }

    /// A task is running for the current job: its work may go on in the background.
    var isRunning: Bool { task != nil }

    /// Asks the system to let `job` go on in the background. Call while Daybook is on the screen; once
    /// per job (again for the same job does nothing). Returns whether the request was accepted.
    @discardableResult
    func begin(job id: UUID, title: String, subtitle: String) -> Bool {
        guard job != id else { return true }
        end(success: false)
        guard let scheduler else { return false }
        self.title = title; self.subtitle = subtitle; fraction = 0
        do {
            job = id
            try scheduler.submit(identifier: "\(Self.prefix).\(UUID().uuidString)", title: title, subtitle: subtitle) { [weak self] task in
                self?.started(task, for: id)
            }
            return true
        } catch {
            job = nil
            return false
        }
    }

    /// The work's progress (0…1) and, when it changes, what it's doing.
    func report(fraction: Double, title: String? = nil, subtitle: String? = nil) {
        self.fraction = min(1, max(0, fraction.isFinite ? fraction : 0))
        if let title { self.title = title }
        if let subtitle { self.subtitle = subtitle }
        guard let task else { return }
        task.progress.completedUnitCount = Int64(self.fraction * Double(Self.units))
        if title != nil || subtitle != nil { task.update(title: self.title, subtitle: self.subtitle) }
    }

    /// The job ended (finished, failed, paused, or handed to a Mac): the task ends with it.
    func end(success: Bool) {
        job = nil
        guard let task else { return }
        self.task = nil
        task.expirationHandler = nil
        task.progress.completedUnitCount = success ? Self.units : task.progress.completedUnitCount
        task.complete(success: success)
    }

    private func started(_ task: any Task, for id: UUID) {
        // The job ended before the system started its task: nothing to do.
        guard job == id else { task.complete(success: true); return }
        self.task = task
        task.progress.totalUnitCount = Self.units
        task.progress.completedUnitCount = Int64(fraction * Double(Self.units))
        task.update(title: title, subtitle: subtitle)
        task.expirationHandler = { [weak self] in
            Swift.Task { @MainActor in self?.expired(task) }
        }
    }

    private func expired(_ task: any Task) {
        guard self.task === task else { return }
        self.task = nil
        job = nil
        task.complete(success: false)
        onExpire?()
    }
}

/// The system's scheduler: `BGTaskScheduler` with a continued-processing request that fails at once
/// when it can't run now, rather than waiting in a queue (the work has already started on the screen).
struct SystemContinuedProcessingScheduler: ContinuedProcessing.Scheduler {
    struct Refused: Error {}

    func submit(identifier: String, title: String, subtitle: String, launch: @escaping @MainActor (any ContinuedProcessing.Task) -> Void) throws {
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
            MainActor.assumeIsolated { launch(SystemContinuedTask(task)) }
        }
        guard registered else { throw Refused() }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        try BGTaskScheduler.shared.submit(request)
    }
}

/// `BGContinuedProcessingTask` as `ContinuedProcessing.Task`.
final class SystemContinuedTask: ContinuedProcessing.Task {
    private let task: BGContinuedProcessingTask
    init(_ task: BGContinuedProcessingTask) { self.task = task }
    var progress: Progress { task.progress }
    func update(title: String, subtitle: String) { task.updateTitle(title, subtitle: subtitle) }
    var expirationHandler: (() -> Void)? {
        get { task.expirationHandler }
        set { task.expirationHandler = newValue }
    }
    func complete(success: Bool) { task.setTaskCompleted(success: success) }
}
