import Foundation

/// Derives the 16-byte AES title key for a title from its ticket and the
/// matching common key. Port of `newTitleCipher` in `decryption.go`.
///
/// The Go version returns a `cipher.Block`; Swift callers only need the raw key
/// bytes, so we return them for use with `AESCBCDecryptor(key:)`.
///
/// - Parameters:
///   - ticketPath: Path to the title's `title.tik`.
///   - tmd: Parsed TMD, used for its title ID and version.
/// - Returns: The decrypted 16-byte title key.
public func newTitleCipher(ticketPath: URL, tmd: TMD) throws -> [UInt8] {
    // Go tolerates a missing ticket (returns a nil key) but then fails to build
    // the AES cipher; surface that as an extraction error instead.
    guard let ticket = try readTicketData(path: ticketPath) else {
        throw WiiUError.extraction("title ticket not found at \(ticketPath.path)")
    }

    let commonKey = chooseCommonKey(tmdVersion: tmd.version, ticketKeyIndex: ticket.keyIndex)
    let decryptor = try AESCBCDecryptor(key: commonKey)

    // IV = title ID as a big-endian 64-bit value, zero-padded to the AES block.
    var iv = [UInt8](repeating: 0, count: WiiUConstants.aesBlockSize)
    let titleIDBytes = bigEndianUInt64Bytes(tmd.titleID)
    let copyCount = min(WiiUConstants.aesBlockSize, titleIDBytes.count)
    iv.replaceSubrange(0 ..< copyCount, with: titleIDBytes[0 ..< copyCount])

    let decryptedTitleKey = try decryptor.decrypt(ticket.encryptedKey, iv: iv)
    guard decryptedTitleKey.count >= WiiUConstants.aesBlockSize else {
        throw WiiUError.extraction("decrypted title key is shorter than the AES block size")
    }
    return Array(decryptedTitleKey[0 ..< WiiUConstants.aesBlockSize])
}

/// Selects the common key used to unwrap a title key. Port of `chooseCommonKey`.
///
/// Wii titles use one of the three Wii common keys selected by the ticket's key
/// index (falling back to index 0); Wii U titles always use the Wii U common key.
public func chooseCommonKey(tmdVersion: UInt8, ticketKeyIndex: UInt8) -> [UInt8] {
    if tmdVersion == tmdVersionWii {
        return wiiCommonKeys[ticketKeyIndex] ?? wiiCommonKeys[0] ?? []
    }
    return wiiUCommonKey
}

/// Big-endian 8-byte representation of `value`.
private func bigEndianUInt64Bytes(_ value: UInt64) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: 8)
    var remaining = value
    for index in stride(from: 7, through: 0, by: -1) {
        out[index] = UInt8(truncatingIfNeeded: remaining)
        remaining >>= 8
    }
    return out
}
