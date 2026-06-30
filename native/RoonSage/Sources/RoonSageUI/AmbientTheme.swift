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
    public init() {}

    /// Re-derive the tint for the selected zone's now-playing artwork. Cheap to
    /// call repeatedly — `ImageCache.dominantColor` caches per URL. Cross-fades
    /// with the ambient motion token so the whole app shifts colour smoothly.
    public func update(from client: RoonClient) async {
        guard let key = client.selectedZone?.nowPlaying?.imageKey,
              let url = client.imageURL(forKey: key, size: 64) else {
            withAnimation(Motion.ambient) { color = nil }
            return
        }
        let derived = await ImageCache.shared.dominantColor(for: url)
        withAnimation(Motion.ambient) { color = derived }
    }
}

/// Full-bleed backdrop that washes the screen in the now-playing tint, dissolving
/// into black toward the bottom so list/form content stays legible. Falls back to
/// plain black when nothing plays, so it's always safe to place behind a tab.
public struct AmbientBackdrop: View {
    let color: Color?
    public init(color: Color?) { self.color = color }

    public var body: some View {
        ZStack {
            Color.black
            if let color {
                // Tinted at the top, settling onto a faint colour floor toward the
                // bottom (not pure black) — mirrors the Now Playing backdrop so the
                // whole app reads as one cohesive, colour-aware surface.
                LinearGradient(
                    colors: [color.opacity(0.45), color.opacity(0.18), color.opacity(0.10)],
                    startPoint: .top, endPoint: .bottom
                )
                // A soft corner bloom adds depth over a flat wash.
                RadialGradient(
                    colors: [color.opacity(0.22), .clear],
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
/// wear the tint (not just the gaps around them). Falls back to a neutral dark
/// card when nothing plays.
public struct AmbientCard: View {
    let color: Color?
    public init(color: Color?) { self.color = color }

    public var body: some View {
        ZStack {
            Color.white.opacity(0.06)                 // surface lift, theme-neutral
            (color ?? .clear).opacity(0.20)           // now-playing tint
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
            .background(AmbientBackdrop(color: ambient.color))
    }
}

public extension View {
    /// Swap a tab's flat system surface for the shared album-art tint. Apply to
    /// the content inside each tab's `NavigationStack` (or the split-view detail).
    func ambientSurface() -> some View { modifier(AmbientSurface()) }
}
