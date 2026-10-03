import Foundation

// MARK: - Custom Codable for TitleEntry
//
// The synthesised conformance is overridden here so that the title ID is
// serialised as a 16-digit lowercase hexadecimal string (matching the wire
// format used by the Go implementation), while the remaining fields stay
// numeric.

extension TitleEntry {
    private enum CodingKeys: String, CodingKey {
        case name
        case titleID
        case region
        case key
        case category
        case version
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.name = try container.decode(String.self, forKey: .name)

        let hexTitleID = try container.decode(String.self, forKey: .titleID)
        guard let parsedTitleID = UInt64(hexTitleID, radix: 16) else {
            throw DecodingError.dataCorruptedError(
                forKey: .titleID,
                in: container,
                debugDescription: "Invalid hexadecimal title ID: \(hexTitleID)"
            )
        }
        self.titleID = parsedTitleID

        self.region = try container.decode(UInt8.self, forKey: .region)
        self.key = try container.decode(UInt8.self, forKey: .key)
        self.category = try container.decode(UInt8.self, forKey: .category)
        self.version = try container.decode(Int.self, forKey: .version)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(titleIDString, forKey: .titleID)
        try container.encode(region, forKey: .region)
        try container.encode(key, forKey: .key)
        try container.encode(category, forKey: .category)
        try container.encode(version, forKey: .version)
    }
}

// MARK: - Title database

/// Thread-safe store for the title database, mirroring the global
/// `TitleDatabase`/`SetTitleDatabase` pair from the Go implementation.
///
/// A `titleID -> entry` index is built lazily on first lookup and invalidated
/// whenever the entry list is replaced.
public final class TitleDatabase: @unchecked Sendable {
    /// Process-wide shared database.
    public static let shared = TitleDatabase()

    private let lock = NSLock()
    private var storedEntries: [TitleEntry] = []
    private var index: [UInt64: TitleEntry]?

    public init() {}

    /// Currently installed entries. Assigning a new value invalidates the index.
    public private(set) var entries: [TitleEntry] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedEntries
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storedEntries = newValue
            index = nil
        }
    }

    /// Replaces the whole database, invalidating the lazily-built index.
    public func setEntries(_ entries: [TitleEntry]) {
        self.entries = entries
    }

    /// Loads entries from a JSON file at `url`.
    public func load(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode([TitleEntry].self, from: data)
        setEntries(decoded)
    }

    /// Loads the bundled `Resources/titles.json`.
    public func loadBundled() throws {
        guard let url = Bundle.module.url(forResource: "titles", withExtension: "json") else {
            throw NSError(
                domain: "WiiUCore.TitleDatabase",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Bundled resource titles.json was not found"]
            )
        }
        try load(from: url)
    }

    /// Returns every installed entry (including discs), in insertion order.
    public func allEntries() -> [TitleEntry] {
        return entries
    }

    /// Returns entries of the given category, always skipping discs.
    ///
    /// Passing `TitleCategory.all` returns every non-disc entry.
    public func entries(category: UInt8) -> [TitleEntry] {
        let snapshot = entries
        var result: [TitleEntry] = []
        result.reserveCapacity(snapshot.count)
        for entry in snapshot {
            if entry.category == TitleCategory.disc {
                continue
            }
            if category == TitleCategory.all || category == entry.category {
                result.append(entry)
            }
        }
        return result
    }

    /// Looks up an entry by exact title ID, excluding disc entries.
    ///
    /// The index is built lazily. When several entries share a title ID the
    /// first one encountered wins.
    public func entry(forTitleID titleID: UInt64) -> TitleEntry? {
        lock.lock()
        defer { lock.unlock() }
        if index == nil {
            buildIndexLocked()
        }
        return index?[titleID]
    }

    private func buildIndexLocked() {
        var built = [UInt64: TitleEntry](minimumCapacity: storedEntries.count)
        for entry in storedEntries {
            if entry.category == TitleCategory.disc {
                continue
            }
            if built[entry.titleID] == nil {
                built[entry.titleID] = entry
            }
        }
        index = built
    }
}
