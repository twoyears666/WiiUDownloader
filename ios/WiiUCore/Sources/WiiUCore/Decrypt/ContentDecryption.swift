import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - File handle helpers

/// Low-level helpers bridging Go's `*os.File` behavior onto `FileHandle`.
///
/// Go reads/writes exactly N bytes (`io.ReadFull`) and can ask a file for its
/// size (`Stat`) without moving the read cursor. Foundation's `FileHandle` has
/// no direct `Stat`, so `size(of:)` saves and restores the offset.
enum DecryptFileIO {
    /// Reads exactly `count` bytes, throwing on EOF. Port of `io.ReadFull`.
    static func readFull(_ handle: FileHandle, count: Int) throws -> [UInt8] {
        guard count > 0 else { return [] }
        var result = [UInt8]()
        result.reserveCapacity(count)
        while result.count < count {
            let need = count - result.count
            guard let chunk = try handle.read(upToCount: need), !chunk.isEmpty else {
                throw WiiUError.extraction("unexpected end of file while reading \(count) byte(s)")
            }
            result.append(contentsOf: chunk)
        }
        return result
    }

    /// Reads from the current offset to EOF.
    static func readAll(_ handle: FileHandle) throws -> [UInt8] {
        let data = try handle.readToEnd() ?? Data()
        return [UInt8](data)
    }

    /// File size in bytes; the read cursor is preserved.
    static func size(of handle: FileHandle) throws -> Int64 {
        let saved = try handle.offset()
        let end = try handle.seekToEnd()
        try handle.seek(toOffset: saved)
        return Int64(end)
    }

    /// Writes the whole buffer to `handle`.
    static func writeAll(_ handle: FileHandle, _ bytes: [UInt8]) throws {
        try handle.write(contentsOf: Data(bytes))
    }

    /// Resolves the on-disk path backing an open `FileHandle`.
    ///
    /// Go can call `os.File.Name()` to locate a sibling `.h3` file. Foundation
    /// exposes no public equivalent, so we recover the path through libSystem's
    /// `F_GETPATH` (the fixed-arity symbol behind the variadic C `fcntl`).
    static func path(of handle: FileHandle) -> String? {
        #if canImport(Darwin)
        let fd = handle.fileDescriptor
        guard fd >= 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let result: Int32 = buffer.withUnsafeMutableBufferPointer { pointer in
            sysFcntl(fd, F_GETPATH, UnsafeMutableRawPointer(pointer.baseAddress))
        }
        guard result != -1, buffer.first != 0 else { return nil }
        return String(cString: buffer)
        #else
        return nil
        #endif
    }

    /// Creates (or truncates) `path` and opens it for writing.
    static func createForWriting(at path: URL) throws -> FileHandle {
        FileManager.default.createFile(atPath: path.path, contents: nil)
        let handle = try FileHandle(forWritingTo: path)
        try handle.truncate(atOffset: 0)
        return handle
    }
}

#if canImport(Darwin)
/// Fixed-arity binding for the C symbol `fcntl`, which is variadic in the SDK
/// headers and therefore unavailable to Swift as-is. Only F_GETPATH is used.
@_silgen_name("fcntl")
private func sysFcntl(_ fd: Int32, _ cmd: Int32, _ ptr: UnsafeMutableRawPointer?) -> Int32
#endif

// MARK: - Hash tree helpers

/// Returns the 0x14-byte SHA-1 entry at `index`. Mirrors Go's `hashEntryAt`.
///
/// Go would panic on an out-of-range index; we return an empty slice instead so
/// the caller's hash comparison fails cleanly.
func hashEntryAt(_ data: [UInt8], index: Int64) -> ArraySlice<UInt8> {
    let start = Int(index) * WiiUConstants.hashEntrySize
    let end = start + WiiUConstants.hashEntrySize
    guard start >= 0, end <= data.count else {
        return data[data.count ..< data.count]
    }
    return data[start ..< end]
}

/// Advances the H0..H3 indices, carrying into the next level every 0x10 entries.
/// Mirrors Go's `advanceHashIndices`.
func advanceHashIndices(
    h0: Int64,
    h1: Int64,
    h2: Int64,
    h3: Int64
) -> (h0: Int64, h1: Int64, h2: Int64, h3: Int64) {
    var h0 = h0
    var h1 = h1
    var h2 = h2
    var h3 = h3
    h0 += 1
    if h0 >= Int64(WiiUConstants.hashEntriesPerLevel) {
        h0 = 0
        h1 += 1
    }
    if h1 >= Int64(WiiUConstants.hashEntriesPerLevel) {
        h1 = 0
        h2 += 1
    }
    if h2 >= Int64(WiiUConstants.hashEntriesPerLevel) {
        h2 = 0
        h3 += 1
    }
    return (h0, h1, h2, h3)
}

// MARK: - Content decryption

/// Decrypts one content file into memory. Port of `decryptContentToBuffer`.
///
/// Hashed (H3) contents are verified against their full hash tree; plain
/// contents are either returned verbatim when already decrypted or decrypted
/// with the content's index as IV and checked against `content.hash`.
public func decryptContentToBuffer(
    encryptedFile: FileHandle,
    content: Content,
    titleKey: [UInt8]
) throws -> [UInt8] {
    let hasHashTree = content.type & WiiUConstants.contentTypeHashed != 0
    let encryptedSize = try DecryptFileIO.size(of: encryptedFile)

    var growSize = Int64(content.size)
    if hasHashTree { growSize = encryptedSize }
    if growSize > WiiUConstants.maxFSTSize {
        throw WiiUError.extraction("FST size \(growSize) exceeds maximum limit of \(WiiUConstants.maxFSTSize)")
    }

    let decryptor = try AESCBCDecryptor(key: titleKey)

    if hasHashTree {
        return try decryptHashedContent(
            encryptedFile: encryptedFile,
            content: content,
            encryptedSize: encryptedSize,
            decryptor: decryptor
        )
    }
    return try decryptPlainContent(encryptedFile: encryptedFile, content: content, decryptor: decryptor)
}

/// H3 hash-tree path: validates H0/H1/H2/H3 each block and concatenates the
/// decrypted 0x400 hash header with its 0xFC00 payload.
private func decryptHashedContent(
    encryptedFile: FileHandle,
    content: Content,
    encryptedSize: Int64,
    decryptor: AESCBCDecryptor
) throws -> [UInt8] {
    let chunkCount = encryptedSize / Int64(WiiUConstants.blockSizeHashed)

    guard let sourcePath = DecryptFileIO.path(of: encryptedFile) else {
        throw WiiUError.extraction("cannot resolve directory of \(content.cidStr).app")
    }
    let directory = (sourcePath as NSString).deletingLastPathComponent
    let h3URL = URL(fileURLWithPath: directory).appendingPathComponent(content.cidStr + ".h3")
    let h3Data = [UInt8](try Data(contentsOf: h3URL))

    let h3DataSHASum = Digests.sha1(h3Data)
    guard content.hash.count >= 20, h3DataSHASum == Array(content.hash[0 ..< 20]) else {
        throw WiiUError.extraction("H3 Hash mismatch")
    }

    var h0HashNum: Int64 = 0
    var h1HashNum: Int64 = 0
    var h2HashNum: Int64 = 0
    var h3HashNum: Int64 = 0

    let zeroIV = [UInt8](repeating: 0, count: WiiUConstants.aesBlockSize)
    var output = [UInt8]()
    output.reserveCapacity(Int(encryptedSize))

    try encryptedFile.seek(toOffset: 0)

    var chunkNum: Int64 = 0
    while chunkNum < chunkCount {
        let hashesCipher = try DecryptFileIO.readFull(encryptedFile, count: WiiUConstants.hashesSize)
        let hashes = try decryptor.decrypt(hashesCipher, iv: zeroIV)

        let h0Hashes = Array(hashes[WiiUConstants.hashH0Start ..< WiiUConstants.hashH1Start])
        let h1Hashes = Array(hashes[WiiUConstants.hashH1Start ..< WiiUConstants.hashH2Start])
        let h2Hashes = Array(hashes[WiiUConstants.hashH2Start ..< WiiUConstants.hashH2End])

        let h0Hash = Array(hashEntryAt(h0Hashes, index: h0HashNum))
        let h1Hash = Array(hashEntryAt(h1Hashes, index: h1HashNum))
        let h2Hash = Array(hashEntryAt(h2Hashes, index: h2HashNum))
        let h3Hash = Array(hashEntryAt(h3Data, index: h3HashNum))

        guard Digests.sha1(h0Hashes) == h1Hash else {
            throw WiiUError.extraction("h0 Hashes Hash mismatch")
        }
        guard Digests.sha1(h1Hashes) == h2Hash else {
            throw WiiUError.extraction("h1 Hashes Hash mismatch")
        }
        guard Digests.sha1(h2Hashes) == h3Hash else {
            throw WiiUError.extraction("h2 Hashes Hash mismatch")
        }

        var dataBuffer = try DecryptFileIO.readFull(encryptedFile, count: WiiUConstants.hashBlockSize)
        let dataIV = Array(h0Hash[0 ..< WiiUConstants.aesBlockSize])
        try decryptor.decryptInPlace(&dataBuffer, iv: dataIV)

        let decryptedDataHash = Digests.sha1(dataBuffer)
        guard decryptedDataHash == h0Hash else {
            throw WiiUError.extraction("data block hash invalid")
        }

        output.append(contentsOf: hashes)
        output.append(contentsOf: dataBuffer)

        (h0HashNum, h1HashNum, h2HashNum, h3HashNum) =
            advanceHashIndices(h0: h0HashNum, h1: h1HashNum, h2: h2HashNum, h3: h3HashNum)
        chunkNum += 1
    }
    return output
}

/// Plain (non-hashed) path: use the already-decrypted file when its SHA-1
/// matches, otherwise AES-CBC decrypt with `content.index` as IV.
private func decryptPlainContent(
    encryptedFile: FileHandle,
    content: Content,
    decryptor: AESCBCDecryptor
) throws -> [UInt8] {
    if content.hash.count >= 20 {
        try encryptedFile.seek(toOffset: 0)
        let whole = try DecryptFileIO.readAll(encryptedFile)
        if Array(content.hash[0 ..< 20]) == Digests.sha1(whole) {
            return whole
        }
    }

    try encryptedFile.seek(toOffset: 0)

    var contentIV = [UInt8](repeating: 0, count: WiiUConstants.aesBlockSize)
    let ivCopyCount = min(WiiUConstants.aesBlockSize, content.index.count)
    contentIV.replaceSubrange(0 ..< ivCopyCount, with: content.index[0 ..< ivCopyCount])

    var contentHash = [UInt8]()
    var left = content.size
    var leftHash = content.size
    var cbcIV = contentIV

    var output = [UInt8]()
    output.reserveCapacity(Int(content.size))

    let readSize = UInt64(WiiUConstants.readSize)
    let iterations = Int(content.size / readSize) + 2
    for _ in 0 ..< iterations {
        let toRead = min(readSize, left)
        let toReadHash = min(readSize, leftHash)
        let toReadAligned = Int(alignToAESBlockSize(toRead))

        let chunk = try DecryptFileIO.readFull(encryptedFile, count: toReadAligned)
        let decrypted = toReadAligned == 0 ? [] : try decryptor.decrypt(chunk, iv: cbcIV)
        // The next block's IV is the trailing ciphertext block.
        cbcIV = Array(chunk.suffix(WiiUConstants.aesBlockSize))

        contentHash.append(contentsOf: decrypted[0 ..< Int(toReadHash)])
        output.append(contentsOf: decrypted[0 ..< Int(toRead)])

        left -= toRead
        leftHash -= toReadHash
        if left == 0 { break }
    }

    // `contentHash` holds the decrypted plaintext; the TMD stores its SHA-1, so
    // the digest must be taken before comparing (Go keeps a rolling hasher here).
    if content.hash.count >= 20, Digests.sha1(contentHash) != Array(content.hash[0 ..< 20]) {
        throw WiiUError.extraction("content hash mismatch")
    }
    return output
}

// MARK: - Range extraction

/// Extracts a byte range of a plain (non-hashed) content. Port of `extractFile`.
///
/// Reads BLOCK_SIZE-aligned chunks and keeps CBC chaining manually by feeding
/// the previous chunk's trailing ciphertext block as the next IV.
func extractFile(
    src: FileHandle,
    partDataOffset: UInt64,
    fileOffset: UInt64,
    size: UInt64,
    path: URL,
    contentID: UInt16,
    titleKey: [UInt8]
) throws {
    var writeSize = WiiUConstants.blockSize
    var remaining = size

    let destination = try DecryptFileIO.createForWriting(at: path)
    defer { try? destination.close() }

    var readOffset = fileOffset / UInt64(WiiUConstants.blockSize) * UInt64(WiiUConstants.blockSize)
    var subOffset = fileOffset - (fileOffset / UInt64(WiiUConstants.blockSize) * UInt64(WiiUConstants.blockSize))
    if subOffset + remaining > UInt64(writeSize) {
        writeSize -= Int(subOffset)
    }

    try src.seek(toOffset: partDataOffset + readOffset)

    var iv = [UInt8](repeating: 0, count: WiiUConstants.aesBlockSize)
    iv[1] = UInt8(truncatingIfNeeded: contentID)

    let decryptor = try AESCBCDecryptor(key: titleKey)
    let fileSize = try DecryptFileIO.size(of: src)

    // Reused across chunks, exactly like Go's pooled BLOCK_SIZE buffer.
    var decryptedBuffer = [UInt8](repeating: 0, count: WiiUConstants.blockSize)

    while remaining > 0 {
        if UInt64(writeSize) > remaining { writeSize = Int(remaining) }

        let currentPos = Int64(partDataOffset + readOffset)
        let remainingFile = fileSize - currentPos
        if remainingFile <= 0 {
            throw WiiUError.extraction("unexpected end of file")
        }

        var readLen = WiiUConstants.blockSize
        if Int64(readLen) > remainingFile { readLen = Int(remainingFile) }
        if readLen % WiiUConstants.aesBlockSize != 0 {
            throw WiiUError.extraction("read length \(readLen) is not a multiple of AES block size")
        }

        let encrypted = try DecryptFileIO.readFull(src, count: readLen)
        let decryptedChunk = try decryptor.decrypt(encrypted, iv: iv)
        decryptedBuffer.replaceSubrange(0 ..< decryptedChunk.count, with: decryptedChunk)
        iv = Array(encrypted.suffix(WiiUConstants.aesBlockSize))

        try DecryptFileIO.writeAll(destination, Array(decryptedBuffer[Int(subOffset) ..< (Int(subOffset) + writeSize)]))
        remaining -= UInt64(writeSize)

        if subOffset != 0 {
            writeSize = WiiUConstants.blockSize
            subOffset = 0
        }
        readOffset += UInt64(WiiUConstants.blockSize)
    }
}

/// Extracts a byte range of an H3-hashed content, validating each hash header.
/// Port of `extractFileHash`.
func extractFileHash(
    src: FileHandle,
    partDataOffset: UInt64,
    fileOffset: UInt64,
    size: UInt64,
    path: URL,
    contentID: UInt16,
    titleKey: [UInt8]
) throws {
    var writeSize = WiiUConstants.hashBlockSize
    var blockNumber = Int((fileOffset / UInt64(WiiUConstants.hashBlockSize)) & UInt64(WiiUConstants.hashEntriesPerLevel - 1))
    var remaining = size

    let destination = try DecryptFileIO.createForWriting(at: path)
    defer { try? destination.close() }

    var readOffset = fileOffset / UInt64(WiiUConstants.hashBlockSize) * UInt64(WiiUConstants.blockSizeHashed)
    var subOffset = fileOffset - (fileOffset / UInt64(WiiUConstants.hashBlockSize) * UInt64(WiiUConstants.hashBlockSize))
    if subOffset + remaining > UInt64(writeSize) {
        writeSize -= Int(subOffset)
    }

    try src.seek(toOffset: partDataOffset + readOffset)

    let fileSize = try DecryptFileIO.size(of: src)
    let decryptor = try AESCBCDecryptor(key: titleKey)

    var iv = [UInt8](repeating: 0, count: WiiUConstants.aesBlockSize)
    iv[1] = UInt8(truncatingIfNeeded: contentID)

    while remaining > 0 {
        if UInt64(writeSize) > remaining { writeSize = Int(remaining) }

        let currentPos = Int64(partDataOffset + readOffset)
        let remainingFile = fileSize - currentPos
        if remainingFile <= 0 {
            throw WiiUError.extraction("unexpected end of file")
        }

        var readLen = WiiUConstants.blockSizeHashed
        if Int64(readLen) > remainingFile { readLen = Int(remainingFile) }
        if readLen % WiiUConstants.aesBlockSize != 0 {
            throw WiiUError.extraction("read length \(readLen) is not a multiple of AES block size")
        }
        if readLen < WiiUConstants.hashesSize {
            throw WiiUError.extraction("unexpected end of file")
        }

        let encrypted = try DecryptFileIO.readFull(src, count: readLen)

        // Decrypt the 0x400 hash header with IV[1] = contentID.
        let hashes = try decryptor.decrypt(Array(encrypted[0 ..< WiiUConstants.hashesSize]), iv: iv)

        let h0Start = WiiUConstants.hashEntrySize * blockNumber
        let h0Hash = Array(hashes[h0Start ..< (h0Start + 20)])
        var ivBlock = Array(hashes[h0Start ..< (h0Start + WiiUConstants.aesBlockSize)])
        if blockNumber == 0 {
            ivBlock[1] ^= UInt8(truncatingIfNeeded: contentID)
        }

        // Decrypt the payload; only readLen - HASHES_SIZE bytes are meaningful,
        // the tail stays zeroed exactly like Go clears the buffer remainder.
        var dataBuffer = [UInt8](repeating: 0, count: WiiUConstants.hashBlockSize)
        let encryptedData = Array(encrypted[WiiUConstants.hashesSize ..< readLen])
        let decryptedData = try decryptor.decrypt(encryptedData, iv: ivBlock)
        dataBuffer.replaceSubrange(0 ..< decryptedData.count, with: decryptedData)

        var dataHash = Digests.sha1(dataBuffer)
        if blockNumber == 0 {
            dataHash[1] ^= UInt8(truncatingIfNeeded: contentID)
        }
        guard dataHash == h0Hash else {
            throw WiiUError.extraction("h0 hash mismatch")
        }

        try DecryptFileIO.writeAll(destination, Array(dataBuffer[Int(subOffset) ..< (Int(subOffset) + writeSize)]))
        remaining -= UInt64(writeSize)

        blockNumber += 1
        if blockNumber >= WiiUConstants.hashEntriesPerLevel { blockNumber = 0 }
        if subOffset != 0 {
            writeSize = WiiUConstants.hashBlockSize
            subOffset = 0
        }
        readOffset += UInt64(WiiUConstants.blockSizeHashed)
    }
}

/// Reads a big-endian UInt32 from `data` at `offset`.
func readBigEndianUInt32(_ data: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(data[offset]) << 24
        | UInt32(data[offset + 1]) << 16
        | UInt32(data[offset + 2]) << 8
        | UInt32(data[offset + 3])
}
