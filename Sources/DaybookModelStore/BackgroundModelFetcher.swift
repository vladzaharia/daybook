import DaybookKit
import Foundation

/// Model downloads that carry on while the app is suspended, or after iOS ends it: the iPhone's live
/// models (a 566 MB encoder among them) through a background `URLSession`, so the system's own
/// process keeps transferring when Daybook isn't running (docs/iphone.md, "Live transcription").
///
/// - Each file is one download task from Hugging Face, pinned to the artifact's commit, landing at its
///   repository path in the partial folder the store gave; the store verifies every file afterwards,
///   as it does `HubSnapshotFetcher`'s.
/// - A download stopped partway (cancelled, or a network error) keeps what it fetched as the system's
///   resume data beside the file (`<file>.resume`), and the next attempt continues from there.
/// - Wi‑Fi only unless cellular is allowed: a task on the Wi‑Fi session never uses an expensive network
///   (cellular, a hotspot) or Low Data Mode, and simply waits for Wi‑Fi. The two choices are two
///   sessions, because a session's network rules are fixed when it's made.
/// - After a relaunch the sessions are made again with the same identifiers, which reconnects their
///   tasks: a fetch for a file already downloading waits for that task instead of starting another,
///   and `inFlight` names them, so the app can show them and finish their installs. When iOS
///   relaunches the app for a session's events, `handleEvents` takes the completion handler.
public final class BackgroundModelFetcher: NSObject, ModelArtifactFetcher, URLSessionDownloadDelegate, @unchecked Sendable {
    /// The sessions' identifiers start with this; ".wifi" and ".any" follow.
    public static let identifier = "local.daybook.models"

    public enum Failure: LocalizedError, Equatable {
        case http(Int)
        case interrupted

        public var errorDescription: String? {
            switch self {
            case .http(let status): return "The model server answered \(status)."
            case .interrupted: return "The download stopped."
            }
        }
    }

    /// Downloads may use cellular data (and Low Data Mode) when they start from now on.
    public var allowsCellular: Bool {
        get { lock.withLock { cellular } }
        set { lock.withLock { cellular = newValue } }
    }

    private let identifier: String
    private let base: URL
    private let makeConfiguration: (_ identifier: String, _ cellular: Bool) -> URLSessionConfiguration
    private let lock = NSLock()
    private var cellular = false
    private var sessions: [Bool: URLSession] = [:]
    /// Waiting for each file to arrive, by its destination's path.
    private var waiting: [String: [CheckedContinuation<Void, Error>]] = [:]
    /// Bytes written so far by each file's task.
    private var written: [String: Int64] = [:]
    /// Why a file's task failed, between the delegate's two calls.
    private var failures: [String: Error] = [:]
    private var progressHandlers: [UUID: () -> Void] = [:]
    private var finishedEvents: [String: () -> Void] = [:]

    /// `base`: where repositories are (Hugging Face; tests use a local server). `configuration`: the
    /// sessions' configuration for an identifier and cellular choice; background sessions by default
    /// (tests use ordinary ones: a background session doesn't run in a test process).
    public init(identifier: String = BackgroundModelFetcher.identifier, base: URL = URL(string: "https://huggingface.co")!,
                configuration: ((_ identifier: String, _ cellular: Bool) -> URLSessionConfiguration)? = nil) {
        self.identifier = identifier
        self.base = base
        makeConfiguration = configuration ?? Self.background
        super.init()
    }

    /// The configuration Daybook's downloads use: not discretionary (the person asked), relaunching the
    /// app when they finish, and Wi‑Fi only unless `cellular`.
    public static func background(_ identifier: String, cellular: Bool) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.allowsExpensiveNetworkAccess = cellular
        configuration.allowsConstrainedNetworkAccess = cellular
        configuration.allowsCellularAccess = cellular
        return configuration
    }

    /// A file's address: the repository at the artifact's commit.
    public static func url(for file: ModelFile, in artifact: ModelArtifact, base: URL) -> URL {
        var url = base
        for part in artifact.repository.split(separator: "/") { url.appendPathComponent(String(part)) }
        url.appendPathComponent("resolve")
        url.appendPathComponent(artifact.revision)
        for part in file.path.split(separator: "/") { url.appendPathComponent(String(part)) }
        return url
    }

    // MARK: Fetching

    public func fetch(_ artifact: ModelArtifact, into directory: URL,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let total = Double(max(1, artifact.files.reduce(Int64(0)) { $0 + $1.size }))
        var needed: [(file: ModelFile, destination: URL)] = []
        var done: Int64 = 0
        for file in artifact.files {
            let destination = directory.appendingPathComponent(file.path)
            if Self.size(of: destination) == file.size { done += file.size; continue }
            needed.append((file, destination))
        }
        guard !needed.isEmpty else { progress(1); return directory }
        let complete = done
        let paths = Set(needed.map(\.destination.path))
        let report = { [weak self] in
            guard let self else { return }
            let bytes = self.lock.withLock { paths.reduce(Int64(0)) { $0 + (self.written[$1] ?? 0) } }
            progress(min(1, Double(complete + bytes) / total))
        }
        let handler = UUID()
        lock.withLock { progressHandlers[handler] = report }
        defer { _ = lock.withLock { progressHandlers.removeValue(forKey: handler) } }
        report()

        let running = await tasksByDestination()
        let mine = Tasks()
        let session = session(cellular: allowsCellular)
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (file, destination) in needed {
                    try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let task: URLSessionDownloadTask
                    if let existing = running[destination.path] {
                        task = existing  // reconnected after a relaunch: wait for it
                    } else {
                        task = makeTask(for: Self.url(for: file, in: artifact, base: base), destination: destination, in: session)
                    }
                    mine.add(task)
                    group.addTask { try await self.arrival(of: destination, size: file.size, starting: task) }
                }
                do {
                    try await group.waitForAll()
                } catch {
                    // One file failed: the others stop too, keeping what they fetched, so this returns now.
                    mine.stop()
                    throw error
                }
            }
        } onCancel: {
            mine.stop()
        }
        try Task.checkCancellation()
        progress(1)
        return directory
    }

    /// A task for `url` landing at `destination`, continuing from resume data an earlier attempt left.
    private func makeTask(for url: URL, destination: URL, in session: URLSession) -> URLSessionDownloadTask {
        let resume = Self.resumeURL(destination)
        let task: URLSessionDownloadTask
        if let data = try? Data(contentsOf: resume) {
            try? FileManager.default.removeItem(at: resume)
            task = session.downloadTask(withResumeData: data)
        } else {
            task = session.downloadTask(with: url)
        }
        task.taskDescription = destination.path
        return task
    }

    /// Waits until `destination` holds the whole file, starting `task` if it isn't running yet.
    private func arrival(of destination: URL, size: Int64, starting task: URLSessionDownloadTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let arrived = lock.withLock { () -> Bool in
                // The delegate moves a file into place before it looks for who's waiting, so it's either there or we are.
                if Self.size(of: destination) == size { return true }
                waiting[destination.path, default: []].append(continuation)
                return false
            }
            if arrived { continuation.resume() } else if task.state == .suspended { task.resume() }
        }
    }

    // MARK: Sessions and relaunches

    private func session(cellular: Bool) -> URLSession {
        lock.withLock {
            if let session = sessions[cellular] { return session }
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: makeConfiguration(sessionIdentifier(cellular), cellular), delegate: self, delegateQueue: queue)
            sessions[cellular] = session
            return session
        }
    }

    private func sessionIdentifier(_ cellular: Bool) -> String { identifier + (cellular ? ".any" : ".wifi") }

    /// Every download task either session is running, by the file it's for.
    private func tasksByDestination() async -> [String: URLSessionDownloadTask] {
        var tasks: [String: URLSessionDownloadTask] = [:]
        for cellular in [false, true] {
            for task in await session(cellular: cellular).allTasks {
                guard let download = task as? URLSessionDownloadTask, let path = download.taskDescription,
                      download.state == .running || download.state == .suspended else { continue }
                tasks[path] = download
            }
        }
        return tasks
    }

    /// The files downloading now, including ones a previous run started: the sessions are made again,
    /// which reconnects their tasks.
    public func inFlight() async -> [URL] {
        // Making a background session talks to the system's download process: never on the main thread.
        await Task.detached(priority: .utility) {
            await self.tasksByDestination().keys.map { URL(fileURLWithPath: $0) }.sorted { $0.path < $1.path }
        }.value
    }

    /// iOS relaunched the app for a session's events (`application(_:handleEventsForBackgroundURLSession:
    /// completionHandler:)`): makes that session again so they're delivered, and calls `completion`
    /// once they have been. False when the session isn't this fetcher's.
    @discardableResult
    public func handleEvents(for identifier: String, completion: @escaping () -> Void) -> Bool {
        let cellular: Bool
        switch identifier {
        case sessionIdentifier(false): cellular = false
        case sessionIdentifier(true): cellular = true
        default: return false
        }
        lock.withLock { finishedEvents[identifier] = completion }
        _ = session(cellular: cellular)
        return true
    }

    // MARK: URLSessionDownloadDelegate

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let path = downloadTask.taskDescription else { return }
        let handlers = lock.withLock { () -> [() -> Void] in
            written[path] = totalBytesWritten
            return Array(progressHandlers.values)
        }
        for handler in handlers { handler() }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let path = downloadTask.taskDescription else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else {
            lock.withLock { failures[path] = Failure.http(status) }
            return
        }
        // The file must leave `location` before this returns.
        let destination = URL(fileURLWithPath: path)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            lock.withLock { failures[path] = error }
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let path = task.taskDescription else { return }
        if let error = error as NSError?, let data = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            try? data.write(to: Self.resumeURL(URL(fileURLWithPath: path)), options: .atomic)
        }
        let (continuations, failure) = lock.withLock { () -> ([CheckedContinuation<Void, Error>], Error?) in
            written[path] = nil
            return (waiting.removeValue(forKey: path) ?? [], failures.removeValue(forKey: path))
        }
        let outcome: Error? = failure ?? error.map { ($0 as? URLError)?.code == .cancelled ? CancellationError() : $0 }
        for continuation in continuations {
            if let outcome { continuation.resume(throwing: outcome) } else { continuation.resume() }
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier,
              let completion = lock.withLock({ finishedEvents.removeValue(forKey: identifier) }) else { return }
        DispatchQueue.main.async { completion() }
    }

    /// One fetch's tasks, stopped together (keeping their resume data) when it's cancelled or fails.
    private final class Tasks: @unchecked Sendable {
        private let lock = NSLock()
        private var tasks: [URLSessionDownloadTask] = []
        private var stopped = false

        func add(_ task: URLSessionDownloadTask) {
            let stop = lock.withLock { () -> Bool in tasks.append(task); return stopped }
            if stop { Self.stop(task) }
        }

        func stop() {
            let all = lock.withLock { () -> [URLSessionDownloadTask] in stopped = true; return tasks }
            for task in all where task.state == .running || task.state == .suspended { Self.stop(task) }
        }

        /// Cancels, keeping what was fetched for the next attempt.
        private static func stop(_ task: URLSessionDownloadTask) {
            let path = task.taskDescription
            task.cancel { data in
                guard let data, let path else { return }
                try? data.write(to: BackgroundModelFetcher.resumeURL(URL(fileURLWithPath: path)), options: .atomic)
            }
        }
    }

    // MARK: Files

    static func resumeURL(_ destination: URL) -> URL { destination.appendingPathExtension("resume") }

    static func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }
}

extension ModelStore {
    /// The model (`family/variant`) a file downloading into the store's partial folder belongs to.
    public nonisolated func variantKey(downloading file: URL) -> String? {
        let partial = root.appendingPathComponent(".partial", isDirectory: true).standardizedFileURL.pathComponents
        let parts = file.standardizedFileURL.pathComponents
        guard parts.count > partial.count + 3, Array(parts.prefix(partial.count)) == partial else { return nil }
        return "\(parts[partial.count + 1])/\(parts[partial.count + 2])"
    }
}
