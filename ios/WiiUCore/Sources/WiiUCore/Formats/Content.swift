import Foundation

/// One content entry from a title's TMD.
public struct Content: Sendable, Equatable {
    public var id: UInt32
    /// Two-byte content index, used as part of the content's AES IV.
    public var index: [UInt8]
    public var type: UInt16
    public var size: UInt64
    public var hash: [UInt8]
    /// Uppercase 8-digit hex ID, matching the file name on the CDN.
    public var cidStr: String

    public init(
        id: UInt32,
        index: [UInt8],
        type: UInt16,
        size: UInt64,
        hash: [UInt8],
        cidStr: String = ""
    ) {
        self.id = id
        self.index = index
        self.type = type
        self.size = size
        self.hash = hash
        self.cidStr = cidStr
    }

    /// Whether this content is protected by an H3 hash tree.
    public var isHashed: Bool { type & WiiUConstants.contentTypeHashed != 0 }

    /// Index interpreted as a big-endian UInt16.
    public var indexU16: UInt16 {
        guard index.count >= 2 else { return 0 }
        return UInt16(index[0]) << 8 | UInt16(index[1])
    }

    /// Number of bytes the CDN serves for this content, including its hash tree.
    public var downloadSize: Int64 {
        expectedContentDownloadSize(self) + expectedH3DownloadSize(self)
    }
}

/// Payload size the CDN serves for a content body (hashed bodies are stored
/// padded to hashed blocks, plain bodies padded to AES blocks).
public func expectedContentDownloadSize(_ content: Content) -> Int64 {
    if content.type & WiiUConstants.contentTypeHashed == WiiUConstants.contentTypeHashed {
        return Int64(content.size)
    }
    return Int64(alignToAESBlockSize(content.size))
}

/// Size of the `.h3` hash-tree file the CDN serves, or 0 for plain content.
public func expectedH3DownloadSize(_ content: Content) -> Int64 {
    guard content.type & WiiUConstants.contentTypeHashed != 0 else { return 0 }
    let chunkCount = (content.size + UInt64(WiiUConstants.blockSizeHashed) - 1) / UInt64(WiiUConstants.blockSizeHashed)
    let level3 = UInt64(WiiUConstants.hashEntriesPerLevel * WiiUConstants.hashEntriesPerLevel * WiiUConstants.hashEntriesPerLevel)
    let h3Entries = (chunkCount + level3 - 1) / level3
    return Int64(h3Entries) * Int64(WiiUConstants.hashEntrySize)
}
