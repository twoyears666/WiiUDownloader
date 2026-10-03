import Foundation

// MARK: - Constants
// Port of the constants in `download_state.go`.

let defaultDownloadSegmentSize: Int64 = 1 << 20
let mediumDownloadSegmentSize: Int64 = 4 << 20
let largeDownloadSegmentSize: Int64 = 16 << 20
let maxSmallDownloadSize: Int64 = 64 << 20
let maxMediumDownloadSize: Int64 = 1 << 30

let downloadPartExtension = ".part"
let downloadStateExtension = ".resume.json"
let downloadStateDirPermissions = 0o755
let downloadFilePermissions = 0o644
let resumeJournalMagic = "WUDRESUME2"
let resumeJournalHeader = [UInt8]("WUDRESUME2\n".utf8)

// MARK: - State model
// Port of `downloadSegment` / `downloadState` from `download_state.go`. Keys
// match the Go JSON tags so existing journal files stay readable.

struct DownloadSegment: Codable, Equatable {
    var offset: Int64
    var size: Int64
    var sha256: String
}

struct DownloadState: Codable, Equatable {
    var url: String
    var expectedSize: Int64
    var segmentSize: Int64
    var verifiedOffset: Int64
    var lastModified: String?
    var etag: String?
    var segments: [DownloadSegment]
    var partialSegment: DownloadSegment?

    init(
        url: String = "",
        expectedSize: Int64 = 0,
        segmentSize: Int64 = 0,
        verifiedOffset: Int64 = 0,
        lastModified: String? = nil,
        etag: String? = nil,
        segments: [DownloadSegment] = [],
        partialSegment: DownloadSegment? = nil
    ) {
        self.url = url
        self.expectedSize = expectedSize
        self.segmentSize = segmentSize
        self.verifiedOffset = verifiedOffset
        self.lastModified = lastModified
        self.etag = etag
        self.segments = segments
        self.partialSegment = partialSegment
    }

    enum CodingKeys: String, CodingKey {
        case url
        case expectedSize = "expected_size"
        case segmentSize = "segment_size"
        case verifiedOffset = "verified_offset"
        case lastModified = "last_modified"
        case etag
        case segments
        case partialSegment = "partial_segment"
    }

    /// Tolerant decoding: Go marshals a nil slice as `null`, which the
    /// synthesised decoder would reject for a non-optional array.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        expectedSize = try container.decodeIfPresent(Int64.self, forKey: .expectedSize) ?? 0
        segmentSize = try container.decodeIfPresent(Int64.self, forKey: .segmentSize) ?? 0
        verifiedOffset = try container.decodeIfPresent(Int64.self, forKey: .verifiedOffset) ?? 0
        lastModified = try container.decodeIfPresent(String.self, forKey: .lastModified)
        etag = try container.decodeIfPresent(String.self, forKey: .etag)
        segments = try container.decodeIfPresent([DownloadSegment].self, forKey: .segments) ?? []
        partialSegment = try container.decodeIfPresent(DownloadSegment.self, forKey: .partialSegment)
    }
}

// MARK: - Paths

func partPathFor(_ dstPath: URL) -> URL {
    URL(fileURLWithPath: dstPath.path + downloadPartExtension)
}

func statePathFor(_ dstPath: URL) -> URL {
    URL(fileURLWithPath: dstPath.path + downloadStateExtension)
}

// MARK: - Hashing

func hashSegmentHex(_ data: [UInt8]) -> String {
    Digests.sha256(data).map { String(format: "%02x", $0) }.joined()
}

// MARK: - Loading

/// Loads a state file, auto-detecting the journal format and falling back to
/// the legacy single-JSON layout. Port of `loadDownloadState`.
func loadDownloadState(path: URL) throws -> (state: DownloadState, dirty: Bool) {
    let data = [UInt8](try Data(contentsOf: path))
    if data.count >= resumeJournalHeader.count, data[0 ..< resumeJournalHeader.count].elementsEqual(resumeJournalHeader) {
        return try loadDownloadStateJournal(data)
    }
    return try loadLegacyDownloadState(data)
}

func loadLegacyDownloadState(_ data: [UInt8]) throws -> (state: DownloadState, dirty: Bool) {
    do {
        var state = try JSONDecoder().decode(DownloadState.self, from: Data(data))
        state.segmentSize = normalizeSegmentSize(state.segmentSize, expectedSize: state.expectedSize)
        return (state, false)
    } catch {
        throw WiiUError.invalidState("\(error)")
    }
}

func loadDownloadStateJournal(_ data: [UInt8]) throws -> (state: DownloadState, dirty: Bool) {
    let body = data[resumeJournalHeader.count...]
    let decoder = JSONDecoder()
    var state: DownloadState?
    var dirty = false

    for rawLine in body.split(separator: 0x0A, omittingEmptySubsequences: false) {
        let line = trimASCIIWhitespace(Array(rawLine))
        if line.isEmpty { continue }
        do {
            var snapshot = try decoder.decode(DownloadState.self, from: Data(line))
            snapshot.segmentSize = normalizeSegmentSize(snapshot.segmentSize, expectedSize: snapshot.expectedSize)
            state = snapshot
        } catch {
            if state != nil {
                dirty = true
                break
            }
            throw WiiUError.invalidState("\(error)")
        }
    }

    guard let result = state else {
        throw WiiUError.invalidState("download state journal is empty")
    }
    return (result, dirty)
}

private func trimASCIIWhitespace(_ bytes: [UInt8]) -> [UInt8] {
    func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || (byte >= 0x09 && byte <= 0x0D)
    }
    var start = 0
    var end = bytes.count
    while start < end, isWhitespace(bytes[start]) { start += 1 }
    while end > start, isWhitespace(bytes[end - 1]) { end -= 1 }
    return Array(bytes[start ..< end])
}

// MARK: - Saving

func saveDownloadState(path: URL, state: DownloadState) throws {
    try persistDownloadState(path: path, state: state, rewrite: false)
}

func rewriteDownloadState(path: URL, state: DownloadState) throws {
    try persistDownloadState(path: path, state: state, rewrite: true)
}

func persistDownloadState(path: URL, state: DownloadState, rewrite: Bool) throws {
    try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: nil
    )

    var state = state
    state.segmentSize = normalizeSegmentSize(state.segmentSize, expectedSize: state.expectedSize)
    var snapshot = try JSONEncoder().encode(state)
    snapshot.append(0x0A)

    if rewrite {
        FileManager.default.createFile(atPath: path.path, contents: nil)
        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data(resumeJournalHeader))
        try handle.write(contentsOf: snapshot)
        try handle.synchronize()
        return
    }

    let hasHeader = try resumeStateHasJournalHeader(path: path)
    if !hasHeader {
        return try persistDownloadState(path: path, state: state, rewrite: true)
    }

    let handle = try FileHandle(forWritingTo: path)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: snapshot)
    try handle.synchronize()
}

func resumeStateHasJournalHeader(path: URL) throws -> Bool {
    guard FileManager.default.fileExists(atPath: path.path) else {
        return false
    }
    let handle = try FileHandle(forReadingFrom: path)
    defer { try? handle.close() }
    let header = [UInt8](try handle.read(upToCount: resumeJournalHeader.count) ?? Data())
    return header == resumeJournalHeader
}

// MARK: - Segment sizing

/// Picks a segment size for the journal when the caller did not pin one.
/// Port of `normalizeSegmentSize`.
func normalizeSegmentSize(_ segmentSize: Int64, expectedSize: Int64) -> Int64 {
    if segmentSize > 0 { return segmentSize }
    switch true {
    case expectedSize > 0 && expectedSize <= defaultDownloadSegmentSize:
        return expectedSize
    case expectedSize > 0 && expectedSize <= maxSmallDownloadSize:
        return defaultDownloadSegmentSize
    case expectedSize > 0 && expectedSize <= maxMediumDownloadSize:
        return mediumDownloadSegmentSize
    case expectedSize > 0:
        return largeDownloadSegmentSize
    default:
        return defaultDownloadSegmentSize
    }
}

func resetDownloadState(url: String, expectedSize: Int64, segmentSize: Int64) -> DownloadState {
    DownloadState(
        url: url,
        expectedSize: expectedSize,
        segmentSize: normalizeSegmentSize(segmentSize, expectedSize: expectedSize),
        segments: []
    )
}

// MARK: - Cleanup

func cleanupPartialDownload(_ dstPath: URL) throws {
    let fileManager = FileManager.default
    let partPath = partPathFor(dstPath)
    if fileManager.fileExists(atPath: partPath.path) {
        try fileManager.removeItem(at: partPath)
    }
    let statePath = statePathFor(dstPath)
    if fileManager.fileExists(atPath: statePath.path) {
        try fileManager.removeItem(at: statePath)
    }
}

// MARK: - Preparation

/// Reconciles the on-disk `.part` file with its journal and returns the state
/// plus the offset that is safe to resume from. Port of `prepareDownloadState`.
///
/// `state` is `nil` when resuming is disabled, in which case no journal is used.
func prepareDownloadState(
    dstPath: URL,
    downloadURL: String,
    expectedSize: Int64,
    allowResume: Bool,
    segmentSize: Int64
) throws -> (state: DownloadState?, verifiedOffset: Int64) {
    if !allowResume {
        try cleanupPartialDownload(dstPath)
        return (nil, 0)
    }

    let fileManager = FileManager.default
    let partPath = partPathFor(dstPath)
    let statePath = statePathFor(dstPath)

    guard fileManager.fileExists(atPath: statePath.path) else {
        if fileManager.fileExists(atPath: partPath.path) {
            try fileManager.removeItem(at: partPath)
        }
        return (resetDownloadState(url: downloadURL, expectedSize: expectedSize, segmentSize: segmentSize), 0)
    }

    let loaded: DownloadState
    let dirty: Bool
    do {
        (loaded, dirty) = try loadDownloadState(path: statePath)
    } catch let error as WiiUError {
        guard case .invalidState = error else { throw error }
        try cleanupPartialDownload(dstPath)
        return (resetDownloadState(url: downloadURL, expectedSize: expectedSize, segmentSize: segmentSize), 0)
    }

    var state = loaded
    if !state.url.isEmpty, state.url != downloadURL {
        try cleanupPartialDownload(dstPath)
        return (resetDownloadState(url: downloadURL, expectedSize: expectedSize, segmentSize: segmentSize), 0)
    }
    if expectedSize > 0, state.expectedSize > 0, state.expectedSize != expectedSize {
        try cleanupPartialDownload(dstPath)
        return (resetDownloadState(url: downloadURL, expectedSize: expectedSize, segmentSize: segmentSize), 0)
    }

    guard fileManager.fileExists(atPath: partPath.path) else {
        try? fileManager.removeItem(at: statePath)
        return (resetDownloadState(url: downloadURL, expectedSize: expectedSize, segmentSize: segmentSize), 0)
    }

    state.url = downloadURL
    state.segmentSize = normalizeSegmentSize(segmentSize, expectedSize: expectedSize)
    if expectedSize > 0 {
        state.expectedSize = expectedSize
    }

    let (verifiedOffset, changed) = try verifyPartialFile(partPath: partPath, state: &state)
    if changed || dirty {
        try rewriteDownloadState(path: statePath, state: state)
    }
    return (state, verifiedOffset)
}

/// Walks the recorded segments, dropping any that no longer hash-match the
/// `.part` file and truncating the file at the first invalid byte. Port of
/// `verifyPartialFile`.
func verifyPartialFile(partPath: URL, state: inout DownloadState) throws -> (Int64, Bool) {
    let handle = try FileHandle(forUpdating: partPath)
    defer { try? handle.close() }

    state.segmentSize = normalizeSegmentSize(state.segmentSize, expectedSize: state.expectedSize)

    var validOffset: Int64 = 0
    var trimmedSegments: [DownloadSegment] = []
    trimmedSegments.reserveCapacity(state.segments.count)
    var changed = false

    for segment in state.segments {
        if segment.offset != validOffset || segment.size <= 0 || segment.size > state.segmentSize {
            changed = true
            break
        }
        do {
            try handle.seek(toOffset: UInt64(segment.offset))
            let data = try DecryptFileIO.readFull(handle, count: Int(segment.size))
            guard hashSegmentHex(data) == segment.sha256 else {
                try handle.truncate(atOffset: UInt64(validOffset))
                changed = true
                break
            }
            trimmedSegments.append(segment)
            validOffset += segment.size
        } catch {
            try handle.truncate(atOffset: UInt64(validOffset))
            changed = true
            break
        }
    }

    state.segments = trimmedSegments

    if let partial = state.partialSegment {
        if partial.offset != validOffset || partial.size <= 0 || partial.size > state.segmentSize {
            state.partialSegment = nil
            state.verifiedOffset = validOffset
            return (validOffset, true)
        }
        do {
            try handle.seek(toOffset: UInt64(partial.offset))
            let data = try DecryptFileIO.readFull(handle, count: Int(partial.size))
            guard hashSegmentHex(data) == partial.sha256 else {
                try handle.truncate(atOffset: UInt64(validOffset))
                state.partialSegment = nil
                state.verifiedOffset = validOffset
                return (validOffset, true)
            }
            validOffset += partial.size
        } catch {
            try handle.truncate(atOffset: UInt64(validOffset))
            state.partialSegment = nil
            state.verifiedOffset = validOffset
            return (validOffset, true)
        }
    }

    let fileSize = try DecryptFileIO.size(of: handle)
    if fileSize != validOffset {
        try handle.truncate(atOffset: UInt64(validOffset))
        changed = true
    }

    state.verifiedOffset = validOffset
    return (validOffset, changed)
}

// MARK: - Journal writer

/// Appends per-segment snapshots to the `.resume.json` journal as bytes are
/// written. Port of `resumeStateWriter`.
final class ResumeStateWriter {
    private let file: FileHandle
    private var state: DownloadState
    private let statePath: URL
    private let segmentSize: Int64
    private var pending: [UInt8]
    private var pendingAt: Int64

    init(file: FileHandle, state: DownloadState, statePath: URL) throws {
        self.file = file
        self.state = state
        self.statePath = statePath
        self.segmentSize = state.segmentSize

        if let partial = state.partialSegment {
            let partialSize = Int(partial.size)
            let savedOffset = try file.offset()
            try file.seek(toOffset: UInt64(partial.offset))
            let data = try DecryptFileIO.readFull(file, count: partialSize)
            try file.seek(toOffset: savedOffset)
            self.pending = data
            self.pendingAt = partial.offset
        } else {
            self.pending = []
            self.pendingAt = state.verifiedOffset
        }
    }

    /// Writes `bytes` to the file and records them in the journal.
    @discardableResult
    func write(_ bytes: [UInt8]) throws -> Int {
        try file.write(contentsOf: Data(bytes))
        try record(bytes, finalize: false)
        return bytes.count
    }

    /// Flushes whatever the file gained and records the trailing partial segment.
    func finalize() throws {
        try reconcileFromFile()
        try record([], finalize: true)
    }

    /// Picks up bytes that were written to the file without going through
    /// `write` (e.g. after a resume). Port of `reconcileFromFile`.
    private func reconcileFromFile() throws {
        let fileSize = try DecryptFileIO.size(of: file)
        var recordedOffset = state.verifiedOffset
        if !pending.isEmpty {
            recordedOffset = pendingAt + Int64(pending.count)
        }
        if fileSize <= recordedOffset {
            return
        }

        while recordedOffset < fileSize {
            var count = fileSize - recordedOffset
            if count > segmentSize {
                count = segmentSize
            }
            try file.seek(toOffset: UInt64(recordedOffset))
            let missing = try DecryptFileIO.readFull(file, count: Int(count))
            try record(missing, finalize: false)
            recordedOffset += count
        }
    }

    private func record(_ bytes: [UInt8], finalize: Bool) throws {
        var index = 0
        while index < bytes.count {
            var remaining = Int(segmentSize) - pending.count
            if remaining <= 0 {
                try persistPending()
                continue
            }
            if remaining > bytes.count - index {
                remaining = bytes.count - index
            }
            pending.append(contentsOf: bytes[index ..< index + remaining])
            index += remaining
            if Int64(pending.count) == segmentSize {
                try persistPending()
            }
        }
        if finalize, !pending.isEmpty {
            try savePartialPending()
        }
    }

    private func persistPending() throws {
        if pending.isEmpty {
            state.partialSegment = nil
            return
        }

        let segment = DownloadSegment(
            offset: pendingAt,
            size: Int64(pending.count),
            sha256: hashSegmentHex(pending)
        )
        state.segments.append(segment)
        state.partialSegment = nil
        state.verifiedOffset = segment.offset + segment.size
        pending.removeAll(keepingCapacity: true)
        pendingAt = state.verifiedOffset

        try saveDownloadState(path: statePath, state: state)
    }

    private func savePartialPending() throws {
        let segment = DownloadSegment(
            offset: pendingAt,
            size: Int64(pending.count),
            sha256: hashSegmentHex(pending)
        )
        state.partialSegment = segment
        state.verifiedOffset = segment.offset + segment.size
        try saveDownloadState(path: statePath, state: state)
    }
}
