import Foundation
import SwiftUI
import WiiUCore

/// One queued title download. Owns the background worker and reflects the
/// core's progress callbacks onto the main actor.
@MainActor
final class DownloadTask: ObservableObject, Identifiable {
    enum Status: Equatable {
        case queued
        case running
        case paused
        case finished
        case failed
        case cancelled

        var label: String {
            switch self {
            case .queued: return "Queued"
            case .running: return "Downloading"
            case .paused: return "Paused"
            case .finished: return "Finished"
            case .failed: return "Failed"
            case .cancelled: return "Cancelled"
            }
        }

        var isActive: Bool {
            self == .queued || self == .running || self == .paused
        }
    }

    let id = UUID()
    let titleID: String
    let name: String
    let outputDirectory: URL
    let version: Int
    let decrypt: Bool
    let deleteEncrypted: Bool
    let reporter: TaskProgressReporter

    @Published var status: Status = .queued
    @Published var downloaded: Int64 = 0
    @Published var total: Int64 = 0
    @Published var message = ""
    @Published var currentFile = ""

    private var baselines: [String: Int64] = [:]
    private var startedAt: Date?
    private var worker: DispatchWorkItem?

    init(
        titleID: String,
        name: String,
        outputDirectory: URL,
        version: Int,
        decrypt: Bool,
        deleteEncrypted: Bool
    ) {
        self.titleID = titleID
        self.name = name
        self.outputDirectory = outputDirectory
        self.version = version
        self.decrypt = decrypt
        self.deleteEncrypted = deleteEncrypted
        self.reporter = TaskProgressReporter()
        self.reporter.task = self
    }

    var progress: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(downloaded) / Double(total))
    }

    var speed: Double {
        guard let startedAt else { return 0 }
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed > 0.5 else { return 0 }
        return Double(downloaded) / elapsed
    }

    // MARK: Control

    func start() {
        status = .running
        startedAt = Date()
        message = ""

        // Snapshot everything the worker needs so it never touches this actor.
        let titleID = self.titleID
        let outputDirectory = self.outputDirectory
        let version = self.version
        let decrypt = self.decrypt
        let deleteEncrypted = self.deleteEncrypted
        let reporter = self.reporter

        let work = DispatchWorkItem { [weak self] in
            do {
                try TitleDownloader.downloadTitle(
                    titleID: titleID,
                    outputDirectory: outputDirectory,
                    version: version,
                    doDecryption: decrypt,
                    deleteEncryptedContents: deleteEncrypted,
                    reporter: reporter
                )
                DispatchQueue.main.async {
                    guard let self, self.status != .cancelled else { return }
                    self.status = .finished
                    self.message = "Finished"
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let error = error as? WiiUError, case .cancelled = error {
                        self.status = .cancelled
                        self.message = "Cancelled"
                    } else if self.reporter.controller.isCancelled {
                        self.status = .cancelled
                        self.message = "Cancelled"
                    } else {
                        self.status = .failed
                        self.message = "\(error)"
                    }
                }
            }
        }
        worker = work
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
    }

    func cancel() {
        reporter.controller.cancel()
    }

    func pause() {
        reporter.controller.pause()
        status = .paused
    }

    func resume() {
        reporter.controller.resume()
        status = .running
    }

    // MARK: Reporter callbacks (main actor)

    func setTotal(_ size: Int64) {
        total = size
    }

    func addDownloaded(_ delta: Int64) {
        downloaded += delta
    }

    func setFileBaseline(_ file: String, _ value: Int64) {
        let previous = baselines[file] ?? 0
        if value > previous {
            baselines[file] = value
            downloaded += value - previous
        }
    }

    func setCurrentFile(_ file: String) {
        if !file.isEmpty { currentFile = file }
    }

    func markStarted(at date: Date) {
        startedAt = date
    }
}

/// Bridges the core's synchronous `ProgressReporter` onto `DownloadTask` on the
/// main actor.
final class TaskProgressReporter: ProgressReporter, @unchecked Sendable {
    let controller = OperationController()

    @MainActor weak var task: DownloadTask?

    func setGameTitle(_ title: String) {}

    func updateDownloadProgress(downloaded: Int64, filename: String) {
        Task { @MainActor [weak self] in
            guard let self, let task = self.task else { return }
            task.addDownloaded(downloaded)
            task.setCurrentFile(filename)
        }
    }

    func updateDecryptionProgress(_ progress: Double) {
        Task { @MainActor [weak self] in
            guard let self, let task = self.task else { return }
            task.message = "Decrypting \(Int(progress * 100))%"
        }
    }

    func setDownloadSize(_ size: Int64) {
        Task { @MainActor [weak self] in
            self?.task?.setTotal(size)
        }
    }

    func resetTotals() {
        Task { @MainActor [weak self] in
            guard let task = self?.task else { return }
            task.setTotal(0)
            task.addDownloaded(-task.downloaded)
        }
    }

    func markFileAsDone(_ filename: String) {}

    func setTotalDownloadedForFile(_ filename: String, downloaded: Int64) {
        Task { @MainActor [weak self] in
            self?.task?.setFileBaseline(filename, downloaded)
        }
    }

    func setStartTime(_ date: Date) {
        Task { @MainActor [weak self] in
            self?.task?.markStarted(at: date)
        }
    }
}
