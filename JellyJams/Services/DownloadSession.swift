import Foundation

/// A URLSession that reports download throughput as data lands, delivering
/// finished files through async/await.
///
/// `URLSession`'s async download conveniences report progress to no delegate
/// — neither the session's own nor the one passed to the call — so this
/// session drives plain download tasks and bridges them itself:
/// ``download(from:)`` parks a continuation the delegate resumes, the byte
/// counts each task writes feed ``bytesPerSecond(asOf:)``, and a finished
/// file is moved to a name of ours before the system reclaims its temp
/// location. The transfer itself behaves as the convenience would: an error
/// page downloads like any other body and stays the caller's to reject.
/// Cancelling the calling task cancels the transfer.
///
/// On iOS the app's session is a *background* session
/// (``init(backgroundIdentifier:)``): transfers keep running while the app is
/// suspended, and the system completes them even if the app dies, delivering
/// the files when a session with the same identifier is next created. A
/// completion that arrives with no parked continuation — one the system kept
/// across a process death — goes to the ``setOrphanedTransferHandler(_:)``
/// instead of being dropped.
///
/// The delegate is a separate object from this owner, because `URLSession`
/// retains its delegate — an owner holding both sides of that would never
/// deallocate.
final class DownloadSession: @unchecked Sendable {
    /// The identifier the app's iOS transfers run under. Recreating a session
    /// with it is what reconnects to downloads the system kept running, and a
    /// second live session on the same identifier is undefined behavior — so
    /// exactly one session uses it, owned by the app's single
    /// ``DownloadStore``.
    static let backgroundIdentifier = "net.aseriesoftubes.JellyJams.downloads"

    private let session: URLSession
    private let bridge: Bridge

    /// Builds the session from `configuration`, which is where a stubbed
    /// protocol or a shared default is carried in.
    init(configuration: URLSessionConfiguration) {
        let bridge = Bridge()
        self.bridge = bridge
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

    /// Holds the system completion handler from
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
    /// until the session reports it has finished delivering events.
    private static let systemCompletion = SystemCompletionBox()

    static func storeBackgroundEventsCompletionHandler(_ handler: @escaping () -> Void) {
        systemCompletion.store(handler)
    }
    #endif

    deinit {
        session.finishTasksAndInvalidate()
    }

    /// Downloads `url`, reporting its bytes to the throughput estimate.
    /// Cancelling the calling task cancels the transfer, which surfaces as
    /// `URLError.cancelled`.
    func download(from url: URL) async throws -> (URL, URLResponse) {
        let task = session.downloadTask(with: url)
        let taskID = task.taskIdentifier
        bridge.register(task)
        defer { bridge.unregister(taskID) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(URL, URLResponse), any Error>) in
                bridge.awaitCompletion(of: task, continuation: continuation)
                task.resume()
            }
        } onCancel: {
            bridge.cancelTask(taskID)
        }
    }

    /// Where completions nobody is waiting for go — files the system finished
    /// across a process death. Called on the session's own queue with the
    /// original request URL, the downloaded file when one landed (parked under
    /// a temporary name of ours; the handler must move or delete it), and the
    /// HTTP status when the response carried one.
    func setOrphanedTransferHandler(_ handler: @escaping @Sendable (URL?, URL?, Int?) -> Void) {
        bridge.setOrphanedTransferHandler(handler)
    }

    /// Bytes per second across recent downloads, or `nil` when nothing has
    /// landed within the tracker's window.
    func bytesPerSecond(asOf now: Date = Date()) -> Double? {
        bridge.tracker.bytesPerSecond(asOf: now)
    }

    /// Receives task events on the session's queue and bridges them to
    /// ``DownloadSession/download(from:)``'s continuations, one per task,
    /// keyed by task identifier.
    private final class Bridge: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let tracker = DownloadSpeedTracker()
        private let lock = NSLock()
        private var continuations: [Int: CheckedContinuation<(URL, URLResponse), any Error>] = [:]
        private var tasks: [Int: URLSessionTask] = [:]
        private var orphanedTransferHandler: (@Sendable (URL?, URL?, Int?) -> Void)?

        func register(_ task: URLSessionTask) {
            lock.lock()
            tasks[task.taskIdentifier] = task
            lock.unlock()
        }

        func unregister(_ taskID: Int) {
            lock.lock()
            tasks[taskID] = nil
            lock.unlock()
        }

        func cancelTask(_ taskID: Int) {
            lock.lock()
            let task = tasks[taskID]
            lock.unlock()
            task?.cancel()
        }

        func setOrphanedTransferHandler(_ handler: @escaping @Sendable (URL?, URL?, Int?) -> Void) {
            lock.lock()
            orphanedTransferHandler = handler
            lock.unlock()
        }

        func awaitCompletion(
            of task: URLSessionTask,
            continuation: CheckedContinuation<(URL, URLResponse), any Error>
        ) {
            lock.lock()
            continuations[task.taskIdentifier] = continuation
            lock.unlock()
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
            // under a name of ours first.
            let parked = FileManager.default.temporaryDirectory
                .appending(path: "JellyJams-\(UUID().uuidString)")
            do {
                try FileManager.default.moveItem(at: location, to: parked)
                let response = downloadTask.response ?? URLResponse()
                if !resume(downloadTask, returning: (parked, response)) {
                    notifyOrphaned(downloadTask, file: parked)
                }
            } catch {
                if !resume(downloadTask, throwing: error) {
                    notifyOrphaned(downloadTask, file: nil)
                }
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            // Success arrives through didFinishDownloadingTo; an error here
            // is the task's own.
            if let error, !resume(task, throwing: error) {
                notifyOrphaned(task, file: nil)
            }
        }

        #if os(iOS)
        func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
            DownloadSession.systemCompletion.takeAndCall()
        }
        #endif

        private func resume(_ task: URLSessionTask, returning result: (URL, URLResponse)) -> Bool {
            guard let continuation = takeContinuation(for: task) else { return false }
            continuation.resume(returning: result)
            return true
        }

        private func resume(_ task: URLSessionTask, throwing error: any Error) -> Bool {
            guard let continuation = takeContinuation(for: task) else { return false }
            continuation.resume(throwing: error)
            return true
        }

        private func notifyOrphaned(_ task: URLSessionTask, file: URL?) {
            lock.lock()
            let handler = orphanedTransferHandler
            lock.unlock()
            handler?(
                task.originalRequest?.url,
                file,
                (task.response as? HTTPURLResponse)?.statusCode
            )
        }

        private func takeContinuation(for task: URLSessionTask) -> CheckedContinuation<(URL, URLResponse), any Error>? {
            lock.lock()
            defer { lock.unlock() }
            return continuations.removeValue(forKey: task.taskIdentifier)
        }
    }
}

#if os(iOS)
/// A thread-safe box for one held closure: the app delegate stores the
/// system's handler on the main thread, the session's queue takes and calls
/// it when event delivery finishes.
private final class SystemCompletionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (() -> Void)?

    func store(_ handler: @escaping () -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func takeAndCall() {
        lock.lock()
        let handler = self.handler
        self.handler = nil
        lock.unlock()
        handler?()
    }
}
#endif
