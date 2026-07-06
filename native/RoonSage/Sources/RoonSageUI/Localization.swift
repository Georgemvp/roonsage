import SwiftUI

// MARK: - Localization (C7 scaffolding)
//
// RoonSage shipped fully in Dutch with hardcoded literals. This establishes the
// mechanism to translate it: a `nl` (default) + `en` string catalogue lives in
// `Resources/*.lproj/Localizable.strings`, and lookups MUST go through
// `Bundle.module` — the classic SPM-library gotcha: a bare `Text("key")` or
// `String(localized:)` resolves against `Bundle.main` (the app), not the
// library bundle where these strings live, so it would silently fall back to the
// key. `LS`/`LT` below pin `.module`.
//
// Migration pattern (do this incrementally, screen by screen):
//   Text("Nu speelt")            → LT("nav.nowPlaying")
//   let s = "Instellingen"       → let s = LS("nav.settings")
// then add the key to both `nl.lproj` and `en.lproj`.

/// In-app language override. `system` follows the OS; the others force a locale
/// so the user can flip the app's language without changing their whole Mac/phone
/// — the switch is live because `LS` reads this on every call and `LT`/`Text`
/// resolve against the `\.locale` environment we pin at the root.
public enum LocalePreference: String, CaseIterable, Identifiable, Sendable {
    case system, nl, en

    public var id: String { rawValue }

    /// Label for the settings picker (shown in the *current* UI language).
    public var label: String {
        switch self {
        case .system: LS("lang.system")
        case .nl:     "Nederlands"
        case .en:     "English"
        }
    }

    /// The forced locale, or `nil` to follow the system.
    public var locale: Locale? {
        switch self {
        case .system: nil
        case .nl:     Locale(identifier: "nl")
        case .en:     Locale(identifier: "en")
        }
    }

    /// Current stored preference (read straight from UserDefaults so free
    /// functions like `LS` can honour it without a SwiftUI environment).
    public static var current: LocalePreference {
        LocalePreference(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "system") ?? .system
    }
}

/// Marker class so `Bundle(for:)` resolves the RoonSageUI module bundle.
private final class BundleToken {}

/// The RoonSageUI resource bundle, found DEFENSIVELY. `Bundle.module`'s generated
/// accessor calls `fatalError` when the SwiftPM resource bundle isn't beside the
/// executable at runtime — which crashed the whole app at launch when the release
/// script packaged the binary into a .app without copying `RoonSage_RoonSageUI.bundle`
/// (now fixed in build-release.sh). We replicate SwiftPM's own search but fall back
/// to `.main` so a missing/misplaced bundle degrades to the base (Dutch) strings
/// instead of a SIGTRAP at launch.
let uiBundle: Bundle = {
    let bundleName = "RoonSage_RoonSageUI"
    let candidates = [
        Bundle.main.resourceURL,                                   // .app/Contents/Resources
        Bundle(for: BundleToken.self).resourceURL,
        Bundle.main.bundleURL,
        Bundle(for: BundleToken.self).bundleURL,
        Bundle.main.executableURL?.deletingLastPathComponent(),    // .app/Contents/MacOS
        Bundle(for: BundleToken.self).resourceURL?.deletingLastPathComponent(),
    ]
    for base in candidates.compactMap({ $0 }) {
        if let bundle = Bundle(url: base.appendingPathComponent("\(bundleName).bundle")) {
            return bundle
        }
    }
    return .main
}()

/// Localized `String`, resolved against the RoonSageUI bundle and honouring the
/// in-app language override.
public func LS(_ key: String.LocalizationValue) -> String {
    if let loc = LocalePreference.current.locale {
        return String(localized: key, bundle: uiBundle, locale: loc)
    }
    return String(localized: key, bundle: uiBundle)
}

/// Localized `Text`, resolved against the RoonSageUI bundle. Respects the
/// `\.locale` environment (pinned at the root by `.appLanguage()`).
public func LT(_ key: LocalizedStringKey) -> Text {
    Text(key, bundle: uiBundle)
}

/// Pins the app's `\.locale` from the stored language override. Reactive: changing
/// the preference re-resolves every `Text`/`LT` beneath it. Apply once at the root.
private struct AppLanguageModifier: ViewModifier {
    @AppStorage("appLanguage") private var lang: LocalePreference = .system
    func body(content: Content) -> some View {
        if let loc = lang.locale {
            content.environment(\.locale, loc)
        } else {
            content
        }
    }
}

public extension View {
    /// Apply the in-app language override at the app root.
    func appLanguage() -> some View { modifier(AppLanguageModifier()) }
}
