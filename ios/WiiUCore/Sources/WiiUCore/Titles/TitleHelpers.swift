import Foundation

// MARK: - Title ID accessors

/// High 32 bits of a 64-bit title ID.
public func titleIDHigh(_ titleID: UInt64) -> UInt32 {
    return UInt32(truncatingIfNeeded: titleID >> 32)
}

/// Low 32 bits of a 64-bit title ID.
public func titleIDLow(_ titleID: UInt64) -> UInt32 {
    return UInt32(truncatingIfNeeded: titleID & 0xFFFF_FFFF)
}

// MARK: - Formatting

/// Human-readable region list built from the region bit flags.
///
/// Order is USA, Europe, Japan. Three matches yield "All" and no match yields
/// "Unknown"; otherwise the names are joined with "/".
public func formattedRegion(_ region: UInt8) -> String {
    var regions: [String] = []
    if region & MCPRegion.usa != 0 {
        regions.append("USA")
    }
    if region & MCPRegion.europe != 0 {
        regions.append("Europe")
    }
    if region & MCPRegion.japan != 0 {
        regions.append("Japan")
    }

    switch regions.count {
    case 0:
        return "Unknown"
    case 3:
        return "All"
    default:
        return regions.joined(separator: "/")
    }
}

/// Human-readable kind derived from the high word of a title ID.
public func formattedKind(titleID: UInt64) -> String {
    switch titleIDHigh(titleID) {
    case TitleIDHigh.game:
        return "Game"
    case TitleIDHigh.demo:
        return "Demo"
    case TitleIDHigh.systemApp:
        return "System App"
    case TitleIDHigh.systemData:
        return "System Data"
    case TitleIDHigh.systemApplet:
        return "System Applet"
    case TitleIDHigh.vwiiIOS:
        return "vWii IOS"
    case TitleIDHigh.vwiiSystemApp:
        return "vWii System App"
    case TitleIDHigh.vwiiSystem:
        return "vWii System"
    case TitleIDHigh.dlc:
        return "DLC"
    case TitleIDHigh.update:
        return "Update"
    default:
        return "Unknown"
    }
}

// MARK: - Related titles

/// High words that may carry a related title (DLC/update vs. base game).
public func relatedTypeTargets(high: UInt32) -> [UInt32] {
    switch high {
    case TitleIDHigh.game:
        return [TitleIDHigh.dlc, TitleIDHigh.update]
    case TitleIDHigh.dlc:
        return [TitleIDHigh.game, TitleIDHigh.update]
    case TitleIDHigh.update:
        return [TitleIDHigh.game, TitleIDHigh.dlc]
    default:
        return []
    }
}

/// Finds the best related entry sharing the low word with `source` while living
/// under `targetHigh`.
///
/// Disc entries are ignored and `exclude` (when provided) filters out title IDs.
/// Region scoring mirrors the Go implementation: exact match scores 0, partial
/// overlap scores 1, otherwise 2. The lowest score wins and ties are broken by
/// the smaller title ID.
public func findRelatedTitle(
    byHighAndLow source: TitleEntry,
    targetHigh: UInt32,
    exclude: Set<UInt64>?
) -> TitleEntry? {
    let sourceLow = titleIDLow(source.titleID)

    var best: TitleEntry?
    var bestScore = 3

    for entry in TitleDatabase.shared.allEntries() {
        if entry.category == TitleCategory.disc {
            continue
        }
        if titleIDHigh(entry.titleID) != targetHigh {
            continue
        }
        if titleIDLow(entry.titleID) != sourceLow {
            continue
        }
        if let exclude, exclude.contains(entry.titleID) {
            continue
        }

        var score = 2
        if entry.region == source.region {
            score = 0
        } else if entry.region & source.region != 0 {
            score = 1
        }

        if best == nil || score < bestScore || (score == bestScore && entry.titleID < best!.titleID) {
            best = entry
            bestScore = score
        }
    }

    return best
}

/// Convenience lookup against the shared database.
public func titleEntry(forTitleID titleID: UInt64) -> TitleEntry? {
    return TitleDatabase.shared.entry(forTitleID: titleID)
}
