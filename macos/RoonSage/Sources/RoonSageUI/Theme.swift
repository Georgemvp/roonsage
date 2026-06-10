import SwiftUI

/// Centralised design tokens so the native app matches the web UI's identity
/// (dark surface + Roon gold accent) and stays internally consistent.
///
/// Usage:
///   - `.tint(Color.roonGold)` is applied once at the app root, so every system
///     control (buttons, pickers, toggles, sliders, progress) picks up the gold.
///   - Use `Color.roonGold` / `Color.roonBg` directly for custom chrome.
///   - Use `Spacing` / `Typography` instead of magic numbers.
///   - Wrap short metadata labels in `Badge`.
public enum RoonTheme {
    /// Roon gold — the web UI's `--color-accent #e5a00d`.
    public static let gold = Color(red: 0.898, green: 0.627, blue: 0.051)
    /// Dark surface — the web UI's `--color-bg #1a1a1a`.
    public static let background = Color(red: 0.102, green: 0.102, blue: 0.102)
    /// Slightly raised card surface.
    public static let surface = Color(red: 0.149, green: 0.149, blue: 0.149)
}

extension Color {
    /// Roon gold accent (`#e5a00d`). Mirrors the web UI accent colour.
    public static let roonGold = RoonTheme.gold
    /// App dark background (`#1a1a1a`).
    public static let roonBg = RoonTheme.background
    /// Raised card surface.
    public static let roonSurface = RoonTheme.surface
}

/// 4-pt spacing scale. Prefer these over inline magic numbers.
public enum Spacing {
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 48
}

/// Semantic typography ramp.
public enum Typography {
    public static let title = Font.system(size: 22, weight: .bold)
    public static let heading = Font.system(size: 17, weight: .semibold)
    public static let body = Font.body
    public static let caption = Font.caption
}

/// Small pill used for metadata (BPM, key, year, tags). Was duplicated across
/// LibraryView / NowPlayingView / DJSetView — now one component.
public struct Badge: View {
    let text: String
    var tint: Color = .secondary

    public init(_ text: String, tint: Color = .secondary) {
        self.text = text
        self.tint = tint
    }

    public var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}
