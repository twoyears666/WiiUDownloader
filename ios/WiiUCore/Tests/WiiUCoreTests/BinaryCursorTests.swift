import XCTest
@testable import WiiUCore

final class BinaryCursorTests: XCTestCase {
    func testReadsBigEndianIntegers() throws {
        var cursor = BinaryCursor([0x01, 0x02, 0x00, 0x00, 0x00, 0x03, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x04])
        XCTAssertEqual(try cursor.readU8(), 0x01)
        XCTAssertEqual(try cursor.readU8(), 0x02)
        XCTAssertEqual(try cursor.readU32BE(), 3)
        XCTAssertEqual(try cursor.readU64BE(), 4)
        XCTAssertEqual(cursor.remaining, 0)
    }

    func testReadPastEndThrows() {
        var cursor = BinaryCursor([0x00])
        XCTAssertThrowsError(try cursor.readU32BE())
    }

    func testAlignToAESBlockSize() {
        XCTAssertEqual(alignToAESBlockSize(0), 0)
        XCTAssertEqual(alignToAESBlockSize(1), 16)
        XCTAssertEqual(alignToAESBlockSize(16), 16)
        XCTAssertEqual(alignToAESBlockSize(17), 32)
    }

    func testH3SizeOnlyForHashedContent() {
        let plain = Content(id: 1, index: [0, 0], type: 0, size: 100, hash: [])
        XCTAssertEqual(expectedH3DownloadSize(plain), 0)

        let hashed = Content(id: 1, index: [0, 0], type: WiiUConstants.contentTypeHashed, size: UInt64(WiiUConstants.blockSizeHashed), hash: [])
        XCTAssertEqual(expectedH3DownloadSize(hashed), Int64(WiiUConstants.hashEntrySize))
    }
}
