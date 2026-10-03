import SwiftUI
import WiiUCore

/// Settings: output location, decryption behavior and title database source.
struct SettingsView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    outputCard
                    decryptionCard
                    databaseCard
                    aboutCard
                }
                .padding(12)
            }
            .background(Theme.pageBackground)
            .navigationTitle("Settings")
        }
    }

    private var outputCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Output")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                LabeledValue(label: "Folder", value: app.outputDirectory.path)
                TextField("Custom output folder (absolute path)", text: $app.outputDirectoryPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote.monospaced())
                    .textFieldStyle(.roundedBorder)
                if !app.outputDirectoryPath.isEmpty {
                    Button("Use default folder") {
                        app.outputDirectoryPath = ""
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var decryptionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Decryption")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                Toggle("Decrypt contents after download", isOn: $app.autoDecrypt)
                    .foregroundStyle(Theme.text)
                Toggle("Delete encrypted files once decrypted", isOn: $app.deleteEncrypted)
                    .foregroundStyle(Theme.text)
                    .disabled(!app.autoDecrypt)
            }
        }
    }

    private var databaseCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Title database")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                LabeledValue(label: "Loaded titles", value: "\(app.titles.count)")
                TextField("Database URL", text: $app.titleDBURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote.monospaced())
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 10) {
                    Button {
                        app.reloadTitles()
                    } label: {
                        Label("Reload bundled", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        app.updateTitleDatabase()
                    } label: {
                        Label("Update", systemImage: "arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var aboutCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("About")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                Text("A SwiftUI port of WiiUDownloader. Title data and downloads come from Nintendo's public update servers; decryption uses your console-independent common keys.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }
}
