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

#if os(macOS)
extension View {
    /// `.navigationBarTitleDisplayMode` is iOS-only. No-op on macOS so hub views
    /// in the shared library compile for both platforms.
    @inlinable
    public func navigationBarTitleDisplayMode(_ mode: NavigationBarTitleDisplayMode) -> some View { self }
}

/// Stub so the type compiles on macOS (only referenced in the no-op shim above).
public enum NavigationBarTitleDisplayMode {
    case automatic, inline, large
}
#endif

// Cross-platform bitmap image type (NSImage on macOS, UIImage on iOS).
#if os(macOS)
public typealias PlatformImage = NSImage
#else
public typealias PlatformImage = UIImage
#endif

extension Image {
    /// Build a SwiftUI `Image` from a platform bitmap regardless of OS.
    public init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

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
