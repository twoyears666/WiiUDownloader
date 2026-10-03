import SwiftUI
import WiiUCore

/// Download queue: one card per task with progress, speed and controls.
struct QueueView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        NavigationStack {
            Group {
                if app.tasks.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle")
                            .font(.largeTitle)
                            .foregroundStyle(Theme.secondaryText)
                        Text("Queue is empty")
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(app.tasks) { task in
                                TaskCard(task: task)
                            }
                        }
                        .padding(12)
                    }
                }
            }
            .background(Theme.pageBackground)
            .navigationTitle("Queue")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Clear finished") {
                        app.removeFinishedTasks()
                    }
                    .disabled(!app.tasks.contains { !$0.status.isActive })
                }
            }
        }
    }
}

/// One queued download.
private struct TaskCard: View {
    @ObservedObject var task: DownloadTask

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.name)
                            .font(.headline)
                            .foregroundStyle(Theme.text)
                            .lineLimit(2)
                        Text(task.titleID)
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                    statusBadge
                }

                if task.status.isActive {
                    ProgressView(value: task.progress)
                        .tint(Theme.accent)
                    HStack {
                        Text(sizeText)
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.secondaryText)
                        Spacer()
                        if task.speed > 0, task.status == .running {
                            Text("\(formatBytes(Int64(task.speed)))/s")
                                .font(.caption.monospaced())
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                    if !task.currentFile.isEmpty, task.status == .running {
                        Text(task.currentFile)
                            .font(.caption2.monospaced())
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                if !task.message.isEmpty {
                    Text(task.message)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(3)
                }

                controls
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        Text(task.status.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.hover)
            .foregroundStyle(Theme.accent)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private var controls: some View {
        switch task.status {
        case .running:
            HStack(spacing: 12) {
                Button("Pause") { task.pause() }
                Button("Cancel", role: .destructive) { task.cancel() }
            }
            .buttonStyle(.bordered)
        case .paused:
            HStack(spacing: 12) {
                Button("Resume") { task.resume() }
                Button("Cancel", role: .destructive) { task.cancel() }
            }
            .buttonStyle(.bordered)
        case .queued:
            Button("Cancel", role: .destructive) { task.cancel() }
                .buttonStyle(.bordered)
        default:
            EmptyView()
        }
    }

    private var sizeText: String {
        guard task.total > 0 else { return formatBytes(task.downloaded) }
        return "\(formatBytes(task.downloaded)) / \(formatBytes(task.total))"
    }
}
