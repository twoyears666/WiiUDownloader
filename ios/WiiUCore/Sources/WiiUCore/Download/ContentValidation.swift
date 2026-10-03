import Foundation

/// Validation helpers applied to downloaded artifacts. Port of `content_validation.go`.

/// The `.h3` hash tree must SHA-1 to the hash recorded in the TMD.
public func verifyH3File(_ path: URL, content: Content) throws {
    let data = [UInt8](try Data(contentsOf: path))
    let sum = Digests.sha1(data)
    guard content.hash.count >= 20, Array(content.hash[0 ..< 20]) == sum else {
        throw WiiUError.validation("H3 Hash mismatch")
    }
}

/// The downloaded `title.tmd` must describe the expected title.
public func validateTMDFile(_ path: URL, expectedTitleID: UInt64) throws {
    let data = [UInt8](try Data(contentsOf: path))
    let tmd = try parseTMD(data)
    guard titleIDsMatchTMD(expectedTitleID: expectedTitleID, actualTitleID: tmd.titleID, tmdVersion: tmd.version) else {
        throw WiiUError.validation("title.tmd title ID mismatch")
    }
}

/// The downloaded `title.tik` must carry the expected title ID and version.
public func validateTicketFile(_ path: URL, expectedTitleID: UInt64, expectedTitleVersion: UInt16) throws {
    let data = [UInt8](try Data(contentsOf: path))
    guard data.count >= ticketTitleVersionOffset + ticketTitleVersionSize else {
        throw WiiUError.validation("title.tik too small")
    }
    let gotTitleID = bigEndianU64(data, offset: ticketTitleIDOffset)
    if expectedTitleID != 0, gotTitleID != expectedTitleID {
        throw WiiUError.validation("title.tik title ID mismatch")
    }
    let gotTitleVersion = UInt16(data[ticketTitleVersionOffset]) << 8 | UInt16(data[ticketTitleVersionOffset + 1])
    if expectedTitleVersion != 0, gotTitleVersion != expectedTitleVersion {
        throw WiiUError.validation("title.tik title version mismatch")
    }
}

/// Finished file size must match the expected size when one is known.
public func finalFileSizeMatches(_ path: URL, expectedSize: Int64) throws {
    guard expectedSize > 0 else { return }
    let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
    let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
    guard size == expectedSize else {
        throw WiiUError.validation("download size mismatch: got \(size), want \(expectedSize)")
    }
}

/// vWii titles are served under a different high word than the database records,
/// so those two pairs are compared on their low word only.
public func titleIDsMatchTMD(expectedTitleID: UInt64, actualTitleID: UInt64, tmdVersion: UInt8) -> Bool {
    if expectedTitleID == 0 || actualTitleID == expectedTitleID {
        return true
    }
    if tmdVersion != tmdVersionWii {
        return false
    }
    let expectedHigh = titleIDHigh(expectedTitleID)
    let actualHigh = titleIDHigh(actualTitleID)
    switch expectedHigh {
    case TitleIDHigh.vwiiSystemApp:
        if actualHigh != TitleIDHigh.wiiSystemApp { return false }
    case TitleIDHigh.vwiiSystem:
        if actualHigh != TitleIDHigh.wiiSystem { return false }
    default:
        return false
    }
    return titleIDLow(expectedTitleID) == titleIDLow(actualTitleID)
}

func bigEndianU64(_ data: [UInt8], offset: Int) -> UInt64 {
    var value: UInt64 = 0
    for index in 0 ..< 8 { value = value << 8 | UInt64(data[offset + index]) }
    return value
}

let ticketTitleIDOffset = 476
let ticketTitleIDSize = 8
let ticketTitleVersionOffset = 486
let ticketTitleVersionSize = 2
