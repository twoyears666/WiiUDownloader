import SwiftUI
import WiiUCore

/// Tools: download a title by ID and browse/extract individual title files.
struct ToolsView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    DownloadByIDCard()
                    FileBrowserCard()
                }
                .padding(12)
            }
            .background(Theme.pageBackground)
            .navigationTitle("Tools")
        }
    }
}

// MARK: - Download by ID

private struct DownloadByIDCard: View {
    @EnvironmentObject private var app: AppState

    @State private var titleID = ""
    @State private var name = ""
    @State private var versionText = ""
    @State private var error: String?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Download by title ID")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)

                TextField("00050000101C9300", text: $titleID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    .textFieldStyle(.roundedBorder)

                TextField("Display name (optional)", text: $name)
                    .textFieldStyle(.roundedBorder)

                TextField("Version (empty = latest)", text: $versionText)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)

                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button {
                    enqueue()
                } label: {
                    Label("Add to queue", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValidTitleID)
            }
        }
    }

    private var normalizedTitleID: String? {
        let trimmed = titleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count == 16, UInt64(trimmed, radix: 16) != nil else { return nil }
        return trimmed
    }

    private var isValidTitleID: Bool { normalizedTitleID != nil }

    private func enqueue() {
        guard let id = normalizedTitleID else {
            error = "Enter a 16-digit hexadecimal title ID"
            return
        }
        error = nil
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = Int(versionText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? versionLatest
        app.enqueue(
            titleID: id,
            name: displayName.isEmpty ? id : displayName,
            version: version
        )
    }
}

// MARK: - File browser

private struct FileBrowserCard: View {
    @EnvironmentObject private var app: AppState
    @StateObject private var model = FileBrowserModel()

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Browse title files")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                Text("Loads the title's file list from the CDN, then extracts the files you pick.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)

                TextField("00050000101C9300", text: $model.titleID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    .textFieldStyle(.roundedBorder)

                TextField("Version (empty = latest)", text: $model.versionText)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 10) {
                    Button {
                        model.load()
                    } label: {
                        Label("Load files", systemImage: "list.bullet")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.canLoad || model.isWorking)

                    if !model.files.isEmpty {
                        Button {
                            model.selectAll()
                        } label: {
                            Text(model.allSelected ? "Deselect all" : "Select all")
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if model.isWorking {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(model.status)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                } else if !model.status.isEmpty {
                    Text(model.status)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }

                if let error = model.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if !model.files.isEmpty {
                    Divider()
                    HStack {
                        Text("\(model.selected.count) of \(model.files.count) selected")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                        Spacer()
                        Text(formatBytes(model.selectedSize))
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.secondaryText)
                    }

                    ForEach(model.files, id: \.path) { file in
                        Button {
                            model.toggle(file)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: model.selected.contains(file.path) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(model.selected.contains(file.path) ? Theme.accent : Theme.secondaryText)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(file.path)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(Theme.text)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(formatBytes(Int64(file.size)))
                                        .font(.caption2)
                                        .foregroundStyle(Theme.secondaryText)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        model.extract(to: app.outputDirectory)
                    } label: {
                        Label("Extract selected files", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selected.isEmpty || model.isWorking)
                }
            }
        }
        .onDisappear {
            model.closeIfIdle()
        }
    }
}

/// Drives `TitleFileTree` off the main thread and republishes results.
@MainActor
final class FileBrowserModel: ObservableObject {
    @Published var titleID = ""
    @Published var versionText = ""
    @Published var files: [TitleFile] = []
    @Published var selected: Set<String> = []
    @Published var isWorking = false
    @Published var status = ""
    @Published var error: String?

    private var tree: TitleFileTree?

    var canLoad: Bool {
        let trimmed = titleID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count == 16 && UInt64(trimmed, radix: 16) != nil
    }

    var allSelected: Bool {
        !files.isEmpty && selected.count == files.count
    }

    var selectedSize: Int64 {
        files.filter { selected.contains($0.path) }.reduce(0) { $0 + Int64($1.size) }
    }

    func toggle(_ file: TitleFile) {
        if selected.contains(file.path) {
            selected.remove(file.path)
        } else {
            selected.insert(file.path)
        }
    }

    func selectAll() {
        if allSelected {
            selected.removeAll()
        } else {
            selected = Set(files.map(\.path))
        }
    }

    func load() {
        guard canLoad else {
            error = "Enter a 16-digit hexadecimal title ID"
            return
        }
        guard let id = UInt64(titleID.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16) else { return }

        isWorking = true
        error = nil
        status = "Fetching title file list…"
        let version = Int(versionText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? versionLatest

        let previous = tree
        tree = nil
        files = []
        selected = []

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let loaded = try TitleFileTree.fetch(
                    titleID: id,
                    version: version,
                    client: .shared,
                    reporter: nil
                )
                let visible = loaded.files.filter { !$0.shared }
                DispatchQueue.main.async {
                    previous?.close()
                    self.tree = loaded
                    self.files = visible
                    self.isWorking = false
                    self.status = "\(visible.count) files"
                }
            } catch {
                DispatchQueue.main.async {
                    self.isWorking = false
                    self.status = ""
                    self.error = "\(error)"
                }
            }
        }
    }

    func extract(to outputDirectory: URL) {
        guard let tree, !selected.isEmpty else { return }

        isWorking = true
        error = nil
        status = "Downloading and extracting \(selected.count) files…"
        let paths = Array(selected)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try tree.downloadFiles(outputDirectory: outputDirectory, paths: paths, reporter: nil)
                DispatchQueue.main.async {
                    self.isWorking = false
                    self.status = "Extracted \(paths.count) files to \(outputDirectory.lastPathComponent)"
                }
            } catch {
                DispatchQueue.main.async {
                    self.isWorking = false
                    self.status = ""
                    self.error = "\(error)"
                }
            }
        }
    }

    func closeIfIdle() {
        guard !isWorking else { return }
        tree?.close()
        tree = nil
        files = []
        selected = []
    }
}
