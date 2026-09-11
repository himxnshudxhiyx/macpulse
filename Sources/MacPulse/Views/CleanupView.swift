import AppKit
import SwiftUI

@MainActor
final class CleanupModel: ObservableObject {
    @Published private(set) var results: [CleanupScanResult] = []
    @Published private(set) var isScanning = false
    @Published private(set) var scanningTitle: String?
    @Published var selection: Set<String> = []
    @Published var moveToTrash = false
    @Published private(set) var lastOutcome: CleanupOutcome?
    @Published private(set) var isCleaning = false

    private let scanner = CacheScanner()

    var totalSelectedBytes: UInt64 {
        results.filter { selection.contains($0.id) }.map(\.size).reduce(0, +)
    }

    var totalFoundBytes: UInt64 { results.map(\.size).reduce(0, +) }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        results = []
        lastOutcome = nil

        let scanner = self.scanner
        let targets = scanner.targets
        Task.detached(priority: .utility) {
            for target in targets {
                await MainActor.run { self.scanningTitle = target.title }
                let result = scanner.size(of: target)
                guard result.size > 0 || result.itemCount > 0 else { continue }
                await MainActor.run {
                    self.results.append(result)
                    self.results.sort { $0.size > $1.size }
                    // Pre-tick only what is genuinely disposable.
                    if result.target.risk != .careful { self.selection.insert(result.id) }
                }
            }
            await MainActor.run {
                self.isScanning = false
                self.scanningTitle = nil
            }
        }
    }

    func clean() {
        guard !isCleaning else { return }
        let chosen = results.filter { selection.contains($0.id) }.map(\.target)
        guard !chosen.isEmpty else { return }
        isCleaning = true

        let scanner = self.scanner
        let moveToTrash = self.moveToTrash
        Task.detached(priority: .utility) {
            var combined = CleanupOutcome()
            for target in chosen {
                let outcome = scanner.clean(target, moveToTrash: moveToTrash)
                combined.freedBytes += outcome.freedBytes
                combined.removedItems += outcome.removedItems
                combined.failures.append(contentsOf: outcome.failures)
            }
            let finished = combined
            await MainActor.run {
                self.lastOutcome = finished
                self.isCleaning = false
                self.selection = []
                self.scan()
            }
        }
    }
}

struct CleanupView: View {
    @StateObject private var model = CleanupModel()
    @State private var confirming = false

    var body: some View {
        PageScaffold(title: "Cleanup",
                     subtitle: "Regenerable caches and logs under your home folder. Nothing outside it is ever touched.") {
            summaryCard

            if let outcome = model.lastOutcome {
                outcomeCard(outcome)
            }

            if model.results.isEmpty && !model.isScanning {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Nothing to clean").font(.system(size: 13, weight: .semibold))
                        Text("None of the cache locations MacPulse knows about are holding anything. Use Rescan after a heavy build or a long browsing session.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            ForEach(model.results) { result in
                row(for: result)
            }
        }
        .task {
            // Measuring is read-only, so do it on first visit rather than
            // making the panel open on an empty state.
            if model.results.isEmpty && !model.isScanning { model.scan() }
        }
        .confirmationDialog(model.moveToTrash ? "Move selected items to the Trash?" : "Permanently delete selected items?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button(model.moveToTrash ? "Move to Trash" : "Delete \(Fmt.bytes(model.totalSelectedBytes))", role: .destructive) {
                model.clean()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.moveToTrash
                 ? "The contents of \(model.selection.count) folder\(model.selection.count == 1 ? "" : "s") will go to the Trash, so they keep using disk space until you empty it."
                 : "This removes the contents of \(model.selection.count) folder\(model.selection.count == 1 ? "" : "s") permanently. Apps rebuild their caches on the next launch; anything marked Careful will not come back.")
        }
    }

    private var summaryCard: some View {
        Card {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(Fmt.bytes(model.totalFoundBytes))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("found in \(model.results.count) location\(model.results.count == 1 ? "" : "s")")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if model.totalSelectedBytes > 0 {
                        Text("\(Fmt.bytes(model.totalSelectedBytes)) selected")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tint)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 8) {
                        if model.isScanning {
                            ProgressView().controlSize(.small)
                            Text(model.scanningTitle ?? "Scanning…")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Button(model.results.isEmpty ? "Scan" : "Rescan") { model.scan() }
                            .disabled(model.isScanning || model.isCleaning)
                        Button("Clean Selected", role: .destructive) { confirming = true }
                            .disabled(model.selection.isEmpty || model.isScanning || model.isCleaning)
                            .keyboardShortcut(.defaultAction)
                    }
                    Toggle("Move to Trash instead of deleting", isOn: $model.moveToTrash)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .font(.system(size: 11))
                }
            }
        }
    }

    private func outcomeCard(_ outcome: CleanupOutcome) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Label("Reclaimed \(Fmt.bytes(outcome.freedBytes)) from \(outcome.removedItems) item\(outcome.removedItems == 1 ? "" : "s")",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 13, weight: .semibold))
                if !outcome.failures.isEmpty {
                    Text("\(outcome.failures.count) item\(outcome.failures.count == 1 ? "" : "s") stayed put — usually because a running app still has them open.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    DisclosureGroup("Show details") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(outcome.failures.prefix(30), id: \.self) { failure in
                                Text(failure).font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .font(.system(size: 11))
                }
            }
        }
    }

    private func row(for result: CleanupScanResult) -> some View {
        Card {
            HStack(spacing: 12) {
                Toggle("", isOn: Binding(
                    get: { model.selection.contains(result.id) },
                    set: { isOn in
                        if isOn { model.selection.insert(result.id) } else { model.selection.remove(result.id) }
                    }))
                    .labelsHidden()
                    .toggleStyle(.checkbox)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(result.target.title).font(.system(size: 13, weight: .semibold))
                        Text(result.target.risk.rawValue)
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(riskColor(result.target.risk).opacity(0.22), in: Capsule())
                            .foregroundStyle(riskColor(result.target.risk))
                            .help(result.target.risk.explanation)
                    }
                    Text(result.target.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(result.target.displayPath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Fmt.bytes(result.size))
                        .font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("\(result.itemCount) item\(result.itemCount == 1 ? "" : "s")")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([result.target.url])
                } label: {
                    Image(systemName: "folder")
                }
                .controlSize(.small)
                .help("Reveal in Finder")
            }
        }
    }

    private func riskColor(_ risk: CleanupRisk) -> Color {
        switch risk {
        case .safe: return .green
        case .regenerates: return .blue
        case .careful: return .orange
        }
    }
}
