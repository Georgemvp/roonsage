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

/// Localized `String`, resolved against the RoonSageUI bundle.
public func LS(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}

/// Localized `Text`, resolved against the RoonSageUI bundle.
public func LT(_ key: LocalizedStringKey) -> Text {
    Text(key, bundle: .module)
}
