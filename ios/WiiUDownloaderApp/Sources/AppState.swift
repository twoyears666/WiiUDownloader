import Foundation
import SwiftUI
import WiiUCore

/// App-wide state: settings, the title database view, and the download queue.
@MainActor
final class AppState: ObservableObject {
    @Published var titles: [TitleEntry] = []
    @Published var searchText = ""
    @Published var regionFilter: RegionFilter = .all
    @Published var categoryFilter: UInt8 = TitleCategory.all
    @Published var tasks: [DownloadTask] = []
    @Published var statusMessage: String?

    @AppStorage("outputDirectoryPath") var outputDirectoryPath = ""
    @AppStorage("autoDecrypt") var autoDecrypt = true
    @AppStorage("deleteEncrypted") var deleteEncrypted = true
    @AppStorage("titleDBURL") var titleDBURL = "https://napi.v10lator.de/db?t=json"

    init() {
        reloadTitles()
    }

    /// Where downloaded titles are written. Defaults to `Documents/WiiUDownloader`.
    var outputDirectory: URL {
        if !outputDirectoryPath.isEmpty {
            return URL(fileURLWithPath: outputDirectoryPath, isDirectory: true)
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("WiiUDownloader", isDirectory: true)
    }

    /// Titles matching the current search text and filters.
    var filteredTitles: [TitleEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return titles.filter { entry in
            if entry.category == TitleCategory.disc { return false }
            if categoryFilter != TitleCategory.all, entry.category != categoryFilter { return false }
            if !regionFilter.matches(entry.region) { return false }
            if query.isEmpty { return true }
            if entry.name.lowercased().contains(query) { return true }
            return entry.titleIDString.contains(query)
        }
    }

    // MARK: Database

    /// Reloads the title database from the bundled sample.
    func reloadTitles() {
        do {
            try TitleDatabase.shared.loadBundled()
        } catch {
            statusMessage = "Failed to load bundled title database: \(error)"
        }
        titles = TitleDatabase.shared.allEntries()
    }

    /// Downloads a JSON title database from `titleDBURL` and installs it.
    func updateTitleDatabase() {
        guard let url = URL(string: titleDBURL) else {
            statusMessage = "Invalid title database URL"
            return
        }
        statusMessage = "Updating title database…"

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("titles-\(UUID().uuidString).json")
        let downloader = Downloader()

        DispatchQueue.global(qos: .userInitiated).async { [titleDBURL] in
            do {
                try downloader.download(
                    from: url,
                    to: destination,
                    options: DownloadOptions(doRetries: true, allowResume: false, userAgent: "WiiUDownloader"),
                    reporter: nil
                )
                try TitleDatabase.shared.load(from: destination)
                try? FileManager.default.removeItem(at: destination)
                let entries = TitleDatabase.shared.allEntries()
                DispatchQueue.main.async {
                    self.titles = entries
                    self.statusMessage = "Loaded \(entries.count) titles"
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = "Update failed (\(titleDBURL)): \(error)"
                }
            }
        }
    }

    // MARK: Queue

    @discardableResult
    func enqueue(titleID: String, name: String, version: Int = versionLatest) -> DownloadTask {
        let task = DownloadTask(
            titleID: titleID,
            name: name,
            outputDirectory: outputDirectory,
            version: version,
            decrypt: autoDecrypt,
            deleteEncrypted: deleteEncrypted
        )
        tasks.insert(task, at: 0)
        task.start()
        return task
    }

    func removeFinishedTasks() {
        tasks.removeAll { task in
            switch task.status {
            case .finished, .failed, .cancelled: return true
            default: return false
            }
        }
    }
}

// MARK: - Region filter

enum RegionFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case usa = "USA"
    case europe = "Europe"
    case japan = "Japan"

    var id: String { rawValue }

    func matches(_ region: UInt8) -> Bool {
        switch self {
        case .all: return true
        case .usa: return region & MCPRegion.usa != 0
        case .europe: return region & MCPRegion.europe != 0
        case .japan: return region & MCPRegion.japan != 0
        }
    }
}
