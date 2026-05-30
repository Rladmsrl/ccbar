import Foundation

/// Categories shown in the main window's "settings mode" sidebar. Each owns
/// the corresponding `*SettingsView` rendered in the detail panel.
enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
    case general
    case features
    case menuBar
    case floatingTab
    case platforms
    case tracking
    case approvals
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:   L10n.string("settings.section.general", defaultValue: "General")
        case .features:  L10n.string("settings.section.features", defaultValue: "Features")
        case .menuBar:      L10n.string("settings.section.menu_bar", defaultValue: "Menu Bar")
        case .floatingTab:  L10n.string("settings.section.floating_tab", defaultValue: "Floating Tab")
        case .platforms:    L10n.string("settings.section.platforms", defaultValue: "Platforms")
        case .tracking:  L10n.string("settings.section.tracking", defaultValue: "Tracking")
        case .approvals: L10n.string("settings.section.approvals", defaultValue: "Approvals")
        case .about:     L10n.string("settings.section.about", defaultValue: "About")
        }
    }

    var symbol: String {
        switch self {
        case .general:   "gearshape"
        case .features:  "switch.2"
        case .menuBar:      "menubar.rectangle"
        case .floatingTab:  "rectangle.on.rectangle"
        case .platforms:    "square.stack.3d.up"
        case .tracking:  "waveform.path.ecg"
        case .approvals: "shield.lefthalf.filled"
        case .about:     "info.circle"
        }
    }

    var assetName: String? { nil }
}
