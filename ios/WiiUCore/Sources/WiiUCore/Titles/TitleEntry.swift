import Foundation

// MARK: - Region bit flags

public enum MCPRegion {
    public static let japan: UInt8 = 0x01
    public static let usa: UInt8 = 0x02
    public static let europe: UInt8 = 0x04
    public static let china: UInt8 = 0x10
    public static let korea: UInt8 = 0x20
    public static let taiwan: UInt8 = 0x40
}

// MARK: - Title key types

/// Key derivation password selector, indexed into `titleKeyPasswords`.
public enum TitleKeyType {
    public static let mypass: UInt8 = 0
    public static let nintendo: UInt8 = 1
    public static let test: UInt8 = 2
    public static let digits1234567890: UInt8 = 3
    public static let lucy131211: UInt8 = 4
    public static let fbf10: UInt8 = 5
    public static let digits5678: UInt8 = 6
    public static let digits1234: UInt8 = 7
    public static let empty: UInt8 = 8
    public static let magic: UInt8 = 9
}

// MARK: - Categories

public enum TitleCategory {
    public static let game: UInt8 = 0
    public static let update: UInt8 = 1
    public static let dlc: UInt8 = 2
    public static let demo: UInt8 = 3
    public static let all: UInt8 = 4
    public static let disc: UInt8 = 5

    /// Human-readable name, matching the Go implementation's UI labels.
    public static func formatted(_ category: UInt8) -> String {
        switch category {
        case game: return "Game"
        case update: return "Update"
        case dlc: return "DLC"
        case demo: return "Demo"
        case all: return "All"
        case disc: return "Disc"
        default: return "All"
        }
    }

    public static func fromFormatted(_ value: String) -> UInt8 {
        switch value {
        case "Game": return game
        case "Update": return update
        case "DLC": return dlc
        case "Demo": return demo
        case "All": return all
        default: return all
        }
    }
}

// MARK: - Title ID high words

public enum TitleIDHigh {
    public static let game: UInt32 = 0x0005_0000
    public static let demo: UInt32 = 0x0005_0002
    public static let systemApp: UInt32 = 0x0005_0010
    public static let systemData: UInt32 = 0x0005_001B
    public static let systemApplet: UInt32 = 0x0005_0030
    public static let vwiiIOS: UInt32 = 0x0000_0007
    public static let vwiiSystemApp: UInt32 = 0x0007_0002
    public static let vwiiSystem: UInt32 = 0x0007_0008
    public static let dlc: UInt32 = 0x0005_000C
    public static let update: UInt32 = 0x0005_000E

    /// Wii-side high words used when matching vWii TMDs.
    public static let wiiSystemApp: UInt32 = 0x0001_0002
    public static let wiiSystem: UInt32 = 0x0001_0008
}

// MARK: - Title entry

/// One record in the title database.
public struct TitleEntry: Sendable, Equatable, Codable {
    public var name: String
    public var titleID: UInt64
    public var region: UInt8
    public var key: UInt8
    public var category: UInt8
    public var version: Int

    public init(
        name: String,
        titleID: UInt64,
        region: UInt8,
        key: UInt8,
        category: UInt8,
        version: Int
    ) {
        self.name = name
        self.titleID = titleID
        self.region = region
        self.key = key
        self.category = category
        self.version = version
    }

    /// Lowercase 16-digit hex title ID.
    public var titleIDString: String { String(format: "%016llx", titleID) }
}

/// `version` value selecting the newest available TMD. Any value >= 0 pins an
/// exact title version, including version 0.
public let versionLatest = -1
