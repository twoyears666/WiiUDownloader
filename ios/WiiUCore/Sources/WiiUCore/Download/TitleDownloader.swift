import Foundation
import Mobile

/// Identifies what a completed download produced, including the concrete title
/// version resolved from the TMD (useful when the caller asked for "latest").
public struct DownloadedTitleInfo: Sendable {
    public let titleID: UInt64
    public let titleVersion: UInt16
    public let outputDirectory: URL

    public init(titleID: UInt64, titleVersion: UInt16, outputDirectory: URL) {
        self.titleID = titleID
        self.titleVersion = titleVersion
        self.outputDirectory = outputDirectory
    }
}

/// Downloads titles through the upstream Go implementation, exposed to iOS via
/// gomobile. The old pure-Swift port lives in git history; this façade keeps the
/// same public surface so the app and view models are unchanged.
public enum TitleDownloader {
    /// Downloads a title and, unless disabled, decrypts it.
    ///
    /// - Parameters:
    ///   - titleID: 16-digit hex title ID, e.g. `"00050000101C9300"`.
    ///   - outputDirectory: Folder that receives the title's files.
    ///   - version: Pinned title version, or `versionLatest` for the newest.
    ///   - doDecryption: Decrypt after downloading.
    ///   - deleteEncryptedContents: Remove encrypted `.app`/`.h3` files once
    ///     decrypted.
    ///   - reporter: Receives progress and cancellation/pause state.
    /// - Returns: The resolved title ID, version and output folder.
    @discardableResult
    public static func downloadTitle(
        titleID: String,
        outputDirectory: URL,
        version: Int = versionLatest,
        doDecryption: Bool = true,
        deleteEncryptedContents: Bool = true,
        reporter: ProgressReporter? = nil
    ) throws -> DownloadedTitleInfo {
        let tid = try GoBackend.parseTitleID(titleID)
        let resolvedVersion = GoBackend.normalize(version: version)

        reporter?.resetTotals()
        let entry = titleEntry(forTitleID: tid)
        let displayName = (entry?.name).flatMap { $0.isEmpty ? nil : $0 } ?? titleID
        reporter?.setGameTitle(displayName)

        // Resolve the concrete header first: when the caller asked for the
        // latest version we still report the version the CDN served.
        var infoError: NSError?
        guard let info = MobileFetchTitleInfo(titleID, resolvedVersion, &infoError) else {
            throw GoBackend.map(infoError)
        }

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let bridge = GoReporterBridge(reporter: reporter)
        var downloadError: NSError?
        let ok = MobileDownloadTitle(
            titleID,
            outputDirectory.path,
            resolvedVersion,
            doDecryption,
            deleteEncryptedContents,
            "",
            bridge,
            &downloadError
        )

        // Go may report cancellation as a nil error, so check the controller.
        if reporter?.controller.isCancelled == true { throw WiiUError.cancelled }
        if !ok { throw GoBackend.map(downloadError) }

        return DownloadedTitleInfo(
            titleID: UInt64(bitPattern: info.titleID),
            titleVersion: UInt16(truncatingIfNeeded: info.titleVersion),
            outputDirectory: outputDirectory
        )
    }

    /// Removes the encrypted artifacts so only decrypted output remains. Port of
    /// `doDeleteEncryptedContents` in `utils.go`.
    public static func deleteEncryptedContents(at path: URL) throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: path,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory { continue }

            let name = entry.lastPathComponent
            if name.hasSuffix(".app") || name.hasSuffix(".h3")
                || name == "title.tmd" || name == "title.tik" || name == "title.cert" {
                try FileManager.default.removeItem(at: entry)
            }
        }
    }
}
