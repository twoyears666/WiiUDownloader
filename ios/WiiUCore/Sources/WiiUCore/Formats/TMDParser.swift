import Foundation

// MARK: - TMD version constants
// Port of `internal/formats/tmd/spec.go` (`VersionWii` / `VersionWiiU`) and the
// re-exported constants in `tmd.go`.

public let tmdVersionWii: UInt8 = 0x00
public let tmdVersionWiiU: UInt8 = 0x01

// MARK: - Field offsets
// Port of the offset constants in `internal/formats/tmd/spec.go`.

private let tmdVersionOffset = 0x180
private let tmdTitleIDOffset = 0x18C
private let tmdTitleVersionOffset = 0x1DC
private let tmdContentCountOffset = 0x1DE

private let wiiContentStart = 0x1E4
private let wiiContentStride = 0x24
private let wiiHashSize = 0x14

private let wiiuContentStart = 0xB04
private let wiiuContentStride = 0x30
private let wiiuHashSize = 0x20

// MARK: - TMD model
// Port of the public `TMD` type in `tmd.go` / the internal `Metadata` type in
// `internal/formats/tmd/parser.go`.

/// A parsed title metadata document.
public struct TMD: Sendable, Equatable {
    public var titleID: UInt64
    public var version: UInt8
    public var titleVersion: UInt16
    public var contentCount: UInt16
    public var contents: [Content]
    public var certificate1: [UInt8]
    public var certificate2: [UInt8]

    public init(
        titleID: UInt64 = 0,
        version: UInt8 = 0,
        titleVersion: UInt16 = 0,
        contentCount: UInt16 = 0,
        contents: [Content] = [],
        certificate1: [UInt8] = [],
        certificate2: [UInt8] = []
    ) {
        self.titleID = titleID
        self.version = version
        self.titleVersion = titleVersion
        self.contentCount = contentCount
        self.contents = contents
        self.certificate1 = certificate1
        self.certificate2 = certificate2
    }
}

// MARK: - Parsing
// Port of `tmd.Parse` (`internal/formats/tmd/parser.go`) wrapped by `ParseTMD`
// (`tmd.go`). A version other than Wii(0)/WiiU(1) is rejected as a parse error.

/// Parses a raw `title.tmd` buffer.
public func parseTMD(_ data: [UInt8]) throws -> TMD {
    var cursor = BinaryCursor(data)

    try cursor.seek(tmdVersionOffset)
    let version = try cursor.readU8()

    var tmd = TMD(version: version)
    switch version {
    case tmdVersionWii:
        try parseTMDHeader(&cursor, &tmd)
        try parseTMDContents(
            &cursor, &tmd,
            start: wiiContentStart,
            stride: wiiContentStride,
            hashSize: wiiHashSize
        )
        try parseTMDCertificates(
            &cursor, &tmd,
            start: wiiContentStart,
            stride: wiiContentStride,
            count: Int(tmd.contentCount),
            hashSize: wiiHashSize,
            required: true
        )
    case tmdVersionWiiU:
        try parseTMDHeader(&cursor, &tmd)
        try parseTMDContents(
            &cursor, &tmd,
            start: wiiuContentStart,
            stride: wiiuContentStride,
            hashSize: wiiuHashSize
        )
        try parseTMDCertificates(
            &cursor, &tmd,
            start: wiiuContentStart,
            stride: wiiuContentStride,
            count: Int(tmd.contentCount),
            hashSize: wiiuHashSize,
            required: false
        )
    default:
        throw WiiUError.parse("unknown TMD version: \(version)")
    }
    return tmd
}

/// Reads the common title ID / version / content count header fields.
private func parseTMDHeader(_ cursor: inout BinaryCursor, _ tmd: inout TMD) throws {
    try cursor.seek(tmdTitleIDOffset)
    tmd.titleID = try cursor.readU64BE()

    try cursor.seek(tmdTitleVersionOffset)
    tmd.titleVersion = try cursor.readU16BE()
    tmd.contentCount = try cursor.readU16BE()
}

/// Reads the fixed-stride content records that follow the header.
private func parseTMDContents(
    _ cursor: inout BinaryCursor,
    _ tmd: inout TMD,
    start: Int,
    stride: Int,
    hashSize: Int
) throws {
    var contents: [Content] = []
    contents.reserveCapacity(Int(tmd.contentCount))
    for i in 0 ..< Int(tmd.contentCount) {
        let offset = start + stride * i
        try cursor.seek(offset)

        let id = try cursor.readU32BE()
        let indexBytes = try cursor.readBytes(2)
        let contentType = try cursor.readU16BE()
        let size = try cursor.readU64BE()
        let hash = try cursor.readBytes(hashSize)

        contents.append(
            Content(
                id: id,
                index: indexBytes,
                type: contentType,
                size: size,
                hash: hash
            )
        )
    }
    tmd.contents = contents
}

/// Reads the optional certificate blobs that follow the last content record.
///
/// Wii TMDs require both certificates; Wii U TMDs read them only when the
/// remaining buffer is large enough (0x400 then 0x300 bytes).
private func parseTMDCertificates(
    _ cursor: inout BinaryCursor,
    _ tmd: inout TMD,
    start: Int,
    stride: Int,
    count: Int,
    hashSize: Int,
    required: Bool
) throws {
    if count == 0 {
        return
    }
    let lastEnd = start + (count - 1) * stride + 16 + hashSize
    if lastEnd < 0 {
        return
    }
    do {
        try cursor.seek(lastEnd)
    } catch {
        if required {
            throw error
        }
        return
    }
    if required || cursor.remaining >= 0x400 {
        tmd.certificate1 = try cursor.readBytes(0x400)
    }
    if required || cursor.remaining >= 0x300 {
        tmd.certificate2 = try cursor.readBytes(0x300)
    }
}

// MARK: - Size accounting
// Port of `TMD.calculateTotalSize` in `tmd.go`.

public extension TMD {
    /// Sums the CDN download size of the selected contents. A `nil` or empty
    /// selection means every content in the TMD.
    func calculateTotalSize(selected: Set<UInt32>? = nil) -> UInt64 {
        let filter: Set<UInt32>? = (selected?.isEmpty == false) ? selected : nil
        var total: UInt64 = 0
        for content in contents {
            if let filter, !filter.contains(content.id) {
                continue
            }
            total += UInt64(expectedContentDownloadSize(content))
            total += UInt64(expectedH3DownloadSize(content))
        }
        return total
    }
}
