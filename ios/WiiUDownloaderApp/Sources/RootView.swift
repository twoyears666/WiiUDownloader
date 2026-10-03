import SwiftUI

/// PCL-inspired light palette. The upstream app is a light-blue GTK theme; this
/// keeps the same feel on iOS.
enum Theme {
    static let topBar = Color(red: 0.23, green: 0.49, blue: 0.85)
    static let pageBackground = Color(red: 0.93, green: 0.95, blue: 0.98)
    static let card = Color.white
    static let border = Color(red: 0.85, green: 0.89, blue: 0.94)
    static let hover = Color(red: 0.92, green: 0.95, blue: 0.99)
    static let text = Color(red: 0.12, green: 0.16, blue: 0.20)
    static let secondaryText = Color(red: 0.42, green: 0.48, blue: 0.55)
    static let accent = Color(red: 0.20, green: 0.46, blue: 0.83)
}

@main
struct WiiUDownloaderApp: App {
    @StateObject private var app = AppState()

    var body: some View {
        RootView()
            .environmentObject(app)
            .tint(Theme.accent)
    }
}

struct RootView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        TabView {
            BrowseView()
                .tabItem { Label("Store", systemImage: "square.grid.2x2") }

            QueueView()
                .tabItem { Label("Queue", systemImage: "arrow.down.circle") }
                .badge(activeCount)

            ToolsView()
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }

    private var activeCount: Int {
        app.tasks.filter { $0.status.isActive }.count
    }
}

// MARK: - Shared components

/// Rounded white card with the light border used throughout the app.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card)
            .overlay(
                RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Human-readable byte count, e.g. `1.4 MB`.
func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    return formatter.string(fromByteCount: max(0, bytes))
}

struct LabeledValue: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
            Spacer(minLength: 12)
            Text(value)
                .font(.footnote.monospaced())
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.trailing)
        }
    }
}
