import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Works around an iOS 26.x layout bug: a `NavigationStack` inside the (floating)
/// `TabView` proposes an OVER-WIDE region to its scrollable content — ~560pt on a
/// ~390–430pt iPhone — so VStack/ScrollView content runs off BOTH screen edges
/// (and a greedy `GeometryReader` or `.frame(maxWidth: .infinity)` only inherits
/// the same bad 560pt). The fix mirrors `NowPlayingView`: bound the content to the
/// TRUE window width (read from UIKit, not from the broken layout proposal) and
/// centre it inside the inflated region — since the region is centred on screen,
/// content at the real width lands correctly.
///
/// Apply once at the root of each NavigationStack-pushed/custom-layout view.
/// No-op-safe on macOS, where the window is sized correctly (plain 560 cap).
struct WindowWidthCap: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .frame(maxWidth: Self.realWidth)
            .frame(maxWidth: .infinity)
        #else
        // macOS windows are sized correctly — leave the layout untouched.
        content
        #endif
    }

    /// The active window's real width (capped for iPad), bypassing the inflated
    /// layout proposal. Falls back to 560 when no window is available yet.
    static var realWidth: CGFloat {
        #if canImport(UIKit)
        let windowWidth = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.bounds.width }
            .first ?? UIScreen.main.bounds.width
        return min(windowWidth > 0 ? windowWidth : 560, 560)
        #else
        return 560
        #endif
    }
}

public extension View {
    /// Keep NavigationStack content on screen despite iOS 26's over-wide layout
    /// proposal. See `WindowWidthCap`.
    func windowWidthCapped() -> some View { modifier(WindowWidthCap()) }
}
