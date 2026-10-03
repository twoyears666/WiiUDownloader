import Foundation

/// Shared constants ported from the Go implementation. Values must stay in sync
/// with Nintendo's NUS layout; do not change them without a matching reference.
public enum WiiUConstants {
    // MARK: Hashing

    /// Plain content block size.
    public static let blockSize = 0x8000
    /// Hashed content block size.
    public static let blockSizeHashed = 0x10000
    /// Payload size inside a hashed block (block minus its 0x400 hash header).
    public static let hashBlockSize = 0xFC00
    /// Size of the hash header that prefixes every hashed block.
    public static let hashesSize = 0x0400
    /// Maximum FST/directory nesting depth.
    public static let maxLevels = 0x10

    // MARK: Streaming

    /// Read chunk used while decrypting unhashed content.
    public static let readSize = 8 * 1024 * 1024
    /// Upper bound for a decrypted FST/metadata content.
    public static let maxFSTSize: Int64 = 200 * 1024 * 1024

    // MARK: Hash tree

    /// Flag on `Content.type` marking hash-tree (H3) protected content.
    public static let contentTypeHashed: UInt16 = 0x02
    /// One SHA-1 entry is 0x14 bytes.
    public static let hashEntrySize = 0x14
    /// Entries per hash level (16 wide, 16 deep, 16 tall).
    public static let hashEntriesPerLevel = 0x10

    // Decrypted 0x400 hash header layout.
    public static let hashH0Start = 0x000
    public static let hashH1Start = 0x140
    public static let hashH2Start = 0x280
    public static let hashH2End = 0x3C0

    // MARK: AES

    public static let aesBlockSize = 16

    // MARK: FST entry flags

    /// Mask extracting the name-table offset from a name field.
    public static let fstNameOffsetMask: UInt32 = 0x00FF_FFFF
    /// Directory entry marker.
    public static let fstDirectoryTypeFlag: UInt8 = 0x01
    /// Shared entries carry no extractable payload.
    public static let fstSharedContentFlag: UInt16 = 0x80
    /// When unset, entry offsets are scaled by the FST factor.
    public static let fstContentFactorFlag: UInt16 = 0x04

    // MARK: U8 archive

    public static let u8Magic: UInt32 = 0x55AA_382D
    public static let u8HeaderProbeSize = 32
    public static let u8AlignmentStep = 16
    public static let u8MagicOffsetSize = 4
}

/// Rounds `size` up to the next AES block boundary.
public func alignToAESBlockSize(_ size: UInt64) -> UInt64 {
    let mask = UInt64(WiiUConstants.aesBlockSize - 1)
    return (size + mask) & ~mask
}
