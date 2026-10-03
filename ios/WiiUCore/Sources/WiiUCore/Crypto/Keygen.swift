import Foundation

/// Keygen secret, ported verbatim from `KEYGEN_SECRET` in `keygen.go`.
private let keygenSecret = "fd040105060b111c2d49"

/// Default keygen password, ported verbatim from `keygen_pw` in `keygen.go`
/// (the ASCII bytes of "mypass").
private let keygenPassword: [UInt8] = [0x6d, 0x79, 0x70, 0x61, 0x73, 0x73]

/// Passwords indexed by title key type, ported verbatim from
/// `titleKeyPasswords` in `keygen.go`.
private let titleKeyPasswords: [UInt8: [UInt8]] = [
    TitleKeyType.mypass: Array("mypass".utf8),
    TitleKeyType.nintendo: Array("nintendo".utf8),
    TitleKeyType.test: Array("test".utf8),
    TitleKeyType.digits1234567890: Array("1234567890".utf8),
    TitleKeyType.lucy131211: Array("Lucy131211".utf8),
    TitleKeyType.fbf10: Array("fbf10".utf8),
    TitleKeyType.digits5678: Array("5678".utf8),
    TitleKeyType.digits1234: Array("1234".utf8),
    TitleKeyType.empty: [],
    TitleKeyType.magic: Array("MAGIC".utf8),
]

/// Generates a title key with the default (`mypass`) key type. Port of Go's
/// `GenerateKey`.
public func generateKey(titleID: String) throws -> [UInt8] {
    try generateKey(titleID: titleID, keyType: TitleKeyType.mypass)
}

/// Generates a title key of `keyType` for `titleID`. Port of Go's
/// `GenerateKeyWithType`.
public func generateKey(titleID: String, keyType: UInt8) throws -> [UInt8] {
    try validateTitleIDHex(titleID)
    let trimmed = trimLeadingZeroPairs(Array(titleID.utf8))

    let h = Array(keygenSecret.utf8) + trimmed

    let bhLength = h.count >> 1
    var bh = [UInt8](repeating: 0, count: bhLength)
    var i = 0
    var j = 0
    while j < bhLength {
        // Byte arithmetic wraps in Go; perform it in a wider type and truncate.
        let high = ((Int(h[i]) % 32 + 9) % 25) * 16
        let low = (Int(h[i + 1]) % 32 + 9) % 25
        bh[j] = UInt8(truncatingIfNeeded: high + low)
        i += 2
        j += 1
    }

    let md5sum = Digests.md5(bh)

    let password = titleKeyPasswords[keyType] ?? keygenPassword
    let key = Digests.pbkdf2SHA1(password: password, salt: md5sum, iterations: 20, keyLength: 16)

    let tidBytes = Array(titleID.utf8)
    var iv = [UInt8](repeating: 0, count: 16)
    i = 0
    j = 0
    while j < 8 {
        let high = ((Int(tidBytes[i]) % 32 + 9) % 25) * 16
        let low = (Int(tidBytes[i + 1]) % 32 + 9) % 25
        iv[j] = UInt8(truncatingIfNeeded: high + low)
        i += 2
        j += 1
    }
    // iv[8..<16] stays zero, matching Go's `copy(iv[8:], make([]byte, 8))`.

    return try AESPrimitives.cbcEncrypt(key, key: wiiUCommonKey, iv: iv)
}

/// Port of Go's `validateTitleIDHex`.
private func validateTitleIDHex(_ titleID: String) throws {
    let bytes = Array(titleID.utf8)
    guard bytes.count == 16 else {
        throw WiiUError.invalidTitleID("invalid title ID length: got \(bytes.count), want 16")
    }
    guard bytes.allSatisfy(isHexDigit) else {
        throw WiiUError.invalidTitleID("invalid title ID hex")
    }
}

private func isHexDigit(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"),
         UInt8(ascii: "a")...UInt8(ascii: "f"),
         UInt8(ascii: "A")...UInt8(ascii: "F"):
        return true
    default:
        return false
    }
}

/// Port of Go's `trimLeadingZeroPairs`.
private func trimLeadingZeroPairs(_ data: [UInt8]) -> [UInt8] {
    var start = 0
    while data.count - start >= 2 && data[start] == UInt8(ascii: "0") && data[start + 1] == UInt8(ascii: "0") {
        start += 2
    }
    return Array(data[start...])
}
