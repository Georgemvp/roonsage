import SwiftUI
import RoonSageCore

/// App-wide tint derived from the *currently playing* album art. The Now Playing
/// view has always tinted its own backdrop from the artwork; this lifts that one
/// colour into a shared, observable source so every other tab (Bibliotheek,
/// Maak, Ontdek, Instellingen) can wear the same ambient wash instead of a flat
/// black surface. Populated once at the app root (see `ContentView`); read by
/// `AmbientBackdrop` via `.ambientSurface()`.
@MainActor
@Observable
public final class AmbientTheme {
    /// Average colour of the current track's cover, or `nil` when nothing plays.
    public var color: Color?
    /// The current track's art key, for the optional full-bleed wallpaper.
    public var artKey: String?
    public init() {}

    /// Re-derive the tint for the selected zone's now-playing artwork. Cheap to
    /// call repeatedly — `ImageCache.dominantColor` caches per URL. Cross-fades
    /// with the ambient motion token so the whole app shifts colour smoothly.
    public func update(from client: RoonClient) async {
        guard let key = client.selectedZone?.nowPlaying?.imageKey,
              let url = client.imageURL(forKey: key, size: 64) else {
            withAnimation(Motion.ambient) { color = nil; artKey = nil }
            return
        }
        let derived = await ImageCache.shared.dominantColor(for: url)
        withAnimation(Motion.ambient) { color = derived; artKey = key }
    }
}

/// Full-bleed backdrop that washes the screen in the now-playing tint, dissolving
/// toward the bottom so list/form content stays legible. The base tracks the
/// active colour scheme — black in dark mode, white in light — so it's always safe
/// to place behind a tab regardless of the app theme. Falls back to the plain base
/// when nothing plays.
public struct AmbientBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(RoonClient.self) private var client
    // User controls (C6): a single intensity dial scales the whole wash (0 =
    // flat surface, 1 = the original look), and an opt-in wallpaper renders the
    // now-playing art full-bleed and blurred behind the tint.
    @AppStorage("ambientIntensity") private var intensity: Double = 1.0
    @AppStorage("ambientWallpaper") private var wallpaper: Bool = false
    let color: Color?
    var artKey: String? = nil
    public init(color: Color?, artKey: String? = nil) { self.color = color; self.artKey = artKey }

    public var body: some View {
        let k = max(0, min(intensity, 1))
        ZStack {
            // Adaptive base: pure black in dark mode (unchanged), pure white in
            // light mode so the tint reads as a soft pastel wash instead of a
            // black slab bleeding over the light theme.
            (scheme == .dark ? Color.black : Color.white)

            // Optional album-art wallpaper: full-bleed, heavily blurred, dimmed —
            // an immersive backdrop that still keeps list/form content legible.
            if wallpaper, k > 0, let artKey,
               let url = client.imageURL(forKey: artKey, size: 400) {
                CachedArtImage(url: url) { Color.clear }
                    .blur(radius: 60)
                    .opacity(0.5 * k)
                    .overlay((scheme == .dark ? Color.black : Color.white).opacity(0.35))
                    .clipped()
            }

            if let color {
                // Tinted at the top, settling onto a faint colour floor toward the
                // bottom (not pure black) — mirrors the Now Playing backdrop so the
                // whole app reads as one cohesive, colour-aware surface.
                LinearGradient(
                    colors: [color.opacity(0.45 * k), color.opacity(0.18 * k), color.opacity(0.10 * k)],
                    startPoint: .top, endPoint: .bottom
                )
                // A soft corner bloom adds depth over a flat wash.
                RadialGradient(
                    colors: [color.opacity(0.22 * k), .clear],
                    center: .topTrailing, startRadius: 0, endRadius: 520
                )
            }
        }
        .ignoresSafeArea()
        .animation(Motion.ambient, value: color)
    }
}

/// Tinted card behind each List/Form row: a faint lift so the row reads as a
/// raised surface, washed with the now-playing colour so the cards themselves
/// wear the tint (not just the gaps around them). Falls back to a neutral,
/// scheme-aware card when nothing plays.
public struct AmbientCard: View {
    @AppStorage("ambientIntensity") private var intensity: Double = 1.0
    let color: Color?
    public init(color: Color?) { self.color = color }

    public var body: some View {
        let k = max(0, min(intensity, 1))
        ZStack {
            // Adaptive lift: `primary` is white in dark mode and black in light,
            // so the raised card reads correctly on either base (a faint light
            // lift on black, a faint shadow-lift on white) instead of an invisible
            // white-on-white card in the light theme.
            Color.primary.opacity(0.06)               // surface lift, theme-aware
            (color ?? .clear).opacity(0.20 * k)       // now-playing tint (dialable)
        }
        .animation(Motion.ambient, value: color)
    }
}

private struct AmbientSurface: ViewModifier {
    @Environment(AmbientTheme.self) private var ambient
    func body(content: Content) -> some View {
        content
            // Let the tint show through Lists/Forms (transparent otherwise sit on
            // the opaque system grouped background). Propagates to descendant
            // scroll views, so pushed screens inherit it too.
            .scrollContentBackground(.hidden)
            // Tint the row cards themselves (propagates to rows in descendant
            // Lists/Forms), so the surface is colour-aware too — not just the gaps.
            .listRowBackground(AmbientCard(color: ambient.color))
            .background(AmbientBackdrop(color: ambient.color, artKey: ambient.artKey))
    }
}

public extension View {
    /// Swap a tab's flat system surface for the shared album-art tint. Apply to
    /// the content inside each tab's `NavigationStack` (or the split-view detail).
    func ambientSurface() -> some View { modifier(AmbientSurface()) }
}
