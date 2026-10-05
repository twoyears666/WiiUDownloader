import Foundation
import CryptoKit

/// Packs a decrypted Wii U title folder into a `.wua` archive.
///
/// `.wua` is Exzap's ZArchive container, the format Cemu uses for Wii U games.
/// The byte layout produced here mirrors `ZArchiveWriter` exactly (big-endian,
/// magic in the footer, one SHA-256 over the whole file). The one deliberate
/// difference is that every 64 KiB block is stored uncompressed: the reader
/// treats a stored block whose size equals the block size as "raw", so this
/// produces a valid archive without pulling in a zstd dependency. The trade-off
/// is output size — an uncompressed `.wua` is about as large as the title.
public enum WUAPacker {

    public struct Result: Sendable {
        public let fileURL: URL
        public let fileSize: UInt64
        public let fileCount: Int
    }

    // ZArchive layout constants (see Exzap/ZArchive, zarchivecommon.h).
    private static let blockSize = 64 * 1024
    private static let entriesPerRecord = 16
    private static let footerSize = 144
    private static let offsetRecordSize = 40
    private static let fileEntrySize = 16
    private static let readChunkSize = 1 << 20

    // MARK: - Naming helpers

    /// Per-title subfolder inside the archive, e.g. `00050000101c9300_v32`.
    /// ZArchive allows several titles per file, each in such a folder.
    public static func titleFolderName(titleID: UInt64, titleVersion: UInt16) -> String {
        String(format: "%016llx_v%d", titleID, titleVersion)
    }

    /// Default `.wua` file name for a title, e.g. `00050000101c9300_v32.wua`.
    public static func defaultFileName(titleID: UInt64, titleVersion: UInt16) -> String {
        titleFolderName(titleID: titleID, titleVersion: titleVersion) + ".wua"
    }

    /// Recovers the title ID and version from `title.tmd` in `directory`, when
    /// that NUS metadata file is still present.
    ///
    /// Only the fixed header is read: title ID at `0x18C` (big-endian u64) and
    /// title version at `0x1DC` (big-endian u16).
    public static func detectTitleInfo(in directory: URL) -> (titleID: UInt64, titleVersion: UInt16)? {
        let tmdURL = directory.appendingPathComponent("title.tmd")
        guard let data = try? Data(contentsOf: tmdURL) else { return nil }
        let bytes = [UInt8](data)
        guard bytes.count >= 0x1DE else { return nil }
        return (readU64BE(bytes, at: 0x18C), readU16BE(bytes, at: 0x1DC))
    }

    private static func readU64BE(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value = (value << 8) | UInt64(bytes[offset + index])
        }
        return value
    }

    private static func readU16BE(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    // MARK: - Packing

    /// Packs the decrypted files under `sourceDirectory` into a `.wua` at
    /// `outputURL`. The write is streamed through a temporary file in the
    /// destination folder and atomically renamed into place; on failure or
    /// cancellation the temporary file is deleted.
    ///
    /// - Parameters:
    ///   - sourceDirectory: Decrypted title folder (`code/ content/ meta/ …`).
    ///   - outputURL: Destination `.wua` path.
    ///   - titleID: Title ID used for the archive's per-title folder name.
    ///   - titleVersion: Title version used for the folder name.
    ///   - controller: Optional cancellation/pause handle.
    ///   - progress: Optional packing progress in `0...1`.
    @discardableResult
    public static func pack(
        sourceDirectory: URL,
        outputURL: URL,
        titleID: UInt64,
        titleVersion: UInt16,
        controller: OperationController? = nil,
        progress: ((Double) -> Void)? = nil
    ) throws -> Result {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw WiiUError.packing("source folder not found: \(sourceDirectory.path)")
        }

        // The archive holds a single title folder containing the decrypted tree.
        let root = Node(name: "", isFile: false)
        let titleFolder = Node(name: titleFolderName(titleID: titleID, titleVersion: titleVersion), isFile: false)
        root.children.append(titleFolder)

        let fileCount = try buildTree(
            into: titleFolder,
            sourceDirectory: sourceDirectory,
            outputURL: outputURL
        )
        guard fileCount > 0 else {
            throw WiiUError.packing("no decrypted files found in \(sourceDirectory.path)")
        }
        sortTree(root)

        // Stream order: depth-first, children already sorted, so both the file
        // offsets and the concatenated block data follow the same order.
        var files: [Node] = []
        collectFiles(root, into: &files)

        var totalData: UInt64 = 0
        for file in files {
            file.fileOffset = totalData
            totalData += file.fileSize
        }

        // Name table (deduplicated), with the byte offset of each name.
        var nameTable: [String] = []
        var nameIndexByName: [String: UInt32] = [:]
        assignNameIndexes(root, nameTable: &nameTable, lookup: &nameIndexByName)
        let nameTableData = makeNameTable(nameTable)

        // File tree: BFS order, directory children contiguous.
        let order = breadthFirstOrder(root)
        var nextIndex: UInt32 = 1
        for node in order where !node.isFile {
            node.nodeStartIndex = nextIndex
            nextIndex += UInt32(node.children.count)
        }
        let treeData = makeFileTree(order, root: root, nameTable: nameTable, nameTableData: nameTableData)

        // Exact output size, for the free-space pre-check.
        let blockCount = max(1, (totalData + UInt64(blockSize) - 1) / UInt64(blockSize))
        let compressedDataSize = UInt64(blockCount) * UInt64(blockSize)
        let alignedDataSize = (compressedDataSize + 7) & ~UInt64(7)
        let recordCount = (blockCount + UInt64(entriesPerRecord) - 1) / UInt64(entriesPerRecord)
        let requiredSize = alignedDataSize
            + recordCount * UInt64(offsetRecordSize)
            + UInt64(nameTableData.count)
            + UInt64(order.count) * UInt64(fileEntrySize)
            + UInt64(footerSize)

        let destinationDirectory = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        try ensureFreeSpace(requiredSize, at: destinationDirectory)

        // Write to a temp file in the same folder so the final rename is atomic.
        let tempURL = destinationDirectory
            .appendingPathComponent(".\(outputURL.lastPathComponent).tmp-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: tempURL.path, contents: nil) else {
            throw WiiUError.packing("cannot create temporary file at \(tempURL.path)")
        }
        let handle = try FileHandle(forWritingTo: tempURL)

        var finished = false
        defer {
            try? handle.close()
            if !finished {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }

        let writer = try ArchiveWriter(handle: handle)

        // 1. Compressed data section: every block stored uncompressed.
        var blockBuffer = Data()
        blockBuffer.reserveCapacity(blockSize)
        var records: [(base: UInt64, sizes: [UInt16])] = []

        func flushBlock(_ block: Data) throws {
            let base = writer.offset
            try writer.write(block)
            if records.isEmpty || records[records.count - 1].sizes.count == entriesPerRecord {
                records.append((base: base, sizes: []))
            }
            records[records.count - 1].sizes.append(UInt16(blockSize - 1))
        }

        func appendChunk(_ chunk: Data) throws {
            var index = chunk.startIndex
            while index < chunk.endIndex {
                let space = blockSize - blockBuffer.count
                let take = min(space, chunk.distance(from: index, to: chunk.endIndex))
                let end = chunk.index(index, offsetBy: take)
                blockBuffer.append(contentsOf: chunk[index..<end])
                index = end
                if blockBuffer.count == blockSize {
                    try flushBlock(blockBuffer)
                    blockBuffer.removeAll(keepingCapacity: true)
                }
            }
        }

        var packedBytes: UInt64 = 0
        for file in files {
            try controller?.waitIfPaused()
            if controller?.isCancelled == true { throw WiiUError.cancelled }

            guard let sourceURL = file.sourceURL else { continue }
            let source = try FileHandle(forReadingFrom: sourceURL)
            defer { try? source.close() }

            var remaining = file.fileSize
            while remaining > 0 {
                try controller?.waitIfPaused()
                if controller?.isCancelled == true { throw WiiUError.cancelled }

                let want = Int(min(remaining, UInt64(readChunkSize)))
                guard let chunk = try source.read(upToCount: want), !chunk.isEmpty else {
                    throw WiiUError.packing("unexpected end of file \(sourceURL.lastPathComponent)")
                }
                try appendChunk(chunk)
                remaining -= UInt64(chunk.count)
                packedBytes += UInt64(chunk.count)
                if totalData > 0 {
                    progress?(Double(packedBytes) / Double(totalData))
                }
            }
        }

        // Pad the trailing partial block to a full block so every stored block
        // has a uniform length. An empty title still emits one block so the
        // archive carries at least one offset record.
        if !blockBuffer.isEmpty {
            if blockBuffer.count < blockSize {
                blockBuffer.append(contentsOf: repeatElement(0, count: blockSize - blockBuffer.count))
            }
            try flushBlock(blockBuffer)
            blockBuffer.removeAll(keepingCapacity: false)
        } else if records.isEmpty {
            try flushBlock(Data(count: blockSize))
        }
        let dataSectionSize = writer.offset

        // 2. Pad the data section to an 8-byte boundary.
        while writer.offset % 8 != 0 {
            try writer.write(Data([0]))
        }

        // 3. Offset records.
        let offsetRecordsOffset = writer.offset
        var recordData = Data()
        recordData.reserveCapacity(records.count * offsetRecordSize)
        for record in records {
            var bytes = [UInt8](repeating: 0, count: offsetRecordSize)
            putU64(record.base, into: &bytes, at: 0)
            for i in 0..<entriesPerRecord {
                let value: UInt16 = i < record.sizes.count ? record.sizes[i] : 0
                putU16(value, into: &bytes, at: 8 + i * 2)
            }
            recordData.append(contentsOf: bytes)
        }
        try writer.write(recordData)
        let offsetRecordsSize = UInt64(recordData.count)

        // 4. Name table.
        let namesOffset = writer.offset
        try writer.write(nameTableData)
        let namesSize = UInt64(nameTableData.count)

        // 5. File tree.
        let treeOffset = writer.offset
        try writer.write(treeData)
        let treeSize = UInt64(treeData.count)

        // 6. Meta sections (unused by the writer, kept empty).
        let metaDirectoryOffset = writer.offset
        let metaDataOffset = writer.offset

        // 7. Footer. The SHA-256 covers everything before it plus the footer
        // itself with the hash field zeroed.
        let totalSize = writer.offset + UInt64(footerSize)
        var footer = Data()
        footer.reserveCapacity(footerSize)
        footer.append(u64BE(0)) // sectionCompressedData.offset
        footer.append(u64BE(dataSectionSize))
        footer.append(u64BE(offsetRecordsOffset))
        footer.append(u64BE(offsetRecordsSize))
        footer.append(u64BE(namesOffset))
        footer.append(u64BE(namesSize))
        footer.append(u64BE(treeOffset))
        footer.append(u64BE(treeSize))
        footer.append(u64BE(metaDirectoryOffset))
        footer.append(u64BE(0))
        footer.append(u64BE(metaDataOffset))
        footer.append(u64BE(0))
        footer.append(Data(count: 32)) // integrity hash placeholder
        footer.append(u64BE(totalSize))
        footer.append(u32BE(0x61BF3A01)) // version
        footer.append(u32BE(0x169F52D6)) // magic
        guard footer.count == footerSize else {
            throw WiiUError.packing("internal error: footer size \(footer.count)")
        }

        writer.updateHash(footer)
        let integrityHash = writer.finalizeHash()
        footer.replaceSubrange(96..<128, with: integrityHash)
        try writer.writeUnhashed(footer)

        try handle.close()

        // Atomic replace on the same volume.
        if FileManager.default.fileExists(atPath: outputURL.path) {
            _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: outputURL)
        }
        finished = true

        progress?(1.0)
        return Result(fileURL: outputURL, fileSize: totalSize, fileCount: fileCount)
    }

    // MARK: - Tree construction

    private final class Node {
        let name: String
        let isFile: Bool
        var children: [Node] = []
        var fileOffset: UInt64 = 0
        var fileSize: UInt64 = 0
        var nameIndex: UInt32 = 0
        var nodeStartIndex: UInt32 = 0
        var sourceURL: URL?

        init(name: String, isFile: Bool) {
            self.name = name
            self.isFile = isFile
        }
    }

    /// Adds every decrypted file under `directory` to `parent`, mirroring the
    /// on-disk directory structure. Returns the number of files added.
    private static func buildTree(into parent: Node, sourceDirectory: URL, outputURL: URL) throws -> Int {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: sourceDirectory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            throw WiiUError.packing("cannot scan \(sourceDirectory.path)")
        }

        let basePath = sourceDirectory.standardizedFileURL.path
        let outputPath = outputURL.standardizedFileURL.path
        // NUS metadata survives only when encrypted files were kept. Its
        // presence means root `<cid>.app`/`<cid>.h3` are still encrypted.
        let hasNUSMetadata = FileManager.default.fileExists(
            atPath: sourceDirectory.appendingPathComponent("title.tmd").path
        )
        var count = 0

        for case let url as URL in enumerator {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(basePath) else { continue }
            var relative = String(path.dropFirst(basePath.count))
            while relative.hasPrefix("/") { relative.removeFirst() }
            guard !relative.isEmpty else { continue }

            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory ?? false
            let name = url.lastPathComponent
            let components = relative.split(separator: "/").map(String.init)

            if isExcluded(
                name: name,
                isDirectory: isDirectory,
                isRootLevel: components.count == 1,
                path: path,
                outputPath: outputPath,
                hasNUSMetadata: hasNUSMetadata
            ) {
                if isDirectory { enumerator.skipDescendants() }
                continue
            }

            if isDirectory {
                _ = ensureDirectory(parent, components: components)
            } else {
                let directory = ensureDirectory(parent, components: Array(components.dropLast()))
                if directory.children.contains(where: { $0.isFile && $0.name == name }) { continue }
                let node = Node(name: name, isFile: true)
                node.fileSize = UInt64(values?.fileSize ?? 0)
                node.sourceURL = url
                directory.children.append(node)
                count += 1
            }
        }
        return count
    }

    private static func ensureDirectory(_ parent: Node, components: [String]) -> Node {
        var current = parent
        for component in components {
            if let existing = current.children.first(where: { !$0.isFile && $0.name == component }) {
                current = existing
            } else {
                let node = Node(name: component, isFile: false)
                current.children.append(node)
                current = node
            }
        }
        return current
    }

    /// NUS artifacts and existing archives are not part of the decrypted tree.
    /// Encrypted contents (`<cid>.app`/`<cid>.h3`) live only at the title root,
    /// and only while the NUS metadata is still around — once decryption
    /// overwrites them in place (raw Wii/Wii U fallback) they are the decrypted
    /// output and must be kept.
    private static func isExcluded(
        name: String,
        isDirectory: Bool,
        isRootLevel: Bool,
        path: String,
        outputPath: String,
        hasNUSMetadata: Bool
    ) -> Bool {
        if isDirectory { return false }
        if path == outputPath { return true }
        let lower = name.lowercased()
        if lower == "title.tmd" || lower == "title.tik" || lower == "title.cert" { return true }
        for ext in [".wua", ".wux"] where lower.hasSuffix(ext) { return true }
        if isRootLevel {
            if lower.hasSuffix(".h3") { return true }
            if hasNUSMetadata, isNUSContentName(lower) { return true }
        }
        return false
    }

    /// True for `<8 hex digits>.app`, the on-disk name of an NUS content.
    private static func isNUSContentName(_ lower: String) -> Bool {
        guard lower.hasSuffix(".app") else { return false }
        let stem = lower.dropLast(4)
        return stem.count == 8 && stem.allSatisfy(\.isHexDigit)
    }

    /// Sorts every directory's children case-insensitively (A-Z only, matching
    /// the format's comparison), so the file tree can be scanned linearly.
    private static func sortTree(_ node: Node) {
        if !node.children.isEmpty {
            node.children.sort { compareNames(Array($0.name.utf8), Array($1.name.utf8)) < 0 }
        }
        for child in node.children { sortTree(child) }
    }

    private static func collectFiles(_ node: Node, into files: inout [Node]) {
        for child in node.children {
            if child.isFile {
                files.append(child)
            } else {
                collectFiles(child, into: &files)
            }
        }
    }

    /// Compares two name byte strings the way ZArchive does: ASCII letters are
    /// lower-cased, everything else compares byte-wise; a prefix sorts first.
    private static func compareNames(_ a: [UInt8], _ b: [UInt8]) -> Int {
        let shared = min(a.count, b.count)
        for i in 0..<shared {
            var c1 = a[i]
            var c2 = b[i]
            if c1 >= 0x41, c1 <= 0x5A { c1 += 0x20 }
            if c2 >= 0x41, c2 <= 0x5A { c2 += 0x20 }
            if c1 != c2 { return Int(c1) - Int(c2) }
        }
        if a.count < b.count { return -1 }
        if a.count > b.count { return 1 }
        return 0
    }

    // MARK: - Name table

    private static func assignNameIndexes(_ node: Node, nameTable: inout [String], lookup: inout [String: UInt32]) {
        for child in node.children {
            if let index = lookup[child.name] {
                child.nameIndex = index
            } else {
                let index = UInt32(nameTable.count)
                nameTable.append(child.name)
                lookup[child.name] = index
                child.nameIndex = index
            }
            assignNameIndexes(child, nameTable: &nameTable, lookup: &lookup)
        }
    }

    /// Serializes the name table. Each name is prefixed with a length that is
    /// either one byte (below 0x80) or two bytes (MSB continuation).
    private static func makeNameTable(_ names: [String]) -> Data {
        var data = Data()
        for name in names {
            var bytes = Array(name.utf8)
            if bytes.count > 0x7FFF { bytes = Array(bytes.prefix(0x7FFF)) }
            if bytes.count >= 0x80 {
                data.append(UInt8(bytes.count & 0x7F) | 0x80)
                data.append(UInt8((bytes.count >> 7) & 0xFF))
            } else {
                data.append(UInt8(bytes.count & 0x7F))
            }
            data.append(contentsOf: bytes)
        }
        return data
    }

    // MARK: - File tree

    private static func breadthFirstOrder(_ root: Node) -> [Node] {
        var order: [Node] = []
        var queue: [Node] = [root]
        var head = 0
        while head < queue.count {
            let node = queue[head]
            head += 1
            order.append(node)
            if !node.isFile { queue.append(contentsOf: node.children) }
        }
        return order
    }

    private static func makeFileTree(_ order: [Node], root: Node, nameTable: [String], nameTableData: Data) -> Data {
        // Byte offset of every name inside the name table.
        var nameOffsets = [UInt32](repeating: 0, count: nameTable.count)
        var runningOffset: UInt32 = 0
        for (index, name) in nameTable.enumerated() {
            nameOffsets[index] = runningOffset
            var length = Array(name.utf8).count
            if length > 0x7FFF { length = 0x7FFF }
            runningOffset += UInt32(length >= 0x80 ? length + 2 : length + 1)
        }
        _ = nameTableData

        var data = Data()
        data.reserveCapacity(order.count * fileEntrySize)
        for node in order {
            var entry = [UInt8](repeating: 0, count: fileEntrySize)
            let nameOffset: UInt32 = (node === root) ? 0x7FFFFFFF : nameOffsets[Int(node.nameIndex)]
            var flag = nameOffset & 0x7FFFFFFF
            if node.isFile { flag |= 0x80000000 }
            putU32(flag, into: &entry, at: 0)

            if node.isFile {
                putU32(UInt32(truncatingIfNeeded: node.fileOffset), into: &entry, at: 4)
                putU32(UInt32(truncatingIfNeeded: node.fileSize), into: &entry, at: 8)
                let offsetHigh = UInt32((node.fileOffset >> 32) & 0xFFFF)
                let sizeHigh = UInt32((node.fileSize >> 16) & 0xFFFF_0000)
                putU32(offsetHigh | sizeHigh, into: &entry, at: 12)
            } else {
                putU32(node.nodeStartIndex, into: &entry, at: 4)
                putU32(UInt32(node.children.count), into: &entry, at: 8)
            }
            data.append(contentsOf: entry)
        }
        return data
    }

    // MARK: - Disk helpers

    /// Refuses to start when the destination volume clearly cannot hold the
    /// archive, so packing never dies half-way from a full disk.
    private static func ensureFreeSpace(_ requiredSize: UInt64, at directory: URL) throws {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return }
        if Int64(requiredSize) > available {
            throw WiiUError.packing(
                "not enough free space: need \(requiredSize) bytes, available \(available) bytes"
            )
        }
    }

    // MARK: - Big-endian byte helpers

    private static func putU16(_ value: UInt16, into bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 1] = UInt8(value & 0xFF)
    }

    private static func putU32(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8((value >> 24) & 0xFF)
        bytes[offset + 1] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 3] = UInt8(value & 0xFF)
    }

    private static func putU64(_ value: UInt64, into bytes: inout [UInt8], at offset: Int) {
        for i in 0..<8 {
            bytes[offset + i] = UInt8((value >> UInt64((7 - i) * 8)) & 0xFF)
        }
    }

    private static func u32BE(_ value: UInt32) -> Data {
        Data([UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    private static func u64BE(_ value: UInt64) -> Data {
        var data = Data(capacity: 8)
        for i in 0..<8 {
            data.append(UInt8((value >> UInt64((7 - i) * 8)) & 0xFF))
        }
        return data
    }
}

/// Append-only file writer that keeps a running SHA-256 of everything written,
/// so the archive's integrity hash can be produced without re-reading the file.
private final class ArchiveWriter {
    private let handle: FileHandle
    private(set) var offset: UInt64 = 0
    private var hasher = SHA256()

    init(handle: FileHandle) throws {
        self.handle = handle
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        try handle.write(contentsOf: data)
        hasher.update(data: data)
        offset += UInt64(data.count)
    }

    /// Writes without hashing (used for the footer, whose hash covers a
    /// zeroed copy of itself instead).
    func writeUnhashed(_ data: Data) throws {
        guard !data.isEmpty else { return }
        try handle.write(contentsOf: data)
        offset += UInt64(data.count)
    }

    func updateHash(_ data: Data) {
        hasher.update(data: data)
    }

    func finalizeHash() -> [UInt8] {
        Array(hasher.finalize())
    }
}
