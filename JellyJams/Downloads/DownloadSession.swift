import Foundation
import Synchronization

/// A URLSession that reports download throughput as data lands, delivering
/// finished files through async/await.
///
/// `URLSession`'s async download conveniences report progress to no delegate
/// — neither the session's own nor the one passed to the call — so this
/// session drives plain download tasks and bridges them itself:
/// ``download(from:description:isolation:)`` parks a continuation the
/// delegate resumes, the byte counts each task writes feed
/// ``bytesPerSecond(asOf:)``, and a finished file is moved to a name of ours
/// before the system reclaims its temp location. The transfer itself behaves
/// as the convenience would: an error page downloads like any other body and
/// stays the caller's to reject. Cancelling the calling task cancels the
/// transfer.
///
/// On iOS the app's session is a *background* session
/// (``init(backgroundIdentifier:)``): transfers keep running while the app is
/// suspended, and the system completes them even if the app dies, delivering
/// the files when a session with the same identifier is next created. A
/// completion that arrives with no parked continuation — one the system kept
/// across a process death — goes to the ``setOrphanedTransferHandler(_:)``
/// instead of being dropped, and ``transfersStartedElsewhere()`` lists the
/// ones the system is still running.
///
/// The delegate is a separate object from this owner, because `URLSession`
/// retains its delegate — an owner holding both sides of that would never
/// deallocate.
final class DownloadSession: Sendable {
    /// The identifier the app's iOS transfers run under. Recreating a session
    /// with it is what reconnects to downloads the system kept running, and a
    /// second live session on the same identifier is undefined behavior — so
    /// exactly one session uses it, owned by the app's single
    /// ``DownloadStore``.
    static let backgroundIdentifier = "net.aseriesoftubes.JellyJams.downloads"

    private let session: URLSession
    private let bridge: Bridge
    /// The configuration the session was built from — kept so a test can
    /// assert the background wiring (`URLSession` copies it and does not
    /// expose the original).
    let configuration: URLSessionConfiguration

    /// Whether this is a background session: one the system runs transfers
    /// for on the app's behalf, even while the app is suspended.
    var isBackground: Bool { configuration.identifier != nil }

    /// Builds the session from `configuration`, which is where a stubbed
    /// protocol or a shared default is carried in.
    init(configuration: URLSessionConfiguration) {
        let bridge = Bridge()
        self.bridge = bridge
        self.configuration = configuration
        self.session = URLSession(configuration: configuration, delegate: bridge, delegateQueue: nil)
    }

    #if os(iOS)
    /// Builds a background session: transfers survive the app being suspended
    /// and the system finishes them even if it dies.
    convenience init(backgroundIdentifier: String) {
        let configuration = URLSessionConfiguration.background(withIdentifier: backgroundIdentifier)
        // Proceed right away rather than at the system's discretion, and wake
        // the app when transfers finish after a death, so the files are
        // adopted and the interrupted batch resumes.
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        self.init(configuration: configuration)
    }

    /// The system completion handler from
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`,
    /// held until the session reports it has finished delivering events. It
    /// arrives on the main thread and must be called there, so the main actor
    /// is all the protection it needs.
    @MainActor private static var systemCompletionHandler: (() -> Void)?

    @MainActor static func storeBackgroundEventsCompletionHandler(_ handler: @escaping () -> Void) {
        systemCompletionHandler = handler
    }

    @MainActor private static func callSystemCompletionHandler() {
        let handler = systemCompletionHandler
        systemCompletionHandler = nil
        handler?()
    }
    #endif

    deinit {
        session.finishTasksAndInvalidate()
    }

    /// Downloads `url`, reporting its bytes to the throughput estimate.
    /// Cancelling the calling task cancels the transfer, which surfaces as
    /// `URLError.cancelled`.
    ///
    /// The task carries `description`, which the system keeps with it —
    /// across a relaunch too — and hands back with whatever the task reports:
    /// what tells the owner which of its records a delivery nobody was
    /// waiting for, or a transfer still running at launch, belongs to.
    ///
    /// Runs on the caller's actor, so the delegate answers the caller there
    /// directly: the work that follows a delivery is queued on that actor the
    /// moment the file lands.
    func download(
        from url: URL,
        description: String,
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> (URL, URLResponse) {
        let task = session.downloadTask(with: url)
        task.taskDescription = description
        bridge.register(task)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                bridge.start(task, answering: continuation)
            }
        } onCancel: {
            bridge.cancel(task)
        }
    }

    /// The outcome of a transfer nobody in this process is waiting for — one
    /// the system finished, or failed, across a process death.
    struct OrphanedTransfer: Sendable {
        /// The description the transfer was started with; `nil` for one a
        /// build from before transfers carried descriptions started.
        let description: String?
        let requestURL: URL?
        /// The downloaded file, parked under a temporary name of ours — the
        /// handler must move or delete it — or `nil` when none landed.
        let file: URL?
        /// The HTTP status, when the response carried one.
        let statusCode: Int?
    }

    /// A transfer the session is running.
    struct RunningTransfer: Sendable {
        let description: String?
        let requestURL: URL?
    }

    /// Where completions nobody is waiting for go — files the system finished
    /// across a process death. Called on the session's own queue. Completions
    /// that arrived before the handler was set are handed to it straight away.
    func setOrphanedTransferHandler(_ handler: @escaping @Sendable (OrphanedTransfer) -> Void) {
        bridge.setOrphanedTransferHandler(handler)
    }

    /// What runs once the system has delivered every event it held for a
    /// background session — on the main thread, before the system's
    /// completion handler tells it the app may be suspended again.
    func setBackgroundEventsFinishedHandler(_ handler: @escaping @MainActor @Sendable () -> Void) {
        bridge.setEventsFinishedHandler(handler)
    }

    /// The transfers the session is running that this process didn't start —
    /// on iOS, those the system kept going for an earlier process.
    func transfersStartedElsewhere() async -> [RunningTransfer] {
        bridge.startedElsewhere(await session.allTasks).map(Self.running)
    }

    /// Cancels the transfers this process didn't start that `shouldCancel`
    /// picks: ones the owner no longer wants, whose deliveries it would only
    /// discard.
    func cancelTransfersStartedElsewhere(where shouldCancel: @escaping @Sendable (RunningTransfer) -> Bool) {
        Task {
            for task in bridge.startedElsewhere(await session.allTasks) where shouldCancel(Self.running(task)) {
                task.cancel()
            }
        }
    }

    private static func running(_ task: URLSessionTask) -> RunningTransfer {
        RunningTransfer(description: task.taskDescription, requestURL: task.originalRequest?.url)
    }

    /// Bytes per second across recent downloads, or `nil` when nothing has
    /// landed within the tracker's window.
    func bytesPerSecond(asOf now: Date = Date()) -> Double? {
        bridge.tracker.bytesPerSecond(asOf: now)
    }

    /// Receives task events on the session's queue and bridges them to
    /// ``DownloadSession/download(from:description:isolation:)``'s
    /// continuations, one per task, keyed by task identifier.
    private final class Bridge: NSObject, URLSessionDownloadDelegate, Sendable {
        let tracker = DownloadSpeedTracker()
        private let state = Mutex(State())

        private struct State {
            /// This process's transfers, by task identifier. A task with no
            /// entry was started by an earlier process, which is what makes
            /// its completion orphaned.
            var transfers: [Int: Transfer] = [:]
            var orphanedTransferHandler: (@Sendable (OrphanedTransfer) -> Void)?
            /// Orphaned completions that arrived before a handler was set:
            /// the system delivers them as soon as the session exists.
            var undeliveredOrphans: [OrphanedTransfer] = []
            var eventsFinishedHandler: (@MainActor @Sendable () -> Void)?
        }

        /// Where one of this process's transfers is up to.
        private enum Transfer {
            /// Created, with its caller still to park; `cancelled` once the
            /// caller has been cancelled in the meantime.
            case created(cancelled: Bool)
            /// Started, with its caller parked on the continuation.
            case running(CheckedContinuation<(URL, URLResponse), any Error>)
            /// The caller has been answered; anything more the task reports
            /// is dropped.
            case answered
        }

        /// Who a task's report is for.
        private enum Recipient {
            /// The caller parked on it, now answered by this report.
            case caller(CheckedContinuation<(URL, URLResponse), any Error>)
            /// Nobody in this process: an earlier one started the task.
            case orphan
            /// Nobody any more: the caller has had its answer.
            case nobody
        }

        /// Records a task this process created, before it can report
        /// anything — which is what keeps its reports from reading as
        /// orphaned.
        func register(_ task: URLSessionTask) {
            state.withLock { $0.transfers[task.taskIdentifier] = .created(cancelled: false) }
        }

        /// Parks the caller, then starts its task — or, when the caller was
        /// cancelled before it got here, cancels the task and answers the
        /// caller at once. Parking first guarantees the task's completion,
        /// however it ends, finds the caller to answer.
        func start(
            _ task: URLSessionTask,
            answering continuation: CheckedContinuation<(URL, URLResponse), any Error>
        ) {
            let id = task.taskIdentifier
            let startsNow = state.withLock { state in
                guard case .created(cancelled: false) = state.transfers[id] else {
                    // Cancelled first — or already over, the session gone.
                    if state.transfers[id] != nil { state.transfers[id] = .answered }
                    return false
                }
                state.transfers[id] = .running(continuation)
                return true
            }
            if startsNow {
                task.resume()
            } else {
                task.cancel()
                continuation.resume(throwing: URLError(.cancelled))
            }
        }

        /// The caller's cancellation. A task that hasn't started is only
        /// marked, and starting it cancels it, so the cancellation can't
        /// overtake the caller parking. A running task reports its
        /// cancellation through `didCompleteWithError`, which answers the
        /// caller.
        func cancel(_ task: URLSessionTask) {
            let id = task.taskIdentifier
            let isRunning = state.withLock { state in
                switch state.transfers[id] {
                case .created:
                    state.transfers[id] = .created(cancelled: true)
                    return false
                case .running:
                    return true
                case .answered, nil:
                    return false
                }
            }
            if isRunning { task.cancel() }
        }

        func setOrphanedTransferHandler(_ handler: @escaping @Sendable (OrphanedTransfer) -> Void) {
            let held = state.withLock { state in
                state.orphanedTransferHandler = handler
                let held = state.undeliveredOrphans
                state.undeliveredOrphans = []
                return held
            }
            for orphan in held {
                handler(orphan)
            }
        }

        func setEventsFinishedHandler(_ handler: @escaping @MainActor @Sendable () -> Void) {
            state.withLock { $0.eventsFinishedHandler = handler }
        }

        /// Those of `tasks` still running that this process didn't start.
        func startedElsewhere(_ tasks: [URLSessionTask]) -> [URLSessionTask] {
            let own = state.withLock { Set($0.transfers.keys) }
            return tasks.filter { task in
                !own.contains(task.taskIdentifier) && (task.state == .running || task.state == .suspended)
            }
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            tracker.record(bytes: Int(bytesWritten))
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            // The system reclaims the temp file when this returns, so park it
            // under a name of ours first — if anyone is going to take it.
            switch recipient(of: downloadTask, isLastReport: false) {
            case let .caller(continuation):
                do {
                    let parked = try park(location)
                    continuation.resume(returning: (parked, downloadTask.response ?? URLResponse()))
                } catch {
                    continuation.resume(throwing: error)
                }
            case .orphan:
                notifyOrphaned(downloadTask, file: try? park(location))
            case .nobody:
                break
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            // A task's last report, however it ended.
            switch recipient(of: task, isLastReport: true) {
            case let .caller(continuation):
                // Success answers the caller through didFinishDownloadingTo;
                // a caller still waiting here never got a file.
                continuation.resume(throwing: error ?? URLError(.unknown))
            case .orphan:
                if error != nil { notifyOrphaned(task, file: nil) }
            case .nobody:
                break
            }
        }

        #if os(iOS)
        func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
            let eventsFinished = state.withLock { $0.eventsFinishedHandler }
            // The system's handler came from UIKit, which requires it be
            // called on the main thread. Queued there, it also runs after the
            // filing of the files just delivered — their callers wait on the
            // main actor, and orphans are handed over on the main thread — so
            // what they filed is saved before the system is told it may
            // suspend the app.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    eventsFinished?()
                    DownloadSession.callSystemCompletionHandler()
                }
            }
        }
        #endif

        /// Who a report from `task` is for, taking the parked continuation so
        /// only one report ever answers the caller. The last report forgets
        /// the task.
        private func recipient(of task: URLSessionTask, isLastReport: Bool) -> Recipient {
            state.withLock { state in
                let id = task.taskIdentifier
                guard let transfer = state.transfers[id] else { return .orphan }
                state.transfers[id] = isLastReport ? nil : .answered
                guard case let .running(continuation) = transfer else { return .nobody }
                return .caller(continuation)
            }
        }

        /// Moves a delivered file out of the system's temp location to a name
        /// of ours.
        private func park(_ location: URL) throws -> URL {
            let parked = FileManager.default.temporaryDirectory
                .appending(path: "JellyJams-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: location, to: parked)
            return parked
        }

        private func notifyOrphaned(_ task: URLSessionTask, file: URL?) {
            let orphan = OrphanedTransfer(
                description: task.taskDescription,
                requestURL: task.originalRequest?.url,
                file: file,
                statusCode: (task.response as? HTTPURLResponse)?.statusCode
            )
            let handler = state.withLock { state in
                if state.orphanedTransferHandler == nil {
                    state.undeliveredOrphans.append(orphan)
                }
                return state.orphanedTransferHandler
            }
            handler?(orphan)
        }
    }
}
