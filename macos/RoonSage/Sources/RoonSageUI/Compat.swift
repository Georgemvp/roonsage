import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Cross-platform compatibility shims so the shared RoonSageUI views compile on
// both macOS and iOS. macOS-only modifiers/colors get an iOS-appropriate
// fallback rather than scattering `#if os(macOS)` through every view.

#if !os(macOS)
extension View {
    /// `.help(_:)` is a macOS-only tooltip modifier (no pointer hover on iOS).
    /// On iOS this is a no-op so shared views using `.help("…")` still compile.
    @inlinable
    public func help(_ text: String) -> some View { self }
}
#endif

extension Color {
    /// A faint fill (chip background) — `quaternaryLabel` on both platforms.
    public static var platformQuaternaryFill: Color {
        #if os(macOS)
        Color(nsColor: .quaternaryLabelColor)
        #else
        Color(uiColor: .quaternaryLabel)
        #endif
    }

    /// The neutral surface behind raised cards — window background on macOS,
    /// the secondary system background on iOS.
    public static var platformCardBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }
}
