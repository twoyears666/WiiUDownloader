import SwiftUI
import WiiUCore

/// Title browser: search, region and category filters, then a card list that
/// pushes into `TitleDetailView`.
struct BrowseView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filters
                content
            }
            .background(Theme.pageBackground)
            .navigationTitle("Store")
            .searchable(text: $app.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search titles or IDs")
        }
    }

    private var filters: some View {
        VStack(spacing: 8) {
            Picker("Region", selection: $app.regionFilter) {
                ForEach(RegionFilter.allCases) { region in
                    Text(region.rawValue).tag(region)
                }
            }
            .pickerStyle(.segmented)

            Picker("Category", selection: $app.categoryFilter) {
                Text("All").tag(TitleCategory.all)
                Text("Game").tag(TitleCategory.game)
                Text("Update").tag(TitleCategory.update)
                Text("DLC").tag(TitleCategory.dlc)
                Text("Demo").tag(TitleCategory.demo)
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.pageBackground)
    }

    @ViewBuilder
    private var content: some View {
        let titles = app.filteredTitles
        if titles.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.largeTitle)
                    .foregroundStyle(Theme.secondaryText)
                Text(app.titles.isEmpty ? "No title database loaded" : "No titles match your filters")
                    .foregroundStyle(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.pageBackground)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(titles, id: \.titleID) { entry in
                        NavigationLink {
                            TitleDetailView(entry: entry)
                        } label: {
                            TitleRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .background(Theme.pageBackground)
        }
    }
}

/// One row in the browse list.
private struct TitleRow: View {
    let entry: TitleEntry

    var body: some View {
        Card {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name)
                        .font(.headline)
                        .foregroundStyle(Theme.text)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        Text(entry.titleIDString)
                            .font(.caption.monospaced())
                        Text(formattedRegion(entry.region))
                        Text(TitleCategory.formatted(entry.category))
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }
}

/// Detail page for one title: metadata, related titles and the download action.
struct TitleDetailView: View {
    @EnvironmentObject private var app: AppState
    let entry: TitleEntry

    @State private var useLatest = true

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.name)
                            .font(.title3.bold())
                            .foregroundStyle(Theme.text)
                        LabeledValue(label: "Title ID", value: entry.titleIDString)
                        LabeledValue(label: "Region", value: formattedRegion(entry.region))
                        LabeledValue(label: "Kind", value: formattedKind(titleID: entry.titleID))
                        LabeledValue(label: "Category", value: TitleCategory.formatted(entry.category))
                        LabeledValue(label: "Database version", value: entry.version >= 0 ? "\(entry.version)" : "—")
                    }
                }

                Card {
                    Toggle("Download latest version", isOn: $useLatest)
                        .foregroundStyle(Theme.text)
                    if !useLatest {
                        LabeledValue(label: "Pinned version", value: entry.version >= 0 ? "\(entry.version)" : "Start from 0")
                    }
                }

                relatedSection

                Button {
                    app.enqueue(
                        titleID: entry.titleIDString,
                        name: entry.name,
                        version: useLatest ? versionLatest : max(0, entry.version)
                    )
                } label: {
                    Label("Add to queue", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if let status = app.statusMessage {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .padding(12)
        }
        .background(Theme.pageBackground)
        .navigationTitle("Title")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var relatedSection: some View {
        let related = relatedEntries
        if !related.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Related")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.text)
                    ForEach(related, id: \.titleID) { relatedEntry in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(relatedEntry.name)
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(1)
                                Text("\(relatedEntry.titleIDString) · \(formattedRegion(relatedEntry.region))")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(Theme.secondaryText)
                            }
                            Spacer()
                            Button {
                                app.enqueue(titleID: relatedEntry.titleIDString, name: relatedEntry.name)
                            } label: {
                                Image(systemName: "arrow.down.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
    }

    private var relatedEntries: [TitleEntry] {
        let exclude: Set<UInt64> = [entry.titleID]
        var result: [TitleEntry] = []
        for target in relatedTypeTargets(high: titleIDHigh(entry.titleID)) {
            if let related = findRelatedTitle(byHighAndLow: entry, targetHigh: target, exclude: exclude) {
                result.append(related)
            }
        }
        return result
    }
}
