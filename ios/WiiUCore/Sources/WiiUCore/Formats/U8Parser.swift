import Foundation

// MARK: - U8 model
// Port of `internal/formats/u8/parser.go`.

private let u8MaxNodes: UInt32 = 100_000
private let u8MaxFileSize: UInt32 = 100 * 1024 * 1024
private let u8MaxStackSize = 4096

/// Directory node type marker in a U8 archive.
private let u8DirectoryType: UInt16 = 0x0100

/// One node in the U8 node table (0x0C bytes each).
public struct U8Node: Sendable, Equatable {
    public var type: UInt16
    public var nameOffset: UInt16
    public var dataOffset: UInt32
    public var size: UInt32

    public init(type: UInt16, nameOffset: UInt16, dataOffset: UInt32, size: UInt32) {
        self.type = type
        self.nameOffset = nameOffset
        self.dataOffset = dataOffset
        self.size = size
    }
}

/// A parsed U8 archive. Keeps the backing buffer plus the extracted string
/// table so names can be resolved lazily via `name(of:)`.
public final class U8Archive {
    public let data: [UInt8]
    public let rootNodeOffset: UInt32
    public let headerSize: UInt32
    public let dataOffset: UInt32
    public let nodes: [U8Node]
    public let stringTable: [UInt8]
    public let stringTableStart: UInt32

    private init(
        data: [UInt8],
        rootNodeOffset: UInt32,
        headerSize: UInt32,
        dataOffset: UInt32,
        nodes: [U8Node],
        stringTable: [UInt8],
        stringTableStart: UInt32
    ) {
        self.data = data
        self.rootNodeOffset = rootNodeOffset
        self.headerSize = headerSize
        self.dataOffset = dataOffset
        self.nodes = nodes
        self.stringTable = stringTable
        self.stringTableStart = stringTableStart
    }

    /// Parses a raw U8 buffer.
    public static func parse(_ data: [UInt8]) throws -> U8Archive {
        if data.count < 16 {
            throw WiiUError.parse("invalid U8 header: too short")
        }
        let magic = readU32BE(data, 0)
        guard magic == WiiUConstants.u8Magic else {
            throw WiiUError.parse("invalid U8 magic")
        }
        let rootNodeOffset = readU32BE(data, 4)
        let headerSize = readU32BE(data, 8)
        let dataOffset = readU32BE(data, 12)

        if rootNodeOffset < 16 || Int(rootNodeOffset) + 12 > data.count {
            throw WiiUError.parse("invalid U8 root node offset: \(rootNodeOffset)")
        }
        if dataOffset < rootNodeOffset || Int(dataOffset) > data.count {
            throw WiiUError.parse("invalid U8 data offset: \(dataOffset)")
        }

        let root = parseNode(data, Int(rootNodeOffset))
        let totalNodes = root.size
        if totalNodes == 0 || totalNodes > u8MaxNodes {
            throw WiiUError.parse("invalid U8 node count: \(totalNodes)")
        }

        let nodeTableSize = totalNodes * 12
        if nodeTableSize > UInt32(data.count)
            || rootNodeOffset &+ nodeTableSize > dataOffset
            || Int(rootNodeOffset &+ nodeTableSize) > data.count
        {
            throw WiiUError.parse("invalid U8 node table bounds")
        }

        var nodes: [U8Node] = []
        nodes.reserveCapacity(Int(totalNodes))
        for i in 0 ..< totalNodes {
            let start = Int(rootNodeOffset &+ i &* 12)
            nodes.append(parseNode(data, start))
        }

        let stringTableStart = rootNodeOffset &+ nodeTableSize
        let stringTableSize = dataOffset &- stringTableStart
        if Int(stringTableStart) > data.count || Int(stringTableStart &+ stringTableSize) > data.count {
            throw WiiUError.parse("invalid U8 string table bounds")
        }
        let start = Int(stringTableStart)
        let stringTable = Array(data[start ..< start + Int(stringTableSize)])

        return U8Archive(
            data: data,
            rootNodeOffset: rootNodeOffset,
            headerSize: headerSize,
            dataOffset: dataOffset,
            nodes: nodes,
            stringTable: stringTable,
            stringTableStart: stringTableStart
        )
    }

    /// Resolves the NUL-terminated name referenced by `node`.
    public func name(of node: U8Node) throws -> String {
        guard Int(node.nameOffset) < stringTable.count else {
            throw WiiUError.parse("invalid U8 name offset: \(node.nameOffset)")
        }
        let start = Int(node.nameOffset)
        var end = start
        while end < stringTable.count && stringTable[end] != 0 {
            end += 1
        }
        if end == stringTable.count {
            throw WiiUError.parse("unterminated U8 string at \(node.nameOffset)")
        }
        return String(decoding: stringTable[start ..< end], as: UTF8.self)
    }
}

// MARK: - Node helpers

private func parseNode(_ data: [UInt8], _ offset: Int) -> U8Node {
    U8Node(
        type: readU16BE(data, offset),
        nameOffset: readU16BE(data, offset + 2),
        dataOffset: readU32BE(data, offset + 4),
        size: readU32BE(data, offset + 8)
    )
}

private func readU16BE(_ data: [UInt8], _ offset: Int) -> UInt16 {
    UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
}

private func readU32BE(_ data: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(data[offset]) << 24
        | UInt32(data[offset + 1]) << 16
        | UInt32(data[offset + 2]) << 8
        | UInt32(data[offset + 3])
}

// MARK: - Extraction

/// Extracts a U8 archive to `outputPath`, recreating its directory tree.
public func extractU8(_ data: [UInt8], to outputPath: URL) throws {
    let archive = try U8Archive.parse(data)
    let basePath = filepathAbs(outputPath.path)
    try makeDirectory(basePath)

    var currentDir = basePath
    var dirStack: [String] = [basePath]
    var breakNodes: [UInt32] = [UInt32(archive.nodes.count)]

    for i in 1 ..< UInt32(archive.nodes.count) {
        let node = archive.nodes[Int(i)]
        let name = try archive.name(of: node)
        let cleanName = try sanitizeName(name)

        if node.type == u8DirectoryType {
            let nextDir = try safeJoin(base: basePath, currentDir: currentDir, name: cleanName)
            try makeDirectory(nextDir)
            currentDir = nextDir
            dirStack.append(nextDir)
            breakNodes.append(node.size)
            if dirStack.count > u8MaxStackSize {
                throw WiiUError.extraction("U8 nesting too deep")
            }
        } else {
            if node.size > u8MaxFileSize {
                continue
            }
            let end = node.dataOffset &+ node.size
            if end < node.dataOffset || Int(end) > archive.data.count {
                throw WiiUError.extraction("U8 file node out of bounds")
            }
            let targetPath = try safeJoin(base: basePath, currentDir: currentDir, name: cleanName)
            let fileData = Data(archive.data[Int(node.dataOffset) ..< Int(end)])
            do {
                try fileData.write(to: URL(fileURLWithPath: targetPath))
            } catch {
                throw WiiUError.extraction("failed to write U8 file: \(error)")
            }
        }

        while breakNodes.count > 1 && breakNodes[breakNodes.count - 1] == i &+ 1 {
            breakNodes.removeLast()
            dirStack.removeLast()
            currentDir = dirStack[dirStack.count - 1]
        }
    }
}

// MARK: - Path safety helpers

private func makeDirectory(_ path: String) throws {
    do {
        try FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true,
            attributes: nil
        )
    } catch {
        throw WiiUError.extraction("failed to create directory: \(error)")
    }
}

private func sanitizeName(_ name: String) throws -> String {
    if name.isEmpty || name == "." {
        throw WiiUError.extraction("invalid empty U8 name")
    }
    if name.contains("\u{0}") {
        throw WiiUError.extraction("invalid U8 name")
    }
    let clean = filepathClean(name)
    if clean == "." || clean == ".." || clean.hasPrefix("../") || filepathIsAbs(clean) {
        throw WiiUError.extraction("unsafe U8 path: \"\(name)\"")
    }
    return clean
}

private func safeJoin(base: String, currentDir: String, name: String) throws -> String {
    let target = filepathClean(currentDir + "/" + name)
    let absBase = filepathAbs(base)
    let absTarget = filepathAbs(target)
    if absTarget != absBase && !absTarget.hasPrefix(absBase + "/") {
        throw WiiUError.extraction("unsafe U8 extraction path: \"\(name)\"")
    }
    return absTarget
}

private func filepathIsAbs(_ path: String) -> Bool {
    path.hasPrefix("/")
}

/// Minimal port of Go's `filepath.Clean` for POSIX paths.
private func filepathClean(_ path: String) -> String {
    if path.isEmpty {
        return "."
    }
    let rooted = path.hasPrefix("/")
    var components: [String] = []
    for component in path.split(separator: "/", omittingEmptySubsequences: true) {
        if component == "." {
            continue
        }
        if component == ".." {
            if let last = components.last, last != ".." {
                components.removeLast()
            } else if !rooted {
                components.append("..")
            }
        } else {
            components.append(String(component))
        }
    }
    let joined = components.joined(separator: "/")
    if rooted {
        return components.isEmpty ? "/" : "/" + joined
    }
    return components.isEmpty ? "." : joined
}

/// Minimal port of Go's `filepath.Abs` for POSIX paths.
private func filepathAbs(_ path: String) -> String {
    if filepathIsAbs(path) {
        return filepathClean(path)
    }
    return filepathClean(FileManager.default.currentDirectoryPath + "/" + path)
}
