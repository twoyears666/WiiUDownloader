import Foundation

/// Big-endian cursor over an in-memory buffer. Port of `internal/safebin.Cursor`.
public struct BinaryCursor {
    private let data: [UInt8]
    public private(set) var position: Int

    public init(_ data: [UInt8], position: Int = 0) {
        self.data = data
        self.position = position
    }

    public var remaining: Int { data.count - position }
    public var count: Int { data.count }

    public mutating func seek(_ offset: Int) throws {
        guard offset >= 0, offset <= data.count else {
            throw ParseError(op: "seek", offset: offset, need: 0, have: data.count)
        }
        position = offset
    }

    public func slice(offset: Int, length: Int) throws -> ArraySlice<UInt8> {
        guard offset >= 0, length >= 0, offset <= data.count - length else {
            throw ParseError(op: "slice", offset: offset, need: length, have: data.count - offset)
        }
        return data[offset ..< offset + length]
    }

    public mutating func readBytes(_ n: Int) throws -> [UInt8] {
        let start = position
        do {
            let out = try slice(offset: start, length: n)
            position += n
            return Array(out)
        } catch {
            throw ParseError(op: "read-bytes", offset: start, need: n, have: data.count - start)
        }
    }

    public mutating func readU8() throws -> UInt8 {
        try readBytes(1)[0]
    }

    public mutating func readU16BE() throws -> UInt16 {
        let b = try readBytes(2)
        return UInt16(b[0]) << 8 | UInt16(b[1])
    }

    public mutating func readU32BE() throws -> UInt32 {
        let b = try readBytes(4)
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }

    public mutating func readU64BE() throws -> UInt64 {
        let b = try readBytes(8)
        var value: UInt64 = 0
        for byte in b { value = value << 8 | UInt64(byte) }
        return value
    }
}
