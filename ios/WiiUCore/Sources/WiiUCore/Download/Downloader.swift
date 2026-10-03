import Foundation

// MARK: - Constants
// Port of the constants at the top of `downloader.go`.

private let maxRetries = 5
private let retryDelay: TimeInterval = 5
/// Progress callbacks are throttled to this interval (Go's `WRITER_PROGRESS_FLUSH_INTERVAL`).
let writerProgressFlushInterval: TimeInterval = 0.1

// MARK: - Public downloader

/// Synchronous, resumable, streaming HTTP downloader.
///
/// Port of `downloadFileWithOptions` in `downloader.go`. The API blocks the
/// calling thread until the transfer finishes, mirroring the Go implementation
/// rather than exposing Swift concurrency.
///
/// Unlike Go's `net/http`, `URLSession` streams through a delegate. A fresh
/// session is created per download (sharing the injected client's
/// configuration) because a session with a data delegate cannot be the shared
/// one. The 30-second inactivity watchdog is delegated to
/// `timeoutIntervalForRequest`, which resets on every received packet exactly
/// like Go's `watchdogReader`.
public final class Downloader {
    public let client: URLSession
    public let timeout: TimeInterval

    public init(client: URLSession = .shared, timeout: TimeInterval = 30) {
        self.client = client
        self.timeout = timeout
    }

    public func download(
        from url: URL,
        to destination: URL,
        options: DownloadOptions = DownloadOptions(),
        reporter: ProgressReporter?
    ) throws {
        let operation = DownloadOperation(
            url: url,
            destination: destination,
            options: options,
            reporter: reporter,
            timeout: timeout,
            baseSession: client
        )
        try operation.run()
    }
}

// MARK: - Writer progress

/// Counts bytes flowing to disk and flushes throttled progress updates.
/// Port of `WriterProgress` in `writerProgress.go`.
final class WriterProgress {
    private let sink: ([UInt8]) throws -> Int
    private let reporter: ProgressReporter?
    private let controller: OperationController?
    private let filename: String
    private var pending: Int64 = 0
    private var lastFlush = Date()

    init(
        sink: @escaping ([UInt8]) throws -> Int,
        reporter: ProgressReporter?,
        controller: OperationController?,
        filename: String
    ) {
        self.sink = sink
        self.reporter = reporter
        self.controller = controller
        self.filename = filename
    }

    func write(_ bytes: [UInt8]) throws -> Int {
        if let controller {
            try controller.waitIfPaused()
            if controller.isCancelled {
                throw WiiUError.cancelled
            }
        }
        let written = try sink(bytes)
        pending += Int64(written)
        if Date().timeIntervalSince(lastFlush) >= writerProgressFlushInterval {
            flush()
        }
        return written
    }

    func close() {
        flush()
    }

    private func flush() {
        if pending > 0 {
            reporter?.updateDownloadProgress(downloaded: pending, filename: filename)
            pending = 0
        }
        lastFlush = Date()
    }
}

// MARK: - Download operation

/// Drives the per-attempt request/response state machine. All delegate
/// callbacks run serially on the session's delegate queue; the caller blocks on
/// a semaphore until the whole operation (including retries) completes.
private final class DownloadOperation: NSObject, URLSessionDataDelegate {
    private let url: URL
    private let destination: URL
    private let options: DownloadOptions
    private let reporter: ProgressReporter?
    private let timeout: TimeInterval
    private let baseSession: URLSession

    private let baseName: String
    private let partPath: URL
    private let statePath: URL

    private var session: URLSession!
    private let finished = DispatchSemaphore(value: 0)

    // Attempt lifecycle.
    private var attempt = 0
    private var state: DownloadState?
    private var existingOffset: Int64 = 0
    private var expectedSize: Int64 = 0
    private var completeError: Error?
    private var needsCleanup = false

    // Response metadata.
    private var responseStatus = 0
    private var responseContentLength: Int64 = -1
    private var responseLastModified: String?
    private var responseETag: String?
    private var responseRangeStart: Int64?
    private var responseHasContentRange = false

    // Body writers.
    private var fileHandle: FileHandle?
    private var stateWriter: ResumeStateWriter?
    private var writerProgress: WriterProgress?

    init(
        url: URL,
        destination: URL,
        options: DownloadOptions,
        reporter: ProgressReporter?,
        timeout: TimeInterval,
        baseSession: URLSession
    ) {
        self.url = url
        self.destination = destination
        self.options = options
        self.reporter = reporter
        self.timeout = timeout
        self.baseSession = baseSession
        self.baseName = destination.lastPathComponent
        self.partPath = partPathFor(destination)
        self.statePath = statePathFor(destination)
        super.init()
    }

    func run() throws {
        let configuration = baseSession.configuration
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = .greatestFiniteMagnitude
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        // A finished, still-valid destination short-circuits the download.
        if FileManager.default.fileExists(atPath: destination.path) {
            if (try? validateExistingDownload()) != nil {
                reporter?.setTotalDownloadedForFile(baseName, downloaded: options.expectedSize)
                reporter?.markFileAsDone(baseName)
                return
            }
            try FileManager.default.removeItem(at: destination)
        }

        while true {
            try waitUntilResumed()
            attempt += 1
            try runAttempt()

            var failure = completeError
            if failure == nil {
                do {
                    try finishSuccessfulDownload()
                    return
                } catch {
                    failure = error
                }
            }

            if reporter?.isCancelled == true { throw WiiUError.cancelled }
            if let error = failure as? WiiUError, case .cancelled = error {
                throw WiiUError.cancelled
            }
            if needsCleanup {
                try cleanupPartialDownload(destination)
            }
            guard options.doRetries, attempt < maxRetries else {
                throw failure ?? WiiUError.download("download failed")
            }
            guard sleepInterruptible(retryDelay) else { throw WiiUError.cancelled }
        }
    }

    // MARK: Attempts

    private func runAttempt() throws {
        completeError = nil
        needsCleanup = false
        resetResponseState()

        let prepared = try prepareDownloadState(
            dstPath: destination,
            downloadURL: url.absoluteString,
            expectedSize: options.expectedSize,
            allowResume: options.allowResume,
            segmentSize: options.segmentSize
        )
        state = prepared.state
        existingOffset = prepared.verifiedOffset

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if !options.userAgent.isEmpty {
            request.setValue(options.userAgent, forHTTPHeaderField: "User-Agent")
        }
        if existingOffset > 0 {
            request.setValue("bytes=\(existingOffset)-", forHTTPHeaderField: "Range")
        }

        let task = session.dataTask(with: request)
        task.resume()
        finished.wait()
    }

    private func resetResponseState() {
        responseStatus = 0
        responseContentLength = -1
        responseLastModified = nil
        responseETag = nil
        responseRangeStart = nil
        responseHasContentRange = false
        fileHandle = nil
        stateWriter = nil
        writerProgress = nil
    }

    private func validateExistingDownload() throws {
        try finalFileSizeMatches(destination, expectedSize: options.expectedSize)
        if let validate = options.validate {
            try validate(destination)
        }
    }

    /// Verifies the finished `.part` file, then atomically promotes it. Port of
    /// the tail of `downloadFileWithOptions`.
    private func finishSuccessfulDownload() throws {
        do {
            try finalFileSizeMatches(partPath, expectedSize: expectedSize)
            if let validate = options.validate {
                try validate(partPath)
            }
        } catch {
            try? cleanupPartialDownload(destination)
            throw error
        }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: partPath, to: destination)
        if fileManager.fileExists(atPath: statePath.path) {
            try? fileManager.removeItem(at: statePath)
        }
        reporter?.markFileAsDone(baseName)
    }

    // MARK: Response handling

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completeError = WiiUError.download("missing HTTP response")
            completionHandler(.cancel)
            return
        }

        responseStatus = http.statusCode
        responseContentLength = http.expectedContentLength
        responseLastModified = http.value(forHTTPHeaderField: "Last-Modified")
        responseETag = http.value(forHTTPHeaderField: "ETag")
        if let raw = http.value(forHTTPHeaderField: "Content-Range"), let start = parseContentRangeStart(raw) {
            responseRangeStart = start
            responseHasContentRange = true
        }

        do {
            try prepareBody()
            completionHandler(.allow)
        } catch {
            if completeError == nil { completeError = error }
            completionHandler(.cancel)
        }
    }

    /// Validates the response against the resume state and opens the `.part`
    /// file for streaming. Port of the middle of `downloadFileWithOptions`.
    private func prepareBody() throws {
        if existingOffset > 0, responseStatus == 206 {
            guard responseHasContentRange, responseRangeStart == existingOffset else {
                needsCleanup = true
                throw WiiUError.download("download resume failed: unexpected content-range")
            }
        }

        let acceptsRangedBodyWithStatusOK = existingOffset > 0
            && responseStatus == 200
            && options.expectedSize > 0
            && responseContentLength >= 0
            && options.expectedSize - existingOffset == responseContentLength

        if !acceptsRangedBodyWithStatusOK, existingOffset > 0, responseStatus == 200 {
            // The server ignored our Range header; start over.
            try cleanupPartialDownload(destination)
            let prepared = try prepareDownloadState(
                dstPath: destination,
                downloadURL: url.absoluteString,
                expectedSize: options.expectedSize,
                allowResume: options.allowResume,
                segmentSize: options.segmentSize
            )
            state = prepared.state
            existingOffset = prepared.verifiedOffset
        }

        guard responseStatus == 200 || responseStatus == 206 else {
            throw WiiUError.download("download error after \(attempt) attempts, status code: \(responseStatus)")
        }

        expectedSize = responseExpectedSize()

        if var current = state {
            if current.expectedSize > 0, expectedSize > 0, current.expectedSize != expectedSize {
                needsCleanup = true
                throw WiiUError.download("download size mismatch: expected \(current.expectedSize), got \(expectedSize)")
            }
            if expectedSize > 0 {
                current.expectedSize = expectedSize
            }
            if let lastModified = responseLastModified, !lastModified.isEmpty {
                if let previous = current.lastModified, !previous.isEmpty, previous != lastModified, existingOffset > 0 {
                    needsCleanup = true
                    throw WiiUError.download("download source changed while resuming")
                }
                current.lastModified = lastModified
            }
            if let etag = responseETag, !etag.isEmpty {
                if let previous = current.etag, !previous.isEmpty, previous != etag, existingOffset > 0 {
                    needsCleanup = true
                    throw WiiUError.download("download source changed while resuming")
                }
                current.etag = etag
            }
            state = current
            try saveDownloadState(path: statePath, state: current)
        }

        FileManager.default.createFile(atPath: partPath.path, contents: nil)
        let handle = try FileHandle(forUpdating: partPath)
        if existingOffset == 0 {
            try handle.truncate(atOffset: 0)
        }
        try handle.seek(toOffset: UInt64(existingOffset))
        fileHandle = handle

        let sink: ([UInt8]) throws -> Int
        if let current = state {
            let writer = try ResumeStateWriter(file: handle, state: current, statePath: statePath)
            stateWriter = writer
            sink = { try writer.write($0) }
        } else {
            sink = { bytes in
                try handle.write(contentsOf: Data(bytes))
                return bytes.count
            }
        }

        writerProgress = WriterProgress(
            sink: sink,
            reporter: reporter,
            controller: reporter?.controller,
            filename: baseName
        )

        reporter?.setTotalDownloadedForFile(baseName, downloaded: existingOffset)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            _ = try writerProgress?.write([UInt8](data))
        } catch {
            completeError = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        writerProgress?.close()

        var finalizeError: Error?
        if let stateWriter {
            do { try stateWriter.finalize() } catch { finalizeError = error }
        }
        try? fileHandle?.close()
        fileHandle = nil
        stateWriter = nil
        writerProgress = nil

        if completeError == nil {
            if let finalizeError {
                completeError = finalizeError
            } else if let error {
                completeError = reporter?.isCancelled == true ? WiiUError.cancelled : error
            }
        }

        finished.signal()
    }

    // MARK: Helpers

    private func responseExpectedSize() -> Int64 {
        if options.expectedSize > 0 { return options.expectedSize }
        if responseContentLength >= 0 {
            if existingOffset > 0, responseStatus == 206 {
                return existingOffset + responseContentLength
            }
            return responseContentLength
        }
        return 0
    }

    /// Extracts the first byte of a `Content-Range: bytes START-END/TOTAL`
    /// header. Returns nil when the header is malformed.
    private func parseContentRangeStart(_ value: String) -> Int64? {
        let parts = value.split(separator: " ")
        guard parts.count == 2, parts[0] == "bytes" else { return nil }
        let rangeAndTotal = parts[1].split(separator: "/")
        guard rangeAndTotal.count == 2 else { return nil }
        let bounds = rangeAndTotal[0].split(separator: "-")
        guard bounds.count == 2, let start = Int64(bounds[0]) else { return nil }
        return start
    }

    private func waitUntilResumed() throws {
        if let reporter {
            try reporter.controller.waitIfPaused()
        }
        if reporter?.isCancelled == true {
            throw WiiUError.cancelled
        }
    }

    private func sleepInterruptible(_ interval: TimeInterval) -> Bool {
        guard let reporter else {
            Thread.sleep(forTimeInterval: interval)
            return true
        }
        return reporter.controller.sleep(interval)
    }
}
