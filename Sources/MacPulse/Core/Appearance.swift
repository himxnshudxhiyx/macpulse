import AppKit
import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    /// `nil` hands the decision back to macOS.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Applies the appearance to `NSApp` rather than using SwiftUI's
/// `preferredColorScheme`, which only reaches the window — the menu bar popover
/// is a separate panel and would keep the system appearance.
@MainActor
final class AppearanceSetting: ObservableObject {
    private static let defaultsKey = "appearanceMode"

    @Published var mode: AppearanceMode {
        didSet {
            guard oldValue != mode else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: Self.defaultsKey)
            apply()
        }
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.defaultsKey)
        mode = stored.flatMap(AppearanceMode.init(rawValue:)) ?? .system
        // NSApp is not guaranteed to exist while the App's state is being built.
        DispatchQueue.main.async { [weak self] in self?.apply() }
    }

    func apply() {
        NSApp.appearance = mode.nsAppearance
    }
}
