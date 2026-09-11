import AppKit
import SwiftUI

struct AppsView: View {
    @EnvironmentObject private var metrics: SystemMetrics
    @State private var pending: PendingQuit?
    @State private var errorMessage: String?
    @State private var search = ""

    private struct PendingQuit: Identifiable {
        let id = UUID()
        let app: RunningAppRow
        let force: Bool
    }

    private var apps: [RunningAppRow] {
        guard !search.isEmpty else { return metrics.apps }
        return metrics.apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private let columns = [GridItem(.adaptive(minimum: 250, maximum: 400), spacing: 12)]

    var body: some View {
        PageScaffold(title: "Open Apps",
                     subtitle: "\(metrics.apps.count) apps · CPU and memory include each app's helper processes") {
            HStack {
                TextField("Filter apps", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                Spacer()
                Button("Quit All Inactive", role: .destructive) { quitAllInactive() }
                    .help("Asks every app except the frontmost one to quit. Each app can still prompt about unsaved work.")
            }

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(apps) { app in
                    appCard(app)
                }
            }

            if metrics.apps.isEmpty {
                Card { Text("Collecting running apps…").font(.system(size: 12)).foregroundStyle(.secondary) }
            }
        }
        .alert(item: $pending) { pending in
            Alert(title: Text(pending.force ? "Force quit \(pending.app.name)?" : "Quit \(pending.app.name)?"),
                  message: Text(pending.force
                                ? "Force quitting ends the app immediately. Any unsaved work is lost."
                                : "The app will close normally and can prompt you about unsaved work."),
                  primaryButton: .destructive(Text(pending.force ? "Force Quit" : "Quit")) {
                      let result = metrics.quit(pid: pending.app.pid, force: pending.force)
                      if case .failed(let message) = result { errorMessage = message }
                  },
                  secondaryButton: .cancel())
        }
        .alert("Couldn't quit that app",
               isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func appCard(_ app: RunningAppRow) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    if let icon = app.icon {
                        Image(nsImage: icon).resizable().frame(width: 30, height: 30)
                    } else {
                        Image(systemName: "app").font(.system(size: 24)).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(app.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            if app.isActive {
                                Text("FRONT").font(.system(size: 8, weight: .bold))
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.25), in: RoundedRectangle(cornerRadius: 3))
                            }
                            if app.isHidden {
                                Image(systemName: "eye.slash").font(.system(size: 9)).foregroundStyle(.tertiary)
                            }
                        }
                        Text(app.bundleIdentifier ?? "PID \(app.pid)")
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                }

                HStack(spacing: 14) {
                    metricColumn(title: "CPU", value: String(format: "%.1f%%", app.cpu),
                                 fraction: min(1, app.cpu / 100))
                    metricColumn(title: "Memory", value: Fmt.bytes(app.memoryBytes),
                                 fraction: metrics.memory.total > 0 ? Double(app.memoryBytes) / Double(metrics.memory.total) : 0)
                }

                HStack(spacing: 6) {
                    if let launch = app.launchDate {
                        Text("Running \(Fmt.duration(Date().timeIntervalSince(launch)))")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("Quit") { pending = PendingQuit(app: app, force: false) }
                    Button("Force") { pending = PendingQuit(app: app, force: true) }
                        .tint(.red)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }
        }
    }

    private func metricColumn(title: String, value: String, fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Text(value).font(.system(size: 11, weight: .semibold)).monospacedDigit()
            }
            UsageBar(fraction: fraction, height: 4)
        }
        .frame(maxWidth: .infinity)
    }

    /// Leaves the frontmost app alone so the user is never left staring at an
    /// empty desktop mid-task.
    private func quitAllInactive() {
        for app in metrics.apps where !app.isActive && app.bundleIdentifier != Bundle.main.bundleIdentifier {
            _ = metrics.quit(pid: app.pid, force: false)
        }
    }
}
