import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Centralised design tokens so the native app matches the web UI's identity
/// (Roon gold accent) and stays internally consistent on macOS and iOS, in
/// light and dark mode.
///
/// Usage:
///   - `.tint(...)` is applied once at the app root (user accent, gold default),
///     so every system control (buttons, pickers, toggles, sliders) picks it up.
///   - Use the semantic `Color.roon*` tokens for state colours (success/warning/
///     danger/info) instead of ad-hoc `.green`/`.red`/`.orange` so meaning stays
///     consistent and there is one place to retune.
///   - Use `Spacing` / `Radius` / `Typography` / `Motion` instead of magic numbers.
///   - Surfaces: `Color.platformCardBackground` / `.platformQuaternaryFill`
///     (Compat.swift) — adaptive on both platforms; never hardcode dark greys.
///   - Wrap short metadata labels in `Badge`.
public enum RoonTheme {
    /// Roon gold — the web UI's `--color-accent #e5a00d`.
    public static let gold = Color(red: 0.898, green: 0.627, blue: 0.051)
}

extension Color {
    /// Roon gold accent (`#e5a00d`). Mirrors the web UI accent colour.
    public static let roonGold = RoonTheme.gold

    // MARK: Semantic state colours (adaptive light/dark via system palette)

    /// Positive state: connected, harmonic match, saved, completed.
    public static let roonSuccess = Color.green
    /// Caution state: live versions, degraded connection, long operations.
    public static let roonWarning = Color.orange
    /// Error state: failures, destructive actions.
    public static let roonDanger = Color.red
    /// Informational accents: hints, neutral highlights.
    public static let roonInfo = Color.blue

    /// One drop-shadow tint for raised art/cards, so depth stays uniform instead
    /// of every call-site inventing its own `.black.opacity(0.2…0.4)`.
    public static let roonShadow = Color.black.opacity(0.25)
}

extension View {
    /// Guarantees at least Apple's 44×44pt minimum hit target for icon-only
    /// controls, expanding the tappable area without resizing the glyph. Use on
    /// borderless image buttons (play/skip/mute/refresh) so touch + VoiceOver
    /// land reliably.
    public func tappable44() -> some View {
        self.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
    }
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

/// Corner-radius scale. `sm` chips/badges, `md` rows/thumbnails, `lg` cards,
/// `xl` sheets/hero art.
public enum Radius {
    public static let sm: CGFloat = 4
    public static let md: CGFloat = 6
    public static let lg: CGFloat = 12
    public static let xl: CGFloat = 16
}

/// Semantic typography ramp. Anchored to system text styles (not fixed point
/// sizes) so every label scales with the user's Dynamic Type setting — a fixed
/// `size:` ramp would silently break accessibility.
public enum Typography {
    /// Screen / hero titles.
    public static let title = Font.system(.title2, weight: .bold)
    /// Section headers and card titles.
    public static let heading = Font.system(.headline)
    public static let body = Font.body
    public static let caption = Font.caption
}

/// Motion tokens — one place for animation durations/curves so transitions
/// feel uniform across views.
public enum Motion {
    /// Quick state flips (selection, badge swap).
    public static let quick = Animation.easeOut(duration: 0.15)
    /// Standard content transitions (cards, lists appearing).
    public static let standard = Animation.easeInOut(duration: 0.3)
    /// Ambient/large transitions (art-driven backdrop tint).
    public static let ambient = Animation.easeInOut(duration: 0.8)
    /// Springy content pops (hero art, dealt-in rows) — ease curves feel
    /// mechanical for physical-feeling moves; springs feel alive.
    public static let spring = Animation.spring(response: 0.4, dampingFraction: 0.8)
}

/// One shared card surface. Three competing recipes coexisted
/// (`.background.secondary`, `platformCardBackground.opacity(0.5)`,
/// `cornerRadius: 10`) so padding, radius and fill drifted per view.
/// Usage: `content.cardStyle()` or `Card { content }`.
public struct Card<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .padding(Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.lg))
    }
}

extension View {
    /// The shared card treatment as a modifier, for call-sites that already
    /// have their own container view.
    public func cardStyle() -> some View {
        self
            .padding(Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.lg))
    }
}

/// Cross-platform haptics — award-quality iOS apps confirm every meaningful
/// tap. No-op on macOS so call-sites stay clean of #if os(...) noise.
public enum Haptics {
    /// Light tap for ordinary actions (play, queue, zone select).
    public static func tap() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    /// Success notification for completed work (playlist saved, set built,
    /// curation finished).
    public static func success() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    /// Error notification — pairs with the ActionError toast.
    public static func error() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        #endif
    }
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
