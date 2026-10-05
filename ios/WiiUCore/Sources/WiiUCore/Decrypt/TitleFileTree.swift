import Foundation

/// One file listed by a title's FST, with enough information to extract it on
/// its own. Port of `TitleFile` in `titlefiles.go`.
public struct TitleFile: Sendable, Equatable {
    /// File path inside the title, e.g. `content/foo.bar`.
    public var path: String
    public var size: UInt64
    /// Indexes the TMD's content list, not the content's own ID.
    public var contentID: UInt16
    /// File start inside that content.
    public var offset: UInt64
    public var length: UInt64
    public var hashed: Bool
    /// Shared entries carry no extractable payload; they are listed but never
    /// downloaded.
    public var shared: Bool

    public init(
        path: String,
        size: UInt64,
        contentID: UInt16,
        offset: UInt64,
        length: UInt64,
        hashed: Bool,
        shared: Bool
    ) {
        self.path = path
        self.size = size
        self.contentID = contentID
        self.offset = offset
        self.length = length
        self.hashed = hashed
        self.shared = shared
    }
}

/// A title's parsed FST plus the small working set needed to extract files from
/// it. Port of `TitleFileTree`.
public final class TitleFileTree {
    public let titleID: UInt64
    public let name: String
    public let version: Int
    public let files: [TitleFile]

    private let workDir: URL
    private let contents: [Content]
    private let titleKey: [UInt8]
    private let client: URLSession

    private init(
        titleID: UInt64,
        name: String,
        version: Int,
        files: [TitleFile],
        workDir: URL,
        contents: [Content],
        titleKey: [UInt8],
        client: URLSession
    ) {
        self.titleID = titleID
        self.name = name
        self.version = version
        self.files = files
        self.workDir = workDir
        self.contents = contents
        self.titleKey = titleKey
        self.client = client
    }

    /// Downloads a title's FST and returns every file it lists. The FST lives in
    /// content index 0, which is small on real titles. Port of
    /// `FetchTitleFileTree`.
    public static func fetch(
        titleID: UInt64,
        version: Int,
        client: URLSession,
        reporter: ProgressReporter?
    ) throws -> TitleFileTree {
        let tidStr = String(format: "%016llx", titleID)
        let entry = titleEntry(forTitleID: titleID)

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wiiu-titlefiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        do {
            let baseURL = "http://ccs.cdn.c.shop.nintendowifi.net/ccs/download/\(tidStr)"

            let tmdPath = workDir.appendingPathComponent("title.tmd")
            var tmdURLString = baseURL + "/tmd"
            if version >= 0 { tmdURLString += ".\(version)" }
            let tmdURL = try requireURL(tmdURLString)

            let downloader = Downloader(client: client)
            try downloader.download(
                from: tmdURL,
                to: tmdPath,
                options: DownloadOptions(
                    expectedSize: 0,
                    doRetries: true,
                    allowResume: true,
                    segmentSize: 0,
                    userAgent: "WiiUDownloader",
                    validate: { url in try validateTMDFile(url, expectedTitleID: titleID) }
                ),
                reporter: nil
            )

            let tmdData = [UInt8](try Data(contentsOf: tmdPath))
            var tmd = try parseTMD(tmdData)
            if tmd.contents.isEmpty {
                throw WiiUError.extraction("title \(tidStr) lists no contents")
            }
            for index in tmd.contents.indices {
                tmd.contents[index].cidStr = String(format: "%08X", tmd.contents[index].id)
            }

            let ticketPath = workDir.appendingPathComponent("title.tik")
            try TitleDownloader.ensureTitleTicket(
                reporter: nil,
                client: client,
                baseURL: baseURL,
                ticketPath: ticketPath,
                tmd: tmd,
                tid: titleID,
                titleID: tidStr
            )
            let titleKey = try newTitleCipher(ticketPath: ticketPath, tmd: tmd)

            let fstContent = tmd.contents[0]
            let fstPath = workDir.appendingPathComponent(fstContent.cidStr + ".app")
            try downloadContentFile(
                reporter: reporter,
                client: client,
                baseURL: baseURL,
                dir: workDir,
                content: fstContent
            )

            let fstHandle = try FileHandle(forReadingFrom: fstPath)
            let buffer: [UInt8]
            do {
                buffer = try decryptContentToBuffer(encryptedFile: fstHandle, content: fstContent, titleKey: titleKey)
            } catch {
                try? fstHandle.close()
                throw error
            }
            try? fstHandle.close()

            let table: FSTTable
            do {
                table = try parseFST(buffer)
            } catch {
                throw WiiUError.extraction("failed to parse the title's file list: \(error)")
            }

            let files = try flattenFST(table: table, tmd: tmd)

            var name = entry?.name ?? ""
            if name.isEmpty { name = tidStr }

            return TitleFileTree(
                titleID: titleID,
                name: name,
                version: version,
                files: files,
                workDir: workDir,
                contents: tmd.contents,
                titleKey: titleKey,
                client: client
            )
        } catch {
            try? FileManager.default.removeItem(at: workDir)
            throw error
        }
    }

    /// Sum of the listed files, excluding shared entries.
    public func totalSize() -> UInt64 {
        var total: UInt64 = 0
        for file in files where !file.shared {
            total += file.size
        }
        return total
    }

    /// Fetches the contents the selected paths need, then extracts exactly those
    /// files under `outputDirectory`, keeping the FST's directory tree. Port of
    /// `DownloadFiles`.
    public func downloadFiles(outputDirectory: URL, paths: [String], reporter: ProgressReporter?) throws {
        let wanted = Set(paths)

        var selected: [TitleFile] = []
        var needed = Set<UInt16>()
        for file in files {
            if file.shared { continue }
            if !wanted.contains(file.path) { continue }
            selected.append(file)
            needed.insert(file.contentID)
        }
        if selected.isEmpty { return }

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        reporter?.resetTotals()

        let baseURL = "http://ccs.cdn.c.shop.nintendowifi.net/ccs/download/\(String(format: "%016llx", titleID))"
        var missing: [Content] = []
        var totalSize: Int64 = 0
        for index in needed {
            if Int(index) >= contents.count {
                throw WiiUError.extraction("invalid content index \(index)")
            }
            let content = contents[Int(index)]
            if FileManager.default.fileExists(atPath: contentPath(index).path) {
                continue
            }
            missing.append(content)
            totalSize += expectedContentDownloadSize(content) + expectedH3DownloadSize(content)
        }
        reporter?.setDownloadSize(totalSize)

        missing.sort { $0.id < $1.id }
        for content in missing {
            if reporter?.isCancelled == true { return }
            try downloadContentFile(reporter: reporter, client: client, baseURL: baseURL, dir: workDir, content: content)
        }

        for (index, file) in selected.enumerated() {
            if let reporter = reporter {
                if reporter.isCancelled { return }
                reporter.updateDecryptionProgress(Double(index) / Double(selected.count))
            }
            try extractTitleFile(file, outputDir: outputDirectory)
        }
        reporter?.updateDecryptionProgress(1)
    }

    /// Removes the temporary directory holding the metadata and FST content.
    public func close() {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: Private

    private func contentPath(_ index: UInt16) -> URL {
        workDir.appendingPathComponent(contents[Int(index)].cidStr + ".app")
    }

    private func extractTitleFile(_ file: TitleFile, outputDir: URL) throws {
        if Int(file.contentID) >= contents.count {
            throw WiiUError.extraction("invalid content index \(file.contentID)")
        }
        let targetPath = try safeJoinUnderBase(base: outputDir, current: outputDir, name: file.path)
        try FileManager.default.createDirectory(at: targetPath.deletingLastPathComponent(), withIntermediateDirectories: true)

        let src = try FileHandle(forReadingFrom: contentPath(file.contentID))
        var extractionError: Error?
        do {
            if file.hashed {
                try extractFileHash(
                    src: src,
                    partDataOffset: 0,
                    fileOffset: file.offset,
                    size: file.length,
                    path: targetPath,
                    contentID: file.contentID,
                    titleKey: titleKey
                )
            } else {
                try extractFile(
                    src: src,
                    partDataOffset: 0,
                    fileOffset: file.offset,
                    size: file.length,
                    path: targetPath,
                    contentID: file.contentID,
                    titleKey: titleKey
                )
            }
        } catch {
            extractionError = error
        }
        try? src.close()
        if let extractionError = extractionError {
            throw WiiUError.extraction("failed to extract \(file.path): \(extractionError)")
        }
    }
}

// MARK: - Helpers

/// Fetches one content (and its `.h3` when hashed) into `dir`. Port of
/// `downloadContentFile`.
func downloadContentFile(
    reporter: ProgressReporter?,
    client: URLSession,
    baseURL: String,
    dir: URL,
    content: Content
) throws {
    let downloader = Downloader(client: client)
    let contentURL = try requireURL("\(baseURL)/\(content.cidStr)")
    try downloader.download(
        from: contentURL,
        to: dir.appendingPathComponent(content.cidStr + ".app"),
        options: DownloadOptions(
            expectedSize: expectedContentDownloadSize(content),
            doRetries: true,
            allowResume: true,
            segmentSize: 0,
            userAgent: "WiiUDownloader",
            validate: nil
        ),
        reporter: reporter
    )
    if content.type & WiiUConstants.contentTypeHashed == 0 {
        return
    }
    let h3URL = try requireURL("\(baseURL)/\(content.cidStr).h3")
    try downloader.download(
        from: h3URL,
        to: dir.appendingPathComponent(content.cidStr + ".h3"),
        options: DownloadOptions(
            expectedSize: expectedH3DownloadSize(content),
            doRetries: true,
            allowResume: true,
            segmentSize: 0,
            userAgent: "WiiUDownloader",
            validate: { url in try verifyH3File(url, content: content) }
        ),
        reporter: reporter
    )
}

/// Walks the FST's directory hierarchy into file paths. Port of `flattenFST`.
func flattenFST(table: FSTTable, tmd: TMD) throws -> [TitleFile] {
    var files: [TitleFile] = []
    files.reserveCapacity(table.entries.count)

    var nameStack: [String] = []
    nameStack.reserveCapacity(WiiUConstants.maxLevels)
    var positions = [UInt32](repeating: 0, count: WiiUConstants.maxLevels)
    var level: UInt32 = 0
    let entriesLen = UInt32(table.entries.count)

    var i: UInt32 = 1
    while i < entriesLen {
        while level >= 1, table.entries[Int(positions[Int(level - 1)])].length == i {
            level -= 1
            nameStack.removeLast()
        }

        let current = table.entries[Int(i)]
        let fileName = try table.name(at: current.nameOffset & WiiUConstants.fstNameOffsetMask)

        if current.type & WiiUConstants.fstDirectoryTypeFlag != 0 {
            if level >= UInt32(WiiUConstants.maxLevels) {
                throw WiiUError.extraction("FST directory nesting exceeds limit")
            }
            positions[Int(level)] = i
            level += 1
            nameStack.append(fileName)
            i += 1
            continue
        }

        var offset = UInt64(current.offset)
        if current.flags & WiiUConstants.fstContentFactorFlag == 0 {
            offset *= UInt64(table.factor)
        }
        var hashed = false
        if Int(current.contentID) < tmd.contents.count {
            hashed = tmd.contents[Int(current.contentID)].type & WiiUConstants.contentTypeHashed != 0
        }

        files.append(
            TitleFile(
                path: (nameStack + [fileName]).joined(separator: "/"),
                size: UInt64(current.length),
                contentID: current.contentID,
                offset: offset,
                length: UInt64(current.length),
                hashed: hashed,
                shared: current.type & UInt8(WiiUConstants.fstSharedContentFlag) != 0
            )
        )
        i += 1
    }

    files.sort { $0.path < $1.path }
    return files
}

/// Builds a URL from a CDN string, throwing on malformed input.
private func requireURL(_ string: String) throws -> URL {
    guard let url = URL(string: string) else {
        throw WiiUError.download("invalid URL: \(string)")
    }
    return url
}
