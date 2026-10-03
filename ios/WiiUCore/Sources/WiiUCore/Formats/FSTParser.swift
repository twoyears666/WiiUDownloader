import Foundation

// MARK: - FST model
// Port of `internal/formats/fst/parser.go`.

/// Maximum number of entries accepted in an FST.
private let fstMaxEntries: UInt32 = 1_000_000

/// One on-disk FST entry (0x10 bytes each).
public struct FSTEntry: Sendable, Equatable {
    public var type: UInt8
    public var nameOffset: UInt32
    public var offset: UInt32
    public var length: UInt32
    public var flags: UInt16
    public var contentID: UInt16

    public init(
        type: UInt8,
        nameOffset: UInt32,
        offset: UInt32,
        length: UInt32,
        flags: UInt16,
        contentID: UInt16
    ) {
        self.type = type
        self.nameOffset = nameOffset
        self.offset = offset
        self.length = length
        self.flags = flags
        self.contentID = contentID
    }
}

/// A parsed file-system table. Keeps the backing buffer so names can be
/// resolved lazily via `name(at:)`.
public final class FSTTable {
    public let factor: UInt32
    public let entryCount: UInt32
    public let namesOffset: UInt32
    public let entries: [FSTEntry]

    private let data: [UInt8]

    init(factor: UInt32, entryCount: UInt32, namesOffset: UInt32, entries: [FSTEntry], data: [UInt8]) {
        self.factor = factor
        self.entryCount = entryCount
        self.namesOffset = namesOffset
        self.entries = entries
        self.data = data
    }

    /// Resolves the NUL-terminated name stored at `namesOffset + nameOffset`.
    public func name(at nameOffset: UInt32) throws -> String {
        // Mirrors Go's uint32 addition, which wraps on overflow.
        let start = Int(namesOffset &+ nameOffset)
        guard start >= 0, start < data.count else {
            throw WiiUError.parse("FST name offset out of bounds: \(nameOffset)")
        }

        var end = start
        while end < data.count && data[end] != 0 {
            end += 1
        }
        if end == data.count {
            throw WiiUError.parse("unterminated FST string at offset \(nameOffset)")
        }
        return String(decoding: data[start ..< end], as: UTF8.self)
    }
}

// MARK: - Parsing

/// Parses the file-system table stored inside a decrypted FST content.
public func parseFST(_ data: [UInt8]) throws -> FSTTable {
    var cursor = BinaryCursor(data)
    try cursor.seek(0x04)
    let rawFactor = try cursor.readU32BE()
    let entryCount = try cursor.readU32BE()
    let factor = rawFactor == 0 ? 1 : rawFactor

    let rootOffset = 0x20 + Int(entryCount) * 0x20
    guard rootOffset >= 0, rootOffset <= data.count - 16 else {
        throw WiiUError.parse("invalid FST root offset")
    }

    try cursor.seek(rootOffset + 8)
    let totalEntries = try cursor.readU32BE()
    guard totalEntries != 0, totalEntries <= fstMaxEntries else {
        throw WiiUError.parse("invalid FST entries count: \(totalEntries)")
    }

    let namesOffset = UInt32(0x20 + Int(entryCount) * 0x20 + Int(totalEntries) * 0x10)
    guard Int(namesOffset) <= data.count else {
        throw WiiUError.parse("invalid FST names offset")
    }

    try cursor.seek(rootOffset)

    var entries: [FSTEntry] = []
    entries.reserveCapacity(Int(totalEntries))
    for _ in 0 ..< Int(totalEntries) {
        let type = try cursor.readU8()
        let nameBytes = try cursor.readBytes(3)
        // Go reads three bytes and combines them as
        // nameB[2] | nameB[1]<<8 | nameB[0]<<16, i.e. 3-byte big-endian.
        let nameOffset = UInt32(nameBytes[2]) | UInt32(nameBytes[1]) << 8 | UInt32(nameBytes[0]) << 16
        let offset = try cursor.readU32BE()
        let length = try cursor.readU32BE()
        let flags = try cursor.readU16BE()
        let contentID = try cursor.readU16BE()

        entries.append(
            FSTEntry(
                type: type,
                nameOffset: nameOffset,
                offset: offset,
                length: length,
                flags: flags,
                contentID: contentID
            )
        )
    }

    return FSTTable(
        factor: factor,
        entryCount: entryCount,
        namesOffset: namesOffset,
        entries: entries,
        data: data
    )
}
