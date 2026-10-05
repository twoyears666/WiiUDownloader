import Foundation
import Mobile

/// One file listed by a title's FST, with enough information to extract it on
/// its own. Mirrors `TitleFile` in `titlefiles.go`.
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

/// A title's parsed FST, backed by the upstream Go implementation through
/// gomobile. The file list is snapshotted on `fetch`; extraction still runs
/// against the Go tree, which owns the temporary working set.
public final class TitleFileTree {
    public let titleID: UInt64
    public let name: String
    public let version: Int
    public let files: [TitleFile]

    private let handle: MobileTitleFiles

    private init(titleID: UInt64, name: String, version: Int, files: [TitleFile], handle: MobileTitleFiles) {
        self.titleID = titleID
        self.name = name
        self.version = version
        self.files = files
        self.handle = handle
    }

    /// Downloads a title's FST and returns every file it lists. Port of
    /// `FetchTitleFileTree`.
    public static func fetch(
        titleID: UInt64,
        version: Int,
        client: URLSession,
        reporter: ProgressReporter?
    ) throws -> TitleFileTree {
        let tidStr = GoBackend.titleIDString(titleID)
        let resolvedVersion = GoBackend.normalize(version: version)

        var error: NSError?
        guard let handle = MobileFetchTitleFiles(tidStr, resolvedVersion, &error) else {
            throw GoBackend.map(error)
        }

        let count = handle.fileCount()
        var files: [TitleFile] = []
        files.reserveCapacity(count)
        for index in 0..<count {
            guard let entry = handle.file(at: index) else { continue }
            files.append(
                TitleFile(
                    path: entry.path,
                    size: UInt64(entry.size),
                    contentID: UInt16(truncatingIfNeeded: entry.contentID),
                    offset: UInt64(entry.offset),
                    length: UInt64(entry.length),
                    hashed: entry.hashed,
                    shared: entry.shared
                )
            )
        }

        let entry = titleEntry(forTitleID: titleID)
        var name = entry?.name ?? ""
        if name.isEmpty { name = tidStr }

        return TitleFileTree(
            titleID: titleID,
            name: name,
            version: resolvedVersion,
            files: files,
            handle: handle
        )
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
        if paths.isEmpty { return }

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let data = try JSONEncoder().encode(paths)
        guard let pathsJSON = String(data: data, encoding: .utf8) else {
            throw WiiUError.extraction("failed to encode file paths")
        }

        let bridge = GoReporterBridge(reporter: reporter)
        try handle.downloadFiles(outputDirectory.path, pathsJSON: pathsJSON, r: bridge)
        if reporter?.controller.isCancelled == true { throw WiiUError.cancelled }
    }

    /// Releases the Go-side temporary working set backing the tree.
    public func close() {
        try? handle.close()
    }
}
