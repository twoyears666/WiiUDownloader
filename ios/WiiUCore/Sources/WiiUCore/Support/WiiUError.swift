import Foundation

/// Errors surfaced by the core, mirroring the Go implementation's error paths.
public enum WiiUError: Error, LocalizedError, Equatable {
    case cancelled
    case invalidTitleID(String)
    case parse(String)
    case download(String)
    case validation(String)
    case extraction(String)
    case packing(String)
    case invalidState(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Download cancelled"
        case .invalidTitleID(let detail): return "Invalid title ID: \(detail)"
        case .parse(let detail): return "Parse error: \(detail)"
        case .download(let detail): return "Download error: \(detail)"
        case .validation(let detail): return "Validation error: \(detail)"
        case .extraction(let detail): return "Extraction error: \(detail)"
        case .packing(let detail): return "Packing error: \(detail)"
        case .invalidState(let detail): return "Invalid download state: \(detail)"
        }
    }
}

/// Raised by binary parsers when a read would run past the end of the buffer.
public struct ParseError: Error, LocalizedError, Equatable {
    public let op: String
    public let offset: Int
    public let need: Int
    public let have: Int

    public init(op: String, offset: Int, need: Int, have: Int) {
        self.op = op
        self.offset = offset
        self.need = need
        self.have = have
    }

    public var errorDescription: String? {
        "\(op) failed at offset \(offset): need \(need) byte(s), have \(have)"
    }
}
