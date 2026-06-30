import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Works around an iOS 26.x layout bug: a `NavigationStack` inside the (floating)
/// `TabView` proposes an OVER-WIDE region to its scrollable content — ~560pt on a
/// ~390–430pt iPhone — so VStack/ScrollView content runs off BOTH screen edges
/// (and a greedy `GeometryReader` or `.frame(maxWidth: .infinity)` only inherits
/// the same bad 560pt).
///
/// ⚠️ UNRELIABLE for pushed/scrolling content. This exact pattern (read the real
/// UIKit window width, force an exact `.frame(width:)`, re-centre with
/// `.frame(maxWidth: .infinity)`) is what shipped — and was verified on-device —
/// for `NowPlayingView`, which is the ROOT of its own NavigationStack with a
/// HIDDEN nav bar and no ScrollView. Applied to `GenerateView` (reached via
/// NavigationLink PUSH, with a visible nav bar, wrapping a ScrollView), it was
/// shipped TWICE (ios-v1.7.35, ios-v1.7.36) and confirmed broken BOTH times on a
/// real device (iOS 26.6) despite passing every synthetic-inflation check we
/// could construct on an iOS 26.5 simulator. We don't know why it doesn't
/// transfer — possibly ScrollView re-applies the bad proposal to its own content
/// internally, possibly pushed (vs. root) NavigationStack content behaves
/// differently. GenerateView was rebuilt on `List` instead (which has never
/// exhibited this bug anywhere in the app — Settings/Playlists/Queue are all
/// List/Form-based and unaffected) rather than continuing to patch this modifier.
///
/// Treat this as proven ONLY for hidden-bar root content shaped like
/// `NowPlayingView`. For anything else, prefer restructuring onto `List`/`Form`
/// over reapplying this modifier — and if you do reapply it, get real on-device
/// (not simulator) confirmation before considering it fixed.
struct WindowWidthCap: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        // EXACT width, not `.frame(maxWidth:)` — a max-width cap alone still lets
        // the bad 560pt proposal leak through on iOS 26.6 (this was tried and
        // failed for NowPlayingView in e66452f). Only an exact `.frame(width:)`,
        // then re-centred via `.frame(maxWidth: .infinity)`, reliably forces the
        // real width — the pattern that shipped (and was verified on-device) in
        // 94d63fc.
        content
            .frame(width: Self.realWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
