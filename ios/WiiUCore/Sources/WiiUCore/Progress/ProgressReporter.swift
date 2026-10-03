import Foundation

/// Receives progress callbacks from the downloader and decryptor.
/// Port of the Go `ProgressReporter` interface. All methods have no-op
/// defaults so callers only implement what they need.
public protocol ProgressReporter: AnyObject {
    /// Cancellation / pause state for the running operation.
    var controller: OperationController { get }

    func setGameTitle(_ title: String)
    func updateDownloadProgress(downloaded: Int64, filename: String)
    func updateDecryptionProgress(_ progress: Double)
    func setDownloadSize(_ size: Int64)
    func resetTotals()
    func markFileAsDone(_ filename: String)
    func setTotalDownloadedForFile(_ filename: String, downloaded: Int64)
    func setStartTime(_ date: Date)
}

public extension ProgressReporter {
    func setGameTitle(_ title: String) {}
    func updateDownloadProgress(downloaded: Int64, filename: String) {}
    func updateDecryptionProgress(_ progress: Double) {}
    func setDownloadSize(_ size: Int64) {}
    func resetTotals() {}
    func markFileAsDone(_ filename: String) {}
    func setTotalDownloadedForFile(_ filename: String, downloaded: Int64) {}
    func setStartTime(_ date: Date) {}

    /// True when cancellation was requested.
    var isCancelled: Bool { controller.isCancelled }
}

/// A reporter that discards every callback. Useful for probing a title's TMD,
/// size, or file list without touching the UI.
public final class NullProgressReporter: ProgressReporter {
    public let controller = OperationController()
    public init() {}
}
