import SwiftUI

/// SwiftUI's `defaultSize` loses to a restored window frame, and a menu-bar app
/// should survive its window being closed. Both are AppKit-level concerns.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // The Dock icon simply follows the window: gone when the window is
        // closed, back whenever one appears — whether it was reopened from the
        // menu bar popover, from Spotlight, or by SwiftUI itself.
        for name in [NSWindow.willCloseNotification, NSWindow.didBecomeKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                DispatchQueue.main.async { Self.syncActivationPolicy() }
            }
        }

        let atLogin = Self.launchedAtLogin
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.canBecomeMain }) else { return }
            if atLogin {
                // Starting at login means starting out of the way: the menu bar
                // readout appears, the window waits until it is asked for.
                window.close()
                Self.syncActivationPolicy()
                return
            }
            window.minSize = NSSize(width: 960, height: 640)
            if window.frame.width < window.minSize.width || window.frame.height < window.minSize.height {
                window.setContentSize(NSSize(width: 1180, height: 800))
                window.center()
            }
        }
    }

    /// The Dock icon is shown only while a real window is on screen. The menu
    /// bar popover is an `NSPanel`, so it never counts as one.
    static func syncActivationPolicy() {
        let hasWindow = NSApp.windows.contains {
            $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel)
        }
        NSApp.setActivationPolicy(hasWindow ? .regular : .accessory)
    }

    /// Brings the main window back from the menu-bar-only state.
    static func showMainWindow(fallback: () -> Void) {
        NSApp.setActivationPolicy(.regular)
        if let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) && !($0 is NSPanel) }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            fallback()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// macOS marks the launch event of a login item with `keyAELaunchedAsLogInItem`.
    /// Spelled as raw four-character codes to avoid pulling in Carbon.
    private static var launchedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == code("oapp") else { return false }
        return event.paramDescriptor(forKeyword: code("prdt"))?.enumCodeValue == code("lgit")
    }

    private static func code(_ text: String) -> FourCharCode {
        text.utf8.reduce(0) { ($0 << 8) + FourCharCode($1) }
    }

    // Keep sampling for the menu bar readout after the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct MacPulseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var metrics = SystemMetrics()
    @StateObject private var loginItem = LoginItem()
    @StateObject private var appearance = AppearanceSetting()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(metrics)
                .environmentObject(loginItem)
                .environmentObject(appearance)
                .frame(minWidth: 900, minHeight: 620)
        }
        .defaultSize(width: 1120, height: 780)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh Now") { metrics.refreshNow() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }

        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(metrics)
                .environmentObject(loginItem)
                .environmentObject(appearance)
        } label: {
            MenuBarReadout(cpu: metrics.cpu.usage,
                           memoryUsed: metrics.memory.used,
                           memoryFree: metrics.memory.available,
                           temperature: metrics.temperature.soc)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Two labelled lines in the menu bar, each showing both halves of the number:
/// what is in use and what is still free.
///
/// `MenuBarExtra` squeezes a SwiftUI label down to a single clipped line, so the
/// readout is drawn into a template image, which the menu bar tints for light
/// and dark automatically.
struct MenuBarReadout: View {
    let cpu: Double
    let memoryUsed: UInt64
    let memoryFree: UInt64
    /// Omitted entirely on hardware whose sensors cannot be read.
    let temperature: Double?

    var body: some View {
        Image(nsImage: Self.render(top: "CPU \(percent(cpu)) / \(percent(1 - cpu)) idle",
                                   bottom: "RAM \(Fmt.compactBytes(memoryUsed)) / \(Fmt.compactBytes(memoryFree)) free",
                                   trailing: temperature.map { String(format: "%.0f°", $0) }))
    }

    private func percent(_ fraction: Double) -> String {
        "\(Int((max(0, min(1, fraction)) * 100).rounded()))%"
    }

    private static func render(top: String, bottom: String, trailing: String?) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let bigFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let bigAttributes: [NSAttributedString.Key: Any] = [.font: bigFont, .foregroundColor: NSColor.black]

        let topSize = (top as NSString).size(withAttributes: attributes)
        let bottomSize = (bottom as NSString).size(withAttributes: attributes)
        let columnWidth = ceil(max(topSize.width, bottomSize.width))

        // The temperature sits to the right of both lines, vertically centred,
        // so it reads as one value for the machine rather than a third stat.
        let gap: CGFloat = 7
        let trailingSize = trailing.map { ($0 as NSString).size(withAttributes: bigAttributes) } ?? .zero
        let trailingWidth = trailing == nil ? 0 : ceil(trailingSize.width) + gap

        let size = NSSize(width: columnWidth + trailingWidth + 2, height: 22)
        let image = NSImage(size: size, flipped: false) { _ in
            (top as NSString).draw(at: NSPoint(x: 1, y: 11), withAttributes: attributes)
            (bottom as NSString).draw(at: NSPoint(x: 1, y: 1), withAttributes: attributes)
            if let trailing {
                let y = (22 - trailingSize.height) / 2
                (trailing as NSString).draw(at: NSPoint(x: 1 + columnWidth + gap, y: y), withAttributes: bigAttributes)
            }
            return true
        }
        // Template rendering makes the menu bar own the colour, so the readout
        // stays legible on light, dark and tinted menu bars alike.
        image.isTemplate = true
        return image
    }
}

struct MenuBarPanel: View {
    @EnvironmentObject private var metrics: SystemMetrics
    @EnvironmentObject private var loginItem: LoginItem
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("MacPulse").font(.system(size: 13, weight: .bold))
                Spacer()
                Text("Health \(metrics.healthScore)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Severity.color(for: 1 - Double(metrics.healthScore) / 100))
            }

            statRow("CPU", Fmt.percent(metrics.cpu.usage, decimals: 0), metrics.cpu.usage)
            statRow("Memory", Fmt.bytes(metrics.memory.used), metrics.memory.usedFraction)
            statRow("Pressure", metrics.memory.pressureLevel.rawValue, metrics.memory.pressure)
            if let volume = metrics.bootVolume {
                statRow("Disk", "\(Fmt.bytes(volume.available)) free", volume.usedFraction)
            }
            if let soc = metrics.temperature.soc {
                statRow("Temperature", String(format: "%.0f °C", soc), soc / 100)
            }

            Divider()

            HStack {
                Text("Network").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text("↓ \(Fmt.rate(metrics.network.downloadRate))  ↑ \(Fmt.rate(metrics.network.uploadRate))")
                    .font(.system(size: 11, weight: .medium)).monospacedDigit()
            }

            if !metrics.apps.isEmpty {
                Divider()
                Text("Top apps").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(metrics.apps.sorted { $0.cpu > $1.cpu }.prefix(3)) { app in
                    HStack(spacing: 6) {
                        if let icon = app.icon {
                            Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                        }
                        Text(app.name).font(.system(size: 11)).lineLimit(1)
                        Spacer()
                        Text(String(format: "%.0f%%", app.cpu)).font(.system(size: 11)).monospacedDigit()
                    }
                }
            }

            Divider()

            Toggle("Start at login", isOn: Binding(get: { loginItem.isEnabled },
                                                   set: { loginItem.set($0) }))
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.system(size: 11))

            HStack {
                Button("Open MacPulse") {
                    AppDelegate.showMainWindow { openWindow(id: "main") }
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 260)
    }

    private func statRow(_ label: String, _ value: String, _ fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text(value).font(.system(size: 11, weight: .semibold)).monospacedDigit()
            }
            UsageBar(fraction: fraction, height: 4)
        }
    }
}
