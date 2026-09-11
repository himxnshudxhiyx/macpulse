import Foundation
import ServiceManagement

/// Wraps `SMAppService.mainApp`, the supported way to start at login on
/// macOS 13+. Registration is recorded against this exact bundle, so moving or
/// renaming the app invalidates it — see `statusDescription`.
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var lastError: String?

    init() {
        refresh()
        // Scripted setup hook, matching the other MACPULSE_* launch variables:
        // MACPULSE_LOGIN_ITEM=register (or unregister) applies the change and
        // leaves the app running normally.
        switch ProcessInfo.processInfo.environment["MACPULSE_LOGIN_ITEM"] {
        case "register": set(true)
        case "unregister": set(false)
        default: break
        }
    }

    func refresh() {
        status = SMAppService.mainApp.status
        isEnabled = status == .enabled
    }

    func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            // The usual cause is the app living somewhere macOS will not launch
            // from, such as a Downloads folder or a disk image.
            lastError = (error as NSError).localizedDescription
        }
        refresh()
    }

    /// Opens System Settings › General › Login Items, which is the only place
    /// the user can undo a manual "block" of a login item.
    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    var statusDescription: String {
        if let lastError { return lastError }
        switch status {
        case .enabled:
            return "MacPulse will start automatically and wait in the menu bar."
        case .notRegistered:
            return "MacPulse only runs when you open it."
        case .requiresApproval:
            return "Blocked in System Settings. Approve MacPulse under Login Items to enable it."
        case .notFound:
            return "macOS can't find this copy of MacPulse. Move it to your Applications folder and try again."
        @unknown default:
            return "Unknown status."
        }
    }

    var needsApproval: Bool { status == .requiresApproval }
}
