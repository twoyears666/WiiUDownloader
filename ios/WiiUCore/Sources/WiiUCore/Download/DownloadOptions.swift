import Foundation

/// Options controlling a single file download. Port of the Go `downloadOptions`.
public struct DownloadOptions {
    /// Exact byte count the CDN should serve, or 0 when unknown.
    public var expectedSize: Int64
    public var doRetries: Bool
    public var allowResume: Bool
    public var segmentSize: Int64
    public var userAgent: String
    /// Optional post-download validation of the finished file.
    public var validate: ((URL) throws -> Void)?

    public init(
        expectedSize: Int64 = 0,
        doRetries: Bool = false,
        allowResume: Bool = true,
        segmentSize: Int64 = 0,
        userAgent: String = "WiiUDownloader",
        validate: ((URL) throws -> Void)? = nil
    ) {
        self.expectedSize = expectedSize
        self.doRetries = doRetries
        self.allowResume = allowResume
        self.segmentSize = segmentSize
        self.userAgent = userAgent
        self.validate = validate
    }
}
