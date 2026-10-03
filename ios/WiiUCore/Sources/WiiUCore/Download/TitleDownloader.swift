import Foundation

/// Maximum number of contents fetched concurrently (Go's `maxConcurrentDownloads`).
let maxConcurrentDownloads = 4

/// Orchestrates a full title download: TMD, ticket, certificate and every
/// content listed in the TMD, with optional decryption. Port of
/// `DownloadTitleContents` / `ensureTitleTicket` / `doDeleteEncryptedContents`.
public enum TitleDownloader {
    /// Downloads a title and, unless restricted to a content subset, decrypts
    /// it. Port of `DownloadTitleContents`.
    ///
    /// - Parameters:
    ///   - titleID: 16-digit hex title ID, e.g. `"00050000101C9300"`.
    ///   - outputDirectory: Folder that receives the title's files.
    ///   - version: Pinned title version, or `versionLatest` for the newest.
    ///   - doDecryption: Decrypt after downloading. Ignored when `contentIDs`
    ///     selects a subset, because decryption needs every content.
    ///   - deleteEncryptedContents: Remove encrypted `.app`/`.h3` files once
    ///     decrypted.
    ///   - decryptOutputDirectory: Parent directory for decrypted output. `nil`
    ///     decrypts in place.
    ///   - contentIDs: Restrict the download to these content IDs. `nil` or an
    ///     empty array downloads everything.
    ///   - client: Session whose configuration is copied for each transfer.
    ///   - reporter: Receives progress and cancellation/pause state.
    ///   - decryptor: Decryption backend.
    public static func downloadTitle(
        titleID: String,
        outputDirectory: URL,
        version: Int = versionLatest,
        doDecryption: Bool = true,
        deleteEncryptedContents: Bool = true,
        decryptOutputDirectory: URL? = nil,
        contentIDs: [UInt32]? = nil,
        client: URLSession = .shared,
        reporter: ProgressReporter? = nil,
        decryptor: ContentDecryptor = DefaultContentDecryptor()
    ) throws {
        let tid = try parseTitleID(titleID)
        let entry = titleEntry(forTitleID: tid)

        reporter?.resetTotals()
        let displayName = (entry?.name).flatMap { $0.isEmpty ? nil : $0 } ?? titleID
        reporter?.setGameTitle(displayName)
        try waitUntilResumed(reporter)

        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: downloadStateDirPermissions]
        )

        let baseURL = NUS.titleBaseURL(tid)
        let downloader = Downloader(client: client)

        let tmdPath = outputDirectory.appendingPathComponent("title.tmd")
        try downloader.download(
            from: try cdnURL(NUS.tmdURL(titleID: tid, version: version)),
            to: tmdPath,
            options: DownloadOptions(
                doRetries: true,
                allowResume: true,
                userAgent: "WiiUDownloader",
                validate: { url in try validateTMDFile(url, expectedTitleID: tid) }
            ),
            reporter: reporter
        )

        let tmdData = [UInt8](try Data(contentsOf: tmdPath))
        var tmd = try parseTMD(tmdData)
        for index in tmd.contents.indices {
            tmd.contents[index].cidStr = String(format: "%08X", tmd.contents[index].id)
        }

        let selected: Set<UInt32>? = (contentIDs?.isEmpty == false) ? Set(contentIDs!) : nil

        let ticketPath = outputDirectory.appendingPathComponent("title.tik")
        try ensureTitleTicket(
            reporter: reporter,
            client: client,
            baseURL: baseURL,
            ticketPath: ticketPath,
            tmd: tmd,
            tid: tid,
            titleID: titleID
        )

        reporter?.setDownloadSize(Int64(tmd.calculateTotalSize(selected: selected)))

        try generateCert(
            tmd: tmd,
            outputPath: outputDirectory.appendingPathComponent("title.cert"),
            reporter: reporter,
            client: client
        )

        reporter?.setStartTime(Date())

        let contents: [Content]
        if let selected {
            contents = tmd.contents.filter { selected.contains($0.id) }
        } else {
            contents = tmd.contents
        }

        try downloadContents(
            contents,
            outputDirectory: outputDirectory,
            baseURL: baseURL,
            client: client,
            reporter: reporter
        )

        // Decryption needs every content in the TMD, so a partial download skips it.
        if doDecryption, selected == nil, reporter?.isCancelled != true {
            let decryptOut = decryptOutputDirectory.map {
                $0.appendingPathComponent(outputDirectory.lastPathComponent)
            }
            try decryptor.decryptContents(
                at: outputDirectory,
                outputPath: decryptOut,
                deleteEncryptedContents: deleteEncryptedContents,
                reporter: reporter
            )
        }
    }

    /// Fetches a title's ticket from the CDN, generating a synthetic one when
    /// the CDN has none and the title's key type is known. Port of
    /// `ensureTitleTicket` in `downloader.go`.
    public static func ensureTitleTicket(
        reporter: ProgressReporter?,
        client: URLSession,
        baseURL: String,
        ticketPath: URL,
        tmd: TMD,
        tid: UInt64,
        titleID: String
    ) throws {
        let downloader = Downloader(client: client)
        do {
            try downloader.download(
                from: try cdnURL("\(baseURL)/cetk"),
                to: ticketPath,
                options: DownloadOptions(
                    doRetries: false,
                    allowResume: true,
                    userAgent: "WiiUDownloader",
                    validate: { url in
                        try validateTicketFile(
                            url,
                            expectedTitleID: tmd.titleID,
                            expectedTitleVersion: tmd.titleVersion
                        )
                    }
                ),
                reporter: reporter
            )
            return
        } catch {
            if reporter?.isCancelled == true { throw WiiUError.cancelled }
            if let error = error as? WiiUError, case .cancelled = error { throw error }
            // Fall through: the CDN has no usable ticket, so generate one.
        }

        var titleKeyType = TitleKeyType.mypass
        if let entry = titleEntry(forTitleID: tid), entry.titleID == tid {
            titleKeyType = entry.key
        }
        let titleKey = try generateKey(titleID: titleID, keyType: titleKeyType)
        try generateTicket(
            path: ticketPath,
            titleID: tmd.titleID,
            titleKey: titleKey,
            titleVersion: tmd.titleVersion
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

    // MARK: Private

    /// Fetches contents with a concurrency cap of `maxConcurrentDownloads`,
    /// aborting the remaining work on the first failure. Port of the errgroup
    /// loop in `DownloadTitleContents`.
    private static func downloadContents(
        _ contents: [Content],
        outputDirectory: URL,
        baseURL: String,
        client: URLSession,
        reporter: ProgressReporter?
    ) throws {
        let collector = DownloadErrorCollector()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = maxConcurrentDownloads

        for content in contents {
            queue.addOperation {
                if collector.isStopped || reporter?.isCancelled == true { return }
                do {
                    try downloadContentFile(
                        reporter: reporter,
                        client: client,
                        baseURL: baseURL,
                        dir: outputDirectory,
                        content: content
                    )
                } catch {
                    collector.record(reporter?.isCancelled == true ? WiiUError.cancelled : error)
                }
            }
        }

        queue.waitUntilAllOperationsAreFinished()
        if let error = collector.error {
            throw error
        }
    }
}

// MARK: - Helpers

/// First error wins; later failures are dropped. Mirrors `errgroup`'s behavior
/// of surfacing one error while cancelling the rest.
private final class DownloadErrorCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?
    private var stopped = false

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func record(_ error: Error) {
        lock.lock()
        if storedError == nil { storedError = error }
        stopped = true
        lock.unlock()
    }
}

private func parseTitleID(_ titleID: String) throws -> UInt64 {
    guard let value = UInt64(titleID, radix: 16) else {
        throw WiiUError.invalidTitleID(titleID)
    }
    return value
}

private func cdnURL(_ string: String) throws -> URL {
    guard let url = URL(string: string) else {
        throw WiiUError.download("invalid URL: \(string)")
    }
    return url
}

private func waitUntilResumed(_ reporter: ProgressReporter?) throws {
    if let reporter {
        try reporter.controller.waitIfPaused()
    }
    if reporter?.isCancelled == true {
        throw WiiUError.cancelled
    }
}
