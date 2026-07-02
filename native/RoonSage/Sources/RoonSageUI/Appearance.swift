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

/// A curated, named look. `.custom` defers to the `ThemeMode` + `AccentChoice`
/// pickers; every other preset pins its own accent and light/dark scheme so a
/// single tap gives a complete, coherent theme (à la a theme store, but built-in
/// and offline — no account, no download).
public enum ThemePreset: String, CaseIterable, Identifiable {
    case custom
    case midnight
    case ocean
    case forest
    case mocha
    case sunset
    case latte

    public var id: String { rawValue }

    /// Dutch label for the settings picker.
    public var label: String {
        switch self {
        case .custom:   "Aangepast"
        case .midnight: "Middernacht"
        case .ocean:    "Oceaan"
        case .forest:   "Woud"
        case .mocha:    "Mokka"
        case .sunset:   "Zonsondergang"
        case .latte:    "Latte"
        }
    }

    /// The accent for this preset — `nil` for `.custom`, where `AccentChoice` wins.
    public var accent: Color? {
        switch self {
        case .custom:   nil
        case .midnight: Color(red: 0.46, green: 0.52, blue: 0.96)
        case .ocean:    Color(red: 0.16, green: 0.72, blue: 0.79)
        case .forest:   Color(red: 0.30, green: 0.74, blue: 0.44)
        case .mocha:    Color(red: 0.80, green: 0.65, blue: 0.97)
        case .sunset:   Color(red: 0.98, green: 0.45, blue: 0.42)
        case .latte:    Color(red: 0.87, green: 0.52, blue: 0.18)
        }
    }

    /// The light/dark scheme a preset pins — `nil` for `.custom`, where
    /// `ThemeMode` wins. Most curated looks are dark; Latte is a warm light.
    public var forcedScheme: ColorScheme? {
        switch self {
        case .custom: nil
        case .latte:  .light
        default:      .dark
        }
    }

    /// Two-stop swatch for the picker row (accent → a darker/lighter companion).
    public var swatch: [Color] {
        guard let a = accent else { return [.roonGold, Color.roonGold.opacity(0.4)] }
        return forcedScheme == .light
            ? [a, Color.white.opacity(0.9)]
            : [a, Color.black.opacity(0.65)]
    }
}

/// Applies the user's chosen theme. A named `ThemePreset` overrides both accent
/// and scheme; `.custom` falls through to the `ThemeMode` + `AccentChoice`
/// pickers. Reactive: changing any stored value re-tints every descendant view.
public struct RoonSageAppearance: ViewModifier {
    @AppStorage("themePreset") private var preset: ThemePreset = .custom
    @AppStorage("themeMode") private var themeMode: ThemeMode = .system
    @AppStorage("accentChoice") private var accent: AccentChoice = .gold

    public init() {}

    public func body(content: Content) -> some View {
        content
            .tint(preset.accent ?? accent.color)
            .preferredColorScheme(preset.forcedScheme ?? themeMode.colorScheme)
    }
}

extension View {
    /// Apply the user-configured accent + theme mode. Use at the app root.
    public func roonSageAppearance() -> some View {
        modifier(RoonSageAppearance())
    }
}
