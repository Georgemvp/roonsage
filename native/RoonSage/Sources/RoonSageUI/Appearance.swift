import SwiftUI

// User-configurable appearance (theme mode + accent colour), persisted in
// UserDefaults via @AppStorage so it's shared by every view on both platforms.
// Apply once at the app root with `.roonSageAppearance()`.

/// Light / dark / follow-system.
public enum ThemeMode: String, CaseIterable, Identifiable {
    case system, light, dark

    public var id: String { rawValue }

    /// Dutch label for the settings picker.
    public var label: String {
        switch self {
        case .system: "Systeem"
        case .light:  "Licht"
        case .dark:   "Donker"
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light:  .light
        case .dark:   .dark
        }
    }
}

/// Accent colour presets. `gold` is the Roon-matching default.
public enum AccentChoice: String, CaseIterable, Identifiable {
    case gold, amber, blue, indigo, teal, green, pink

    public var id: String { rawValue }

    /// Dutch label for the settings picker.
    public var label: String {
        switch self {
        case .gold:   "Goud"
        case .amber:  "Amber"
        case .blue:   "Blauw"
        case .indigo: "Indigo"
        case .teal:   "Teal"
        case .green:  "Groen"
        case .pink:   "Roze"
        }
    }

    public var color: Color {
        switch self {
        case .gold:   .roonGold
        case .amber:  Color(red: 0.95, green: 0.45, blue: 0.10)
        case .blue:   .blue
        case .indigo: .indigo
        case .teal:   .teal
        case .green:  .green
        case .pink:   .pink
        }
    }
}

/// Applies the user's chosen accent + theme mode. Reactive: changing the stored
/// values updates every view that descends from where this is applied.
public struct RoonSageAppearance: ViewModifier {
    @AppStorage("themeMode") private var themeMode: ThemeMode = .system
    @AppStorage("accentChoice") private var accent: AccentChoice = .gold

    public init() {}

    public func body(content: Content) -> some View {
        content
            .tint(accent.color)
            .preferredColorScheme(themeMode.colorScheme)
    }
}

extension View {
    /// Apply the user-configured accent + theme mode. Use at the app root.
    public func roonSageAppearance() -> some View {
        modifier(RoonSageAppearance())
    }
}
