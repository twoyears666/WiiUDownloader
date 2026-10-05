import Foundation
import Mobile

/// Bridges the gomobile `MobileReporter` protocol back to the app's
/// `ProgressReporter`. Go calls these methods from its own goroutines; the
/// reporter implementations behind `ProgressReporter` are thread-safe.
///
/// Swift imports the ObjC protocol as `MobileReporterProtocol` because a class
/// of the same name (`MobileReporter`) exists in the generated framework.
final class GoReporterBridge: NSObject, MobileReporterProtocol {
    private let reporter: ProgressReporter?

    /// A nil reporter yields a no-op bridge, which lets callers that do not
    /// need progress (e.g. probing a file list) still satisfy the binding.
    init(reporter: ProgressReporter?) {
        self.reporter = reporter
    }

    func setGameTitle(_ title: String?) {
        reporter?.setGameTitle(title ?? "")
    }

    func updateDownloadProgress(_ downloaded: Int64, filename: String?) {
        reporter?.updateDownloadProgress(downloaded: downloaded, filename: filename ?? "")
    }

    func updateDecryptionProgress(_ progress: Double) {
        reporter?.updateDecryptionProgress(progress)
    }

    func setDownloadSize(_ size: Int64) {
        reporter?.setDownloadSize(size)
    }

    func resetTotals() {
        reporter?.resetTotals()
    }

    /// Swift renames the ObjC selector `markFileAsDone:` to `markFile(asDone:)`
    /// because the name reads like a prepositional phrase.
    func markFile(asDone filename: String?) {
        reporter?.markFileAsDone(filename ?? "")
    }

    func setTotalDownloadedForFile(_ filename: String?, downloaded: Int64) {
        reporter?.setTotalDownloadedForFile(filename ?? "", downloaded: downloaded)
    }

    func setStartTime(_ unixSeconds: Int64) {
        reporter?.setStartTime(Date(timeIntervalSince1970: TimeInterval(unixSeconds)))
    }

    func cancelled() -> Bool {
        reporter?.controller.isCancelled ?? false
    }

    /// Blocks while the operation is paused, returning false when it was
    /// cancelled instead of resumed. Implemented as a "pause-aware reporter"
    /// so Go's wait loops observe the pause state.
    func waitIfPaused() -> Bool {
        guard let reporter else { return true }
        do {
            try reporter.controller.waitIfPaused()
        } catch {
            return false
        }
        return !reporter.controller.isCancelled
    }
}

/// Helpers shared by the Go-backed façades.
enum GoBackend {
    /// Converts a hex title ID to the Go backend's representation.
    static func titleIDString(_ titleID: UInt64) -> String {
        String(format: "%016llx", titleID)
    }

    /// Parses a hex title ID, matching the error surfaced before the Go backend.
    static func parseTitleID(_ titleID: String) throws -> UInt64 {
        guard let value = UInt64(titleID, radix: 16) else {
            throw WiiUError.invalidTitleID(titleID)
        }
        return value
    }

    /// Treats version `0` as "latest". Version 0 does not exist on the CDN, and
    /// resolving it as a pinned version makes the backend request `tmd.0`.
    static func normalize(version: Int) -> Int {
        version == 0 ? versionLatest : version
    }

    /// Maps a gomobile `NSError` onto `WiiUError`. A nil error (Go reported a
    /// bare failure) becomes `fallback`.
    static func map(_ error: Error?, fallback: String = "unknown backend error") -> WiiUError {
        guard let error else { return .backend(fallback) }
        if let wiiu = error as? WiiUError {
            return wiiu
        }
        return .backend((error as NSError).localizedDescription)
    }

    /// Installs the app's title database in the Go backend so it can resolve
    /// title keys, names and versions. The backend reads JSON from a path, so
    /// the entries are written to a short-lived temporary file. Failures are
    /// ignored: the backend still downloads, only key/name lookups degrade.
    static func installTitleDatabase(_ entries: [TitleEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wiiu-titles-\(UUID().uuidString).json")
        guard (try? data.write(to: url)) != nil else { return }
        defer { try? FileManager.default.removeItem(at: url) }
        _ = MobileSetTitleDatabase(url.path, nil)
    }
}
