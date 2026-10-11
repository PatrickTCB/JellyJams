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
///
/// The delegate is a separate object from this owner, because `URLSession`
/// retains its delegate — an owner holding both sides of that would never
/// deallocate.
final class DownloadSession: @unchecked Sendable {
    private let session: URLSession
    private let bridge: Bridge

    /// Builds the session from `configuration`, which is where a stubbed
    /// protocol or a shared default is carried in.
    init(configuration: URLSessionConfiguration) {
        let bridge = Bridge()
        self.bridge = bridge
        self.session = URLSession(configuration: configuration, delegate: bridge, delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    /// Downloads `url`, reporting its bytes to the throughput estimate.
    func download(from url: URL) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.downloadTask(with: url)
            bridge.awaitCompletion(of: task, continuation: continuation)
            task.resume()
        }
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
                resume(downloadTask, returning: (parked, response))
            } catch {
                resume(downloadTask, throwing: error)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            // Success arrives through didFinishDownloadingTo; an error here
            // is the task's own.
            if let error { resume(task, throwing: error) }
        }

        private func resume(_ task: URLSessionTask, returning result: (URL, URLResponse)) {
            takeContinuation(for: task)?.resume(returning: result)
        }

        private func resume(_ task: URLSessionTask, throwing error: any Error) {
            takeContinuation(for: task)?.resume(throwing: error)
        }

        private func takeContinuation(for task: URLSessionTask) -> CheckedContinuation<(URL, URLResponse), any Error>? {
            lock.lock()
            defer { lock.unlock() }
            return continuations.removeValue(forKey: task.taskIdentifier)
        }
    }
}
