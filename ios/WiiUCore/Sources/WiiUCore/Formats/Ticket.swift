import Foundation

/// Offsets and sizes inside Nintendo's ticket binary layout, ported verbatim
/// from `ticket.go`.
public enum TicketLayout {
    public static let encryptedKeyOffset = 0x1BF
    public static let encryptedKeySize = 0x10
    public static let keyIndexOffset = 0x1F1
    public static let titleIDOffset = 476
    public static let titleIDSize = 8
    public static let titleVersionOffset = 486
    public static let titleVersionSize = 2
    /// Default key index used when the ticket does not specify one.
    public static let keyIndexUnknown: UInt8 = 0xFF
}

/// Immutable default ticket payload; runtime fields are patched at known
/// offsets. Ported verbatim from `TICKET_TEMPLATE_HEX` in `ticket.go`.
private let ticketTemplateHex = "" +
    "00010004d15ea5ed15abe11ad15ea5ed15abe11ad15ea5ed15abe11ad15ea5ed" +
    "15abe11ad15ea5ed15abe11ad15ea5ed15abe11ad15ea5ed15abe11ad15ea5ed" +
    "15abe11ad15ea5ed15abe11ad15ea5ed15abe11ad15ea5ed15abe11ad15ea5ed" +
    "15abe11ad15ea5ed15abe11ad15ea5ed15abe11ad15ea5ed15abe11ad15ea5ed" +
    "15abe11ad15ea5ed15abe11ad15ea5ed15abe11ad15ea5ed15abe11ad15ea5ed" +
    "15abe11ad15ea5ed15abe11ad15ea5ed15abe11ad15ea5ed15abe11ad15ea5ed" +
    "15abe11ad15ea5ed15abe11ad15ea5ed15abe11ad15ea5ed15abe11ad15ea5ed" +
    "15abe11ad15ea5ed15abe11ad15ea5ed15abe11ad15ea5ed15abe11ad15ea5ed" +
    "15abe11a00000000000000000000000000000000000000000000000000000000" +
    "0000000000000000000000000000000000000000000000000000000000000000" +
    "526f6f742d434130303030303030332d58533030303030303063000000000000" +
    "0000000000000000000000000000000000000000000000000000000000000000" +
    "feedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedface" +
    "feedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedface010000cc" +
    "cccccccccccccccccccccccccccccc00000000000000000000000000aaaaaaaa" +
    "aaaaaaaa00000000000000000000000000000000000000000000000000000000" +
    "0000000000000000000000000000000000000000000000000000000000000000" +
    "0001000000000000000000000000000000000000000000000000000000000000" +
    "0000000000000000000000000000000000000000000000000000000000000000" +
    "0000000000000000000000000000000000000000000000000000000000000000" +
    "0000000000000000000000000000000000000000000000000000000000000000" +
    "0000000000010014000000ac0000001400010014000000000000002800000001" +
    "00000084000000840003000000000000ffffffffffffffffffffffffffffffff" +
    "ffffffffffffffffffffffffffffffff00000000000000000000000000000000" +
    "0000000000000000000000000000000000000000000000000000000000000000" +
    "0000000000000000000000000000000000000000000000000000000000000000" +
    "00000000000000000000000000000000"

/// Decoded ticket template, computed once (Swift's `static let` is lazily
/// initialized and thread-safe, matching Go's `sync.Once`).
private enum TicketTemplate {
    static let result: Result<[UInt8], Error> = {
        do {
            let data = try decodeHex(ticketTemplateHex)

            var requiredSize = TicketLayout.encryptedKeyOffset + TicketLayout.encryptedKeySize
            if TicketLayout.keyIndexOffset + 1 > requiredSize {
                requiredSize = TicketLayout.keyIndexOffset + 1
            }
            if TicketLayout.titleIDOffset + TicketLayout.titleIDSize > requiredSize {
                requiredSize = TicketLayout.titleIDOffset + TicketLayout.titleIDSize
            }
            if TicketLayout.titleVersionOffset + TicketLayout.titleVersionSize > requiredSize {
                requiredSize = TicketLayout.titleVersionOffset + TicketLayout.titleVersionSize
            }
            if data.count < requiredSize {
                throw WiiUError.parse("ticket template too small: got \(data.count), need at least \(requiredSize)")
            }
            return .success(data)
        } catch {
            return .failure(error)
        }
    }()

    static func newData() throws -> [UInt8] {
        switch result {
        case .success(let data): return data
        case .failure(let error): throw error
        }
    }
}

/// Writes a ticket file for `titleID`, patching the encrypted title key, title
/// ID and title version into the default template. Port of Go's `GenerateTicket`.
public func generateTicket(path: URL, titleID: UInt64, titleKey: [UInt8], titleVersion: UInt16) throws {
    guard titleKey.count >= TicketLayout.encryptedKeySize else {
        throw WiiUError.validation(
            "title key must be at least \(TicketLayout.encryptedKeySize) bytes, got \(titleKey.count)"
        )
    }

    var ticketData = try TicketTemplate.newData()

    let keyStart = TicketLayout.encryptedKeyOffset
    let keyEnd = keyStart + TicketLayout.encryptedKeySize
    ticketData.replaceSubrange(keyStart..<keyEnd, with: titleKey[0..<TicketLayout.encryptedKeySize])

    let titleIDBytes = bigEndianBytes(titleID, count: TicketLayout.titleIDSize)
    let titleIDStart = TicketLayout.titleIDOffset
    let titleIDEnd = titleIDStart + TicketLayout.titleIDSize
    ticketData.replaceSubrange(titleIDStart..<titleIDEnd, with: titleIDBytes)

    let versionBytes = bigEndianBytes(UInt64(titleVersion), count: TicketLayout.titleVersionSize)
    let versionStart = TicketLayout.titleVersionOffset
    let versionEnd = versionStart + TicketLayout.titleVersionSize
    ticketData.replaceSubrange(versionStart..<versionEnd, with: versionBytes)

    try Data(ticketData).write(to: path)
}

/// Reads the encrypted title key and key index from a ticket file. Returns `nil`
/// when the file does not exist (with key index defaulting to
/// `TicketLayout.keyIndexUnknown`). Port of Go's `readTicketData`.
public func readTicketData(path: URL) throws -> (encryptedKey: [UInt8], keyIndex: UInt8)? {
    var ticketKeyIndex = TicketLayout.keyIndexUnknown

    guard FileManager.default.fileExists(atPath: path.path) else {
        return nil
    }

    let data = try Data(contentsOf: path)

    let keyStart = TicketLayout.encryptedKeyOffset
    let keyEnd = keyStart + TicketLayout.encryptedKeySize
    guard data.count >= keyEnd else {
        throw WiiUError.parse("unexpected EOF")
    }
    let encryptedTitleKey = [UInt8](data[keyStart..<keyEnd])

    guard data.count >= TicketLayout.keyIndexOffset + 1 else {
        throw WiiUError.parse("unexpected EOF")
    }
    ticketKeyIndex = data[TicketLayout.keyIndexOffset]

    return (encryptedTitleKey, ticketKeyIndex)
}

/// Encodes `value` as a big-endian byte array of `count` bytes.
private func bigEndianBytes(_ value: UInt64, count: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    for i in 0..<count {
        bytes[i] = UInt8((value >> (8 * (count - 1 - i))) & 0xFF)
    }
    return bytes
}

/// Decodes a hex string into bytes. Throws on odd length or invalid digits.
private func decodeHex(_ string: String) throws -> [UInt8] {
    let digits = Array(string.utf8)
    guard digits.count % 2 == 0 else {
        throw WiiUError.parse("invalid hex string length")
    }
    var bytes = [UInt8](repeating: 0, count: digits.count / 2)
    for i in 0..<bytes.count {
        let high = try hexValue(digits[2 * i])
        let low = try hexValue(digits[2 * i + 1])
        bytes[i] = high << 4 | low
    }
    return bytes
}

private func hexValue(_ byte: UInt8) throws -> UInt8 {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"):
        return byte - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"):
        return byte - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"):
        return byte - UInt8(ascii: "A") + 10
    default:
        throw WiiUError.parse("invalid hex digit")
    }
}
